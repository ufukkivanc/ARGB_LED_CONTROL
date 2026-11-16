import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:argb_controller/screens/device_settings_screen.dart';
import 'package:argb_controller/screens/setup_screen.dart';
import 'package:argb_controller/screens/usb_setup_screen.dart';
import 'package:argb_controller/services/device_discovery.dart';
import 'package:argb_controller/state/app_state.dart';
import 'package:argb_controller/state/connection_controller.dart';
import 'package:argb_controller/state/usb_setup_controller.dart';
import 'package:argb_controller/theme/app_colors.dart';

/// Cihaz keşfi, seçimi ve mod (simülasyon / gerçek cihaz) ekranı.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  final Map<String, FoundDevice> _found = {};
  StreamSubscription<FoundDevice>? _sub;
  bool _scanning = false;
  bool _scanned = false;
  final _hostCtrl = TextEditingController();
  String? _manualError;
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _hostCtrl.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    await _sub?.cancel();
    final known = ref.read(knownDevicesProvider).map((e) => e.host);
    setState(() {
      _scanning = true;
      _found.clear();
    });
    _sub = ref.read(discoveryProvider).scan(extraHosts: known).listen(
      (d) {
        if (mounted) setState(() => _found[d.id] = d);
      },
      onDone: () {
        if (mounted) {
          setState(() {
            _scanning = false;
            _scanned = true;
          });
        }
      },
    );
  }

  Future<void> _probeManual() async {
    final text = _hostCtrl.text.trim();
    if (text.isEmpty) return;
    var host = text;
    var port = 80;
    final idx = text.lastIndexOf(':');
    if (idx > 0 && !text.contains('::')) {
      host = text.substring(0, idx);
      port = int.tryParse(text.substring(idx + 1)) ?? 80;
    }
    setState(() {
      _probing = true;
      _manualError = null;
    });
    final d = await ref.read(discoveryProvider).probe(host, port: port);
    if (!mounted) return;
    setState(() {
      _probing = false;
      if (d == null) {
        _manualError = 'Bu adreste ARGB denetleyici bulunamadı. Adresi ve ağı kontrol edin.';
      } else {
        _found[d.id] = d;
        _hostCtrl.clear();
      }
    });
  }

  Future<void> _select(FoundDevice d) async {
    if (d.isSetupAp) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SetupScreen(device: d)));
      return;
    }
    final token = await ref.read(tokenStoreProvider).read(d.id);
    if (!mounted) return;
    if (token == null) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SetupScreen(device: d, pairOnly: true)),
      );
      return;
    }
    await ref.read(knownDevicesProvider.notifier).upsert(
          KnownDevice(id: d.id, name: d.name, host: d.host, port: d.port),
        );
    await ref.read(appModeProvider.notifier).set(AppMode.device);
    await ref.read(connectionProvider.notifier).connect(d);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(appModeProvider);
    final conn = ref.watch(connectionProvider);
    final known = ref.watch(knownDevicesProvider);
    final disc = ref.read(discoveryProvider);

    final offlineKnown = known.where((k) => !_found.containsKey(k.id)).toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Cihazlar'),
        actions: [
          IconButton(
            tooltip: 'Yeniden ara',
            onPressed: _scanning ? null : _scan,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SwitchListTile(
                  tileColor: AppColors.surface,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  title: const Text('Gerçek cihaz modu'),
                  subtitle: Text(mode == AppMode.device
                      ? 'Komutlar ESP32\'ye gönderilir.'
                      : 'Simülasyon: yalnızca uygulama içi önizleme.'),
                  value: mode == AppMode.device,
                  onChanged: (v) async {
                    await ref.read(appModeProvider.notifier).set(v ? AppMode.device : AppMode.simulation);
                    if (!v) await ref.read(connectionProvider.notifier).disconnect();
                  },
                ),
                const SizedBox(height: 16),
                if (conn.device != null && conn.status != LinkStatus.idle && mode == AppMode.device)
                  Card(
                    color: AppColors.surface,
                    child: ListTile(
                      leading: Icon(Icons.bolt, color: _statusColor(conn.status)),
                      title: Text(conn.device!.name),
                      subtitle: Text(_statusText(conn)),
                      trailing: IconButton(
                        tooltip: 'Cihaz ayarları',
                        icon: const Icon(Icons.settings),
                        onPressed: conn.device == null
                            ? null
                            : () => Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => DeviceSettingsScreen(device: conn.device!)),
                                ),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    const Expanded(
                      child: Text('Bulunan cihazlar', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    if (_scanning) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ),
                const SizedBox(height: 8),
                if (!_scanning && _scanned && _found.isEmpty)
                  _hint(
                    'Cihaz bulunamadı.\n'
                    '• ESP32 açık ve aynı Wi-Fi ağında mı?\n'
                    '• İlk kez kuruyorsanız "Yeni cihaz kur" ile başlayın.\n'
                    '${disc.mdnsAvailable ? '' : '• Bu platformda (Web) otomatik mDNS yok; IP adresini elle girin.\n'}'
                    '• iOS: Ayarlar ▸ Gizlilik ▸ Yerel Ağ iznini kontrol edin.',
                  ),
                for (final d in _found.values) _deviceTile(d, conn),
                for (final k in offlineKnown)
                  ListTile(
                    tileColor: AppColors.surface,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    leading: const Icon(Icons.portable_wifi_off, color: AppColors.textHint),
                    title: Text(k.name),
                    subtitle: Text('${k.host} • çevrimdışı/bulunamadı'),
                    onTap: () => _select(k.toFound()),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Listeden kaldır',
                      onPressed: () => ref.read(knownDevicesProvider.notifier).remove(k.id),
                    ),
                  ),
                const SizedBox(height: 16),
                const Text('IP adresiyle bağlan', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _hostCtrl,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          hintText: '192.168.1.40  veya  esp32-argb.local',
                          errorMaxLines: 3,
                        ),
                        onSubmitted: (_) => _probeManual(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _probing ? null : _probeManual,
                      child: _probing
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Ara'),
                    ),
                  ],
                ),
                if (_manualError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_manualError!, style: const TextStyle(color: AppColors.error)),
                  ),
                if (kIsWeb)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Flutter Web: tarayıcı mDNS yapamaz ve Wi-Fi ağı değiştiremez. IP girişi ve '
                      'bilgisayarın Wi-Fi ayarı elle yapılır.',
                      style: TextStyle(fontSize: 12, color: AppColors.textHint),
                    ),
                  ),
                const SizedBox(height: 24),
                if (ref.read(serialBackendProvider).supported) ...[
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const UsbSetupScreen()),
                    ),
                    icon: const Icon(Icons.usb),
                    label: const Text('USB ile Wi-Fi kur (kablolu)'),
                  ),
                  const SizedBox(height: 8),
                ],
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SetupScreen()),
                  ),
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('Yeni cihaz kur (ilk Wi-Fi kurulumu)'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _hint(String text) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
      );

  Widget _deviceTile(FoundDevice d, DeviceConnection conn) {
    final isCurrent = conn.device?.id == d.id && conn.isConnected;
    final String tag;
    if (d.isSetupAp) {
      tag = 'Kurulum modu (SoftAP)';
    } else if (isCurrent) {
      tag = 'Bağlı';
    } else {
      tag = d.paired ? 'Eşleşmiş cihaz' : 'Henüz eşleştirilmedi';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        tileColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: Icon(
          d.isSetupAp ? Icons.settings_input_antenna : Icons.lightbulb,
          color: isCurrent ? AppColors.success : AppColors.secondary,
        ),
        title: Text(d.name),
        subtitle: Text('${d.id} • ${d.host}\n$tag${d.fw.isNotEmpty ? ' • v${d.fw}' : ''}'),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _select(d),
      ),
    );
  }
}

Color _statusColor(LinkStatus s) {
  switch (s) {
    case LinkStatus.connected:
      return AppColors.success;
    case LinkStatus.needsPairing:
      return AppColors.warning;
    case LinkStatus.reconnecting:
      return AppColors.warning;
    default:
      return AppColors.secondary;
  }
}

String _statusText(DeviceConnection c) {
  switch (c.status) {
    case LinkStatus.connected:
      return 'Bağlı';
    case LinkStatus.connecting:
    case LinkStatus.authenticating:
      return 'Bağlanıyor…';
    case LinkStatus.reconnecting:
      return 'Çevrimdışı — yeniden bağlanılıyor (deneme ${c.attempt})';
    case LinkStatus.needsPairing:
      return c.error ?? 'Eşleştirme gerekli';
    case LinkStatus.idle:
      return 'Bağlı değil';
  }
}
