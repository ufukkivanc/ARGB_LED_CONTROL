import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/screens/setup_screen.dart';
import 'package:argb_controller/services/device_api.dart';
import 'package:argb_controller/services/device_discovery.dart';
import 'package:argb_controller/state/app_state.dart';
import 'package:argb_controller/theme/app_colors.dart';

/// Cihaz ayarları: eşleştirilmiş istemciler, Wi-Fi değiştirme/sıfırlama, eşleştirmeyi kaldırma.
class DeviceSettingsScreen extends ConsumerStatefulWidget {
  const DeviceSettingsScreen({super.key, required this.device});
  final FoundDevice device;

  @override
  ConsumerState<DeviceSettingsScreen> createState() => _DeviceSettingsScreenState();
}

class _DeviceSettingsScreenState extends ConsumerState<DeviceSettingsScreen> {
  List<PairedClient>? _clients;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<DeviceApi?> _api() async {
    final token = await ref.read(tokenStoreProvider).read(widget.device.id);
    if (token == null) {
      setState(() => _error = 'Bu cihaz için eşleştirme yok.');
      return null;
    }
    return DeviceApi(host: widget.device.host, port: widget.device.port, token: token);
  }

  Future<void> _load() async {
    final api = await _api();
    if (api == null) return;
    try {
      final c = await api.listTokens();
      if (mounted) {
        setState(() {
          _clients = c;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = describeApiError(e));
    } finally {
      api.close();
    }
  }

  Future<void> _run(Future<void> Function(DeviceApi api) action, {String? ok}) async {
    final api = await _api();
    if (api == null) return;
    setState(() => _busy = true);
    try {
      await action(api);
      if (ok != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok)));
      }
    } catch (e) {
      if (mounted) setState(() => _error = describeApiError(e));
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Onayla')),
        ],
      ),
    );
    return r ?? false;
  }

  /// Bu telefonun eşleştirmesini cihazdan ve yerelden kaldırır.
  Future<void> _forget(PairedClient self) async {
    if (!await _confirm('Eşleştirmeyi kaldır', 'Bu telefonun cihazla eşleştirmesi silinecek. Tekrar kullanmak için BOOT düğmesiyle yeniden eşleştirmeniz gerekir.')) return;
    await _run((api) => api.revokeToken(self.tokenId));
    await ref.read(tokenStoreProvider).delete(widget.device.id);
    await ref.read(connectionProvider.notifier).disconnect();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);
    final info = conn.info;
    final persistent = ref.watch(tokenStoreProvider).isPersistent;
    final webPersist = ref.watch(webPersistProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(widget.device.name)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppColors.error.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(_error!),
                  ),
                if (_busy) const LinearProgressIndicator(),
                _section('Cihaz'),
                ListTile(
                  title: Text(info?.name ?? widget.device.name),
                  subtitle: Text([
                    widget.device.id,
                    if (info != null) 'Yazılım ${info.fw}',
                    if (info?.wifiSsid != null) 'Ağ: ${info!.wifiSsid}',
                    if (info?.ip != null) 'IP: ${info!.ip}',
                  ].join('\n')),
                  isThreeLine: true,
                ),
                _section('Wi-Fi'),
                ListTile(
                  leading: const Icon(Icons.wifi),
                  title: const Text('Wi-Fi ağını değiştir'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => SetupScreen(device: widget.device)),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.wifi_off, color: AppColors.warning),
                  title: const Text('Wi-Fi ayarını sıfırla'),
                  subtitle: const Text('ESP32 kurulum moduna (SoftAP) döner.'),
                  onTap: () async {
                    if (!await _confirm('Wi-Fi sıfırlansın mı?', 'ESP32 ağdan ayrılıp kurulum ağını yayınlamaya başlar. Yeniden kurulum gerekir.')) return;
                    await _run((api) => api.resetWifi(), ok: 'Sıfırlama komutu gönderildi.');
                    await ref.read(connectionProvider.notifier).disconnect();
                  },
                ),
                _section('Eşleştirilmiş istemciler'),
                if (_clients == null && _error == null) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
                for (final c in _clients ?? const <PairedClient>[])
                  ListTile(
                    leading: Icon(c.current ? Icons.smartphone : Icons.devices_other),
                    title: Text(c.clientName),
                    subtitle: Text(c.current ? 'Bu cihaz (${c.tokenId})' : c.tokenId),
                    trailing: IconButton(
                      icon: const Icon(Icons.link_off),
                      tooltip: 'Eşleştirmeyi kaldır',
                      onPressed: () async {
                        if (c.current) {
                          await _forget(c);
                        } else {
                          if (await _confirm('İstemci kaldırılsın mı?', '"${c.clientName}" cihazı denetleyiciyi artık kullanamaz.')) {
                            await _run((api) => api.revokeToken(c.tokenId));
                          }
                        }
                      },
                    ),
                  ),
                ListTile(
                  leading: const Icon(Icons.person_add_alt),
                  title: const Text('Yeni telefon eşleştir'),
                  subtitle: const Text('120 saniyelik eşleştirme penceresini açar.'),
                  onTap: () => _run((api) => api.openPairing(), ok: 'Eşleştirme penceresi açıldı (120 sn).'),
                ),
                _section('Güvenlik'),
                ListTile(
                  leading: Icon(persistent ? Icons.lock : Icons.lock_open, color: persistent ? AppColors.success : AppColors.warning),
                  title: Text(persistent ? 'Token güvenli depoda saklanıyor' : 'Token yalnızca bellekte (kalıcı değil)'),
                  subtitle: Text(kIsWeb
                      ? 'Tarayıcıda güvenli kalıcı saklama yoktur. Sekme kapanınca yeniden eşleştirme gerekir.'
                      : 'Android Keystore / iOS Keychain kullanılır.'),
                ),
                if (kIsWeb)
                  SwitchListTile(
                    title: const Text('Tarayıcıda hatırla (GÜVENLİ DEĞİL)'),
                    subtitle: const Text('Yalnızca geliştirme için. Token tarayıcı depolamasına yazılır.'),
                    value: webPersist,
                    onChanged: (v) => ref.read(webPersistProvider.notifier).set(v),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text(t.toUpperCase(), style: const TextStyle(fontSize: 12, letterSpacing: 1.1, color: AppColors.textSecondary)),
      );
}
