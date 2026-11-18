import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/services/device_discovery.dart';
import 'package:argb_controller/services/platform_helpers.dart';
import 'package:argb_controller/state/app_state.dart';
import 'package:argb_controller/state/connection_controller.dart';
import 'package:argb_controller/state/setup_controller.dart';
import 'package:argb_controller/state/setup_providers.dart';
import 'package:argb_controller/theme/app_colors.dart';
import 'package:argb_controller/widgets/signal_bars.dart';

/// Kurulum / eşleştirme sihirbazı.
///
/// - [device] null: ilk kurulum (SoftAP üzerinden).
/// - [device] verilirse: o cihazla başlar. [pairOnly] ise yalnızca eşleştirir.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key, this.device, this.pairOnly = false});
  final FoundDevice? device;
  final bool pairOnly;

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  late final SetupArgs _args;
  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _showPass = false;
  bool _openNetwork = false;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _args = SetupArgs(device: widget.device, pairOnly: widget.pairOnly);
    if (widget.device != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(setupProvider(_args).notifier).startForDevice(widget.device!);
      });
    }
  }

  @override
  void dispose() {
    _passCtrl.clear(); // şifreyi bellekte bırakma
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _useDevice(FoundDevice d) async {
    await ref.read(appModeProvider.notifier).set(AppMode.device);
    await ref.read(connectionProvider.notifier).connect(d);
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(setupProvider(_args));
    final c = ref.read(setupProvider(_args).notifier);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(widget.pairOnly ? 'Cihazı Eşleştir' : 'Cihaz Kurulumu'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _StepHeader(step: s.step, pairOnly: widget.pairOnly),
                const SizedBox(height: 16),
                if (s.error != null) _Banner(text: s.error!, color: AppColors.error),
                if (s.info != null && s.error == null) _Banner(text: s.info!, color: AppColors.secondary),
                ..._body(s, c),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(SetupState s, SetupController c) {
    switch (s.step) {
      case SetupStep.intro:
        return _intro(c);
      case SetupStep.connectAp:
        return [
          _Busy(label: 'Kurulum ağındaki ESP32 aranıyor (192.168.4.1)…', busy: s.busy),
          if (!s.busy) ...[
            FilledButton.icon(
              onPressed: c.probeAp,
              icon: const Icon(Icons.refresh),
              label: const Text('Tekrar dene'),
            ),
            if (canOpenWifiSettings)
              TextButton(onPressed: openWifiSettings, child: const Text('Wi-Fi ayarlarını aç')),
          ],
        ];
      case SetupStep.pairing:
        return _pairing(s, c);
      case SetupStep.scan:
        return _scan(s, c);
      case SetupStep.credentials:
        return _credentials(s, c);
      case SetupStep.connecting:
        return [_Busy(label: s.info ?? 'Bağlanıyor…', busy: true)];
      case SetupStep.rediscover:
        return [
          _Busy(label: s.info ?? 'ESP32 yerel ağda aranıyor…', busy: s.busy),
          if (!s.busy && s.needsPhoneNetwork) ...[
            const SizedBox(height: 8),
            const Text(
              'ESP32 kurulum ağını kapattı. Telefonunuzun ev Wi-Fi ağınıza bağlı olması gerekir.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            if (canOpenWifiSettings)
              OutlinedButton.icon(
                onPressed: openWifiSettings,
                icon: const Icon(Icons.wifi),
                label: const Text('Wi-Fi ayarlarını aç'),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: c.retryRediscover,
              icon: const Icon(Icons.search),
              label: const Text('ESP32\'yi tekrar ara'),
            ),
          ],
        ];
      case SetupStep.done:
        final d = s.finalDevice;
        return [
          const Icon(Icons.check_circle, color: AppColors.success, size: 64),
          const SizedBox(height: 12),
          Text(
            widget.pairOnly ? 'Eşleştirme tamamlandı.' : 'Kurulum tamamlandı.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          if (d != null)
            Text('${d.name}\n${d.host}', textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 20),
          if (d != null)
            FilledButton.icon(
              onPressed: () => _useDevice(d),
              icon: const Icon(Icons.lightbulb),
              label: const Text('Bu cihazı kontrol et'),
            ),
        ];
    }
  }

  // ── Adımlar ───────────────────────────────────────────────────────────

  List<Widget> _intro(SetupController c) => [
        const _Card(children: [
          _Numbered(1, 'ESP32\'yi çalıştırın. Kartın mavi durum LED\'i yavaş yanıp sönüyorsa kurulum modundadır.'),
          _Numbered(2, 'Telefonunuzun Wi-Fi ayarlarında "ESP32-ARGB-Setup-XXXX" ağına bağlanın.'),
          _Numbered(3, 'AP şifresi ilk prototipte yalnızca SERİ PORTTAN öğrenilir: '
              'ESP32\'yi USB ile bilgisayara bağlayıp 115200 baud\'da seri monitörü açın ve '
              '"[WiFiManager] Password: …" satırını okuyun.'),
          _Numbered(4, 'Bağlandıktan sonra buraya dönüp devam edin. (Mobil veri kapalıysa bağlantı daha sorunsuz olur.)'),
        ]),
        const SizedBox(height: 12),
        if (canOpenWifiSettings)
          OutlinedButton.icon(
            onPressed: openWifiSettings,
            icon: const Icon(Icons.wifi),
            label: const Text('Wi-Fi ayarlarını aç'),
          )
        else
          const _Banner(
            text: 'Tarayıcı (Flutter Web) Wi-Fi ağı değiştiremez: bilgisayarınızın Wi-Fi\'ını '
                '"ESP32-ARGB-Setup-…" ağına elle bağlayın. Ardından devam edin.',
            color: AppColors.warning,
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: c.goToConnectAp,
          icon: const Icon(Icons.arrow_forward),
          label: const Text('Bağlandım, devam'),
        ),
      ];

  List<Widget> _pairing(SetupState s, SetupController c) => [
        const _Card(children: [
          _Numbered(1, 'ESP32 üzerindeki BOOT düğmesine 3 saniye basılı tutup bırakın.'),
          _Numbered(2, 'Mavi LED hızlı yanıp söner: eşleştirme penceresi 120 saniye açıktır.'),
          _Numbered(3, 'Uygulama pencereyi otomatik algılar ve eşleştirmeyi tamamlar.'),
        ]),
        const SizedBox(height: 12),
        _Busy(
          label: s.pairingWindowSeen
              ? 'Pencere açık, eşleştiriliyor…'
              : 'BOOT düğmesine basmanız bekleniyor…',
          busy: s.busy,
        ),
        if (!s.busy)
          FilledButton.icon(
            onPressed: c.watchPairing,
            icon: const Icon(Icons.refresh),
            label: const Text('Tekrar dene'),
          ),
        const SizedBox(height: 8),
        const Text(
          'Güvenlik: Eşleştirme yalnızca cihaza fiziksel erişimi olan biri tarafından yapılabilir. '
          'Token yalnızca bu telefonda saklanır.',
          style: TextStyle(fontSize: 12, color: AppColors.textHint),
        ),
      ];

  List<Widget> _scan(SetupState s, SetupController c) {
    final tiles = <Widget>[];
    for (final g in s.networks) {
      final n = g.best;
      tiles.add(ListTile(
        enabled: n.isSupported,
        leading: Icon(n.isOpen ? Icons.lock_open : Icons.lock, color: n.isOpen ? AppColors.warning : AppColors.textSecondary),
        title: Text(g.ssid),
        subtitle: Text([
          n.isOpen ? 'Açık ağ' : n.security.replaceAll('_', ' '),
          if (g.accessPointCount > 1) '${g.accessPointCount} erişim noktası',
          if (!n.isSupported) 'Desteklenmiyor (kurumsal)',
        ].join(' • ')),
        trailing: SignalBars(bars: signalBars(n.rssi)),
        onTap: n.isSupported ? () {
          _ssidCtrl.text = g.ssid;
          _passCtrl.clear();
          _openNetwork = n.isOpen;
          c.selectNetwork(g.ssid);
        } : null,
      ));
    }
    return [
      Row(
        children: [
          const Expanded(
            child: Text('Ev/ofis Wi-Fi ağınızı seçin', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          IconButton(
            tooltip: 'Yeniden tara',
            onPressed: s.scanning ? null : c.scan,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      const Text(
        'ESP32 yalnızca 2.4 GHz ağlara bağlanır. 5 GHz\'e özel ağlar listede görünmez.',
        style: TextStyle(fontSize: 12, color: AppColors.textHint),
      ),
      const SizedBox(height: 8),
      if (s.scanning) const _Busy(label: 'Ağlar taranıyor…', busy: true),
      if (!s.scanning && s.scanDone && s.networks.isEmpty && s.error == null)
        const _Banner(
          text: 'Hiç ağ bulunamadı. ESP32\'yi modeme yaklaştırıp "Yeniden tara" deneyin '
              'veya gizli ağ için SSID\'yi elle girin.',
          color: AppColors.warning,
        ),
      _Card(children: tiles),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () {
          _ssidCtrl.clear();
          _passCtrl.clear();
          _openNetwork = false;
          c.selectHidden();
        },
        icon: const Icon(Icons.edit),
        label: const Text('SSID\'yi elle gir (gizli ağ)'),
      ),
    ];
  }

  List<Widget> _credentials(SetupState s, SetupController c) {
    final hidden = s.selectedSsid == null;
    return [
      Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _ssidCtrl,
              readOnly: !hidden,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Ağ adı (SSID)', prefixIcon: Icon(Icons.wifi)),
              validator: (v) {
                final t = v ?? '';
                if (t.isEmpty) return 'Ağ adı gerekli';
                if (t.codeUnits.length > 32) return 'En fazla 32 karakter';
                return null;
              },
            ),
            const SizedBox(height: 12),
            if (hidden)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Bu ağ açık (şifresiz)'),
                value: _openNetwork,
                onChanged: (v) => setState(() => _openNetwork = v),
              ),
            if (!_openNetwork)
              TextFormField(
                controller: _passCtrl,
                obscureText: !_showPass,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: 'Wi-Fi şifresi',
                  prefixIcon: const Icon(Icons.key),
                  suffixIcon: IconButton(
                    tooltip: _showPass ? 'Gizle' : 'Göster',
                    icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _showPass = !_showPass),
                  ),
                ),
                validator: (v) {
                  final t = v ?? '';
                  if (t.length < 8) return 'WPA şifresi en az 8 karakter olmalı';
                  if (t.codeUnits.length > 63) return 'En fazla 63 karakter';
                  return null;
                },
              ),
            const SizedBox(height: 8),
            const Text(
              'Şifre yalnızca ESP32\'ye gönderilir; uygulamada saklanmaz veya loglanmaz.',
              style: TextStyle(fontSize: 12, color: AppColors.textHint),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                if (!(_formKey.currentState?.validate() ?? false)) return;
                final pass = _openNetwork ? '' : _passCtrl.text;
                final ssid = _ssidCtrl.text;
                _passCtrl.clear();
                c.connectToWifi(ssid, pass);
              },
              icon: const Icon(Icons.link),
              label: const Text('Bağlan'),
            ),
            TextButton(onPressed: c.backToScan, child: const Text('Ağ listesine dön')),
          ],
        ),
      ),
    ];
  }
}

// ── Küçük bileşenler ────────────────────────────────────────────────────

class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.step, required this.pairOnly});
  final SetupStep step;
  final bool pairOnly;

  @override
  Widget build(BuildContext context) {
    final labels = pairOnly
        ? const ['Eşleştir', 'Bitti']
        : const ['Kurulum ağı', 'Eşleştir', 'Wi-Fi', 'Bağlan', 'Bitti'];
    int idx;
    switch (step) {
      case SetupStep.intro:
      case SetupStep.connectAp:
        idx = 0;
      case SetupStep.pairing:
        idx = pairOnly ? 0 : 1;
      case SetupStep.scan:
      case SetupStep.credentials:
        idx = 2;
      case SetupStep.connecting:
      case SetupStep.rediscover:
        idx = 3;
      case SetupStep.done:
        idx = labels.length - 1;
    }
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 4,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: i <= idx ? AppColors.primary : AppColors.surfaceLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 4),
                Text(labels[i],
                    style: TextStyle(fontSize: 10, color: i == idx ? AppColors.textPrimary : AppColors.textHint)),
              ],
            ),
          ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      );
}

class _Numbered extends StatelessWidget {
  const _Numbered(this.n, this.text);
  final int n;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(radius: 12, backgroundColor: AppColors.primary, child: Text('$n', style: const TextStyle(fontSize: 12))),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(text),
      );
}

class _Busy extends StatelessWidget {
  const _Busy({required this.label, required this.busy});
  final String label;
  final bool busy;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            if (busy) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            if (busy) const SizedBox(width: 12),
            Expanded(child: Text(label)),
          ],
        ),
      );
}
