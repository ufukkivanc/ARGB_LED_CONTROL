import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/screens/setup_screen.dart';
import 'package:argb_controller/services/device_api.dart';
import 'package:argb_controller/services/device_discovery.dart';
import 'package:argb_controller/state/app_state.dart';
import 'package:argb_controller/state/connection_controller.dart';
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
  WledAccess? _wled;
  String? _error;
  bool _busy = false;

  // LED sayısı (kanal başına). Alanlar yalnızca kullanıcı düzenlemediyse cihazdaki değerle eşitlenir.
  final List<TextEditingController> _ledCtrls = List.generate(kMaxChannels, (_) => TextEditingController());
  final Set<int> _ledDirty = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ledCtrls) {
      c.dispose();
    }
    super.dispose();
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
      WledAccess? wled;
      try {
        wled = await api.wledAccess();
      } on ApiException {
        wled = null; // eski firmware: WLED uç noktası yok
      }
      if (mounted) {
        setState(() {
          _wled = wled;
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
                ..._ledSection(conn),
                ..._wledSection(),
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

  // ── LED sayısı (kanal başına) ─────────────────────────────────────────────

  int? _ledValue(int ch) => int.tryParse(_ledCtrls[ch - 1].text.trim());

  /// Girişlerden doğrulama mesajı (null = geçerli) ve toplam.
  ({String? error, String? warn, int total}) _ledCheck(DeviceInfo? info, DeviceConnection conn) {
    final maxCh = info?.maxLedsPerChannel ?? 512;
    final maxTotal = info?.maxTotalLeds ?? 1024;
    final warnCh = info?.warnLedsPerChannel ?? 300;
    final warnTotal = info?.warnTotalLeds ?? 600;
    var total = 0;
    String? error;
    String? warn;
    for (var ch = 1; ch <= kMaxChannels; ch++) {
      final v = _ledDirty.contains(ch) ? _ledValue(ch) : (conn.channels[ch]?.ledCount ?? 0);
      if (v == null || v < 0 || v > maxCh) {
        error ??= 'Kanal $ch: 0–$maxCh arası bir sayı girin.';
        continue;
      }
      total += v;
      if (v > warnCh) warn = 'Yüksek LED sayısı: kare hızı düşebilir.';
    }
    if (error == null && total > maxTotal) error = 'Toplam $total LED, $maxTotal sınırını aşıyor.';
    if (error == null && total > warnTotal) warn = 'Yüksek toplam LED sayısı: kare hızı düşebilir.';
    return (error: error, warn: warn, total: total);
  }

  List<Widget> _ledSection(DeviceConnection conn) {
    final info = conn.info;
    if (conn.channels.isEmpty) return const [];
    for (var ch = 1; ch <= kMaxChannels; ch++) {
      final cur = conn.channels[ch]?.ledCount ?? 0;
      final ctrl = _ledCtrls[ch - 1];
      if (!_ledDirty.contains(ch) && ctrl.text != '$cur') ctrl.text = '$cur';
    }
    final check = _ledCheck(info, conn);
    final canApply = !_busy && _ledDirty.isNotEmpty && check.error == null;
    final pendingReboot = conn.channels.values.any((c) => c.pending != null);

    return [
      _section('LED sayısı (kanal başına)'),
      for (var ch = 1; ch <= kMaxChannels; ch++)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Expanded(child: Text('Kanal $ch')),
              if (conn.channels[ch]?.pending != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text('→ ${conn.channels[ch]!.pending!.ledCount} (yeniden başlatınca)',
                      style: const TextStyle(fontSize: 11, color: AppColors.warning)),
                ),
              SizedBox(
                width: 96,
                child: TextField(
                  key: Key('led_count_$ch'),
                  controller: _ledCtrls[ch - 1],
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.right,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                  onChanged: (_) => setState(() => _ledDirty.add(ch)),
                ),
              ),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Text(
          check.error ?? check.warn ?? 'Toplam ${check.total} LED.',
          style: TextStyle(
            fontSize: 12,
            color: check.error != null
                ? AppColors.error
                : (check.warn != null ? AppColors.warning : AppColors.textSecondary),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            FilledButton(
              key: const Key('led_apply'),
              onPressed: canApply ? _applyLeds : null,
              child: const Text('Uygula'),
            ),
            TextButton(
              key: const Key('led_fill_30'),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        // Yalnızca alanları doldurur (cihaza HİÇBİR ŞEY gönderilmez); kullanıcı "Uygula"ya basar.
                        for (var ch = 1; ch <= kMaxChannels; ch++) {
                          _ledCtrls[ch - 1].text = '30';
                          _ledDirty.add(ch);
                        }
                      }),
              child: const Text('4 × 1 m (30 LED/m): her kanal 30'),
            ),
          ],
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(
          'LED sayısı yazılımsal bir ayardır: fiziksel şerit uzunluğu otomatik algılanamaz, kendiniz girin. '
          '0 = kanal kapalı. Değişiklik cihazda kalıcı saklanır.',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ),
      if (pendingReboot)
        ListTile(
          leading: const Icon(Icons.restart_alt, color: AppColors.warning),
          title: const Text('Yeniden başlatma gerekli'),
          subtitle: const Text('Bazı değişiklikler cihaz yeniden başlayınca geçerli olur.'),
          trailing: TextButton(
            key: const Key('led_reboot'),
            onPressed: _busy ? null : () => _run((api) => api.reboot(), ok: 'Cihaz yeniden başlatılıyor…'),
            child: const Text('Yeniden başlat'),
          ),
        ),
    ];
  }

  Future<void> _applyLeds() async {
    final conn = ref.read(connectionProvider);
    final wanted = <int, int>{};
    for (final ch in _ledDirty) {
      final v = _ledValue(ch);
      if (v != null && v != (conn.channels[ch]?.ledCount ?? 0)) wanted[ch] = v;
    }
    if (wanted.isEmpty) {
      setState(_ledDirty.clear);
      return;
    }
    // Önce küçülenler, sonra büyüyenler: toplam bütçe geçici olarak aşılmasın
    final order = wanted.keys.toList()
      ..sort((a, b) => (wanted[a]! - (conn.channels[a]?.ledCount ?? 0)).compareTo(wanted[b]! - (conn.channels[b]?.ledCount ?? 0)));
    await _run((api) async {
      for (final ch in order) {
        await api.setChannelConfig(ch, ledCount: wanted[ch]);
      }
      // Cihaz durumu WebSocket'ten gelir: uygulanana (veya yeniden başlatma bekleyene) kadar bekle
      final until = DateTime.now().add(const Duration(seconds: 4));
      while (DateTime.now().isBefore(until)) {
        final c = ref.read(connectionProvider).channels;
        final done = wanted.entries.every((e) =>
            c[e.key]?.ledCount == e.value || c[e.key]?.pending?.ledCount == e.value);
        if (done) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      final c = ref.read(connectionProvider).channels;
      final failed = wanted.entries
          .where((e) => c[e.key]?.ledCount != e.value && c[e.key]?.pending?.ledCount != e.value)
          .map((e) => 'Kanal ${e.key}')
          .toList();
      if (failed.isNotEmpty) {
        throw ApiException('led_budget_exceeded', message: '${failed.join(', ')}: LED sayısı uygulanamadı (toplam sınırı veya bellek).');
      }
      if (mounted) setState(_ledDirty.clear);
      await ref.read(connectionProvider.notifier).refreshInfo();
    }, ok: 'LED sayıları kaydedildi.');
  }

  /// WLED (iPhone/Android) uygulaması uyumluluğu: erişim modu.
  List<Widget> _wledSection() {
    final w = _wled;
    if (w == null) return const [];
    if (!w.compiled) {
      return [
        _section('WLED uyumluluğu'),
        const ListTile(
          leading: Icon(Icons.block),
          title: Text('Bu firmware WLED uyumluluğu olmadan derlenmiş'),
        ),
      ];
    }
    Widget tile(String mode, String title, String subtitle, {bool warn = false}) {
      final selected = w.mode == mode;
      return ListTile(
        leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
            color: selected ? (warn ? AppColors.warning : AppColors.success) : null),
        title: Text(title),
        subtitle: Text(subtitle),
        onTap: _busy || selected ? null : () => _setWled(mode),
      );
    }

    return [
      _section('WLED uyumluluğu (iPhone WLED uygulaması)'),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          'WLED uygulaması token gönderemez. "Salt okunur" ve "Kontrol" modlarında aynı yerel ağdaki HERKES '
          'kimlik doğrulamadan cihazı okuyabilir (Kontrol: LED\'leri de değiştirebilir). Kullanmıyorsanız KAPALI bırakın.',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ),
      tile('off', 'Kapalı (önerilen)', '/json/* ve _wled._tcp yayını yok'),
      tile('readonly', 'Salt okunur', 'Uygulama cihazı bulur ve durumu görür; kontrol edemez', warn: true),
      tile('control', 'Kontrol', 'Açma/kapama, parlaklık, renk, efekt. Açmak için ESP32 BOOT düğmesine 3 sn basın.',
          warn: true),
    ];
  }

  Future<void> _setWled(String mode) async {
    if (mode == 'control') {
      final ok = await _confirm(
        'Kimlik doğrulamasız kontrol açılsın mı?',
        'Önce ESP32 üzerindeki BOOT düğmesine 3 saniye basılı tutup bırakın (fiziksel onay). '
            'Açıldığında aynı yerel ağdaki herkes WLED protokolüyle LED\'leri kontrol edebilir.',
      );
      if (!ok) return;
    }
    await _run((api) async {
      final r = await api.setWledMode(mode);
      if (mounted) setState(() => _wled = r);
    }, ok: 'WLED modu: $mode');
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text(t.toUpperCase(), style: const TextStyle(fontSize: 12, letterSpacing: 1.1, color: AppColors.textSecondary)),
      );
}
