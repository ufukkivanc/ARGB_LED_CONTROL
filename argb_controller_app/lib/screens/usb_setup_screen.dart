import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/screens/setup_screen.dart';
import 'package:argb_controller/state/usb_setup_controller.dart';
import 'package:argb_controller/theme/app_colors.dart';
import 'package:argb_controller/widgets/signal_bars.dart';

/// USB (seri port) ile ilk Wi-Fi kurulumu — yalnızca Windows masaüstünde sunulur.
class UsbSetupScreen extends ConsumerStatefulWidget {
  const UsbSetupScreen({super.key});

  @override
  ConsumerState<UsbSetupScreen> createState() => _UsbSetupScreenState();
}

class _UsbSetupScreenState extends ConsumerState<UsbSetupScreen> {
  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _showPass = false;
  bool _openNetwork = false;

  @override
  void dispose() {
    _passCtrl.clear(); // şifreyi bellekte bırakma
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(usbSetupProvider);
    final c = ref.read(usbSetupProvider.notifier);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('USB ile Wi-Fi Kurulumu')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!c.supported)
                  const _Note(
                    'USB seri kurulum yalnızca Windows masaüstü uygulamasında kullanılabilir.',
                    AppColors.warning,
                  )
                else ...[
                  if (s.error != null) _Note(s.error!, AppColors.error),
                  ..._body(s, c),
                  const SizedBox(height: 16),
                  _logPanel(s),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(UsbSetupState s, UsbSetupController c) {
    switch (s.step) {
      case UsbStep.selectPort:
        return _selectPort(s, c);
      case UsbStep.waitingBoot:
        return [
          _deviceCard(s),
          const SizedBox(height: 12),
          const _Card(children: [
            _Line('ESP32 üzerindeki BOOT düğmesine 3 saniye basılı tutup BIRAKIN.'),
            _Line('Mavi LED hızlı yanıp söner; kurulum penceresi 120 saniye açık kalır.'),
            _Line('Güvenlik: Kurulum komutları yalnızca bu fiziksel onayla kabul edilir.'),
          ]),
          const SizedBox(height: 12),
          const _Busy('BOOT düğmesine basmanız bekleniyor…'),
        ];
      case UsbStep.ready:
        return [
          _deviceCard(s),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: c.scan,
            icon: const Icon(Icons.wifi_find),
            label: const Text('Wi-Fi Ağlarını Tara'),
          ),
        ];
      case UsbStep.scanning:
        return [_deviceCard(s), const _Busy('ESP32 çevredeki 2.4 GHz ağları tarıyor…')];
      case UsbStep.networks:
        return _networks(s, c);
      case UsbStep.credentials:
        return _credentials(s, c);
      case UsbStep.connecting:
        return const [_Busy('ESP32 ağa bağlanıyor ve DHCP ile IP alıyor…')];
      case UsbStep.done:
        return _done(s, c);
    }
  }

  // ── Adımlar ───────────────────────────────────────────────────────────

  List<Widget> _selectPort(UsbSetupState s, UsbSetupController c) {
    return [
      const _Card(children: [
        _Line('ESP32\'yi USB kablosuyla bilgisayara bağlayın (veri destekleyen kablo).'),
        _Line('Arduino/PlatformIO seri monitörü gibi COM portunu kullanan programları kapatın.'),
        _Line('Port açıldığında bazı kartlar yeniden başlar; birkaç saniye sürebilir.'),
      ]),
      const SizedBox(height: 12),
      Row(
        children: [
          const Expanded(child: Text('COM port', style: TextStyle(fontWeight: FontWeight.bold))),
          IconButton(tooltip: 'Portları yenile', onPressed: c.refreshPorts, icon: const Icon(Icons.refresh)),
        ],
      ),
      if (s.ports.isEmpty)
        const _Note('Hiç seri port bulunamadı. Kablo bağlı mı? CP210x/CH340 sürücüsü yüklü mü?', AppColors.warning)
      else
        DropdownButtonFormField<String>(
          value: s.ports.any((p) => p.name == s.selectedPort) ? s.selectedPort : null,
          isExpanded: true,
          hint: const Text('Port seçin'),
          items: [
            for (final p in s.ports)
              DropdownMenuItem(
                value: p.name,
                child: Text(p.likelyEsp32 ? '${p.label}  ★ ESP32 olabilir' : p.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: s.busy ? null : c.selectPort,
        ),
      const SizedBox(height: 16),
      if (s.busy) _Busy(s.statusText ?? 'ESP32 aranıyor…'),
      Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: s.busy || s.selectedPort == null ? null : c.connect,
              icon: const Icon(Icons.usb),
              label: const Text('Bağlan'),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: s.busy ? null : c.autoDetect,
            icon: const Icon(Icons.search),
            label: const Text('Otomatik algıla'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _networks(UsbSetupState s, UsbSetupController c) {
    final tiles = <Widget>[];
    for (final g in s.networks) {
      final n = g.best;
      tiles.add(ListTile(
        enabled: n.isSupported,
        leading: Icon(n.isOpen ? Icons.lock_open : Icons.lock,
            color: n.isOpen ? AppColors.warning : AppColors.textSecondary),
        title: Text(g.ssid),
        subtitle: Text([
          n.isOpen ? 'Açık ağ' : n.security.replaceAll('_', ' '),
          if (g.accessPointCount > 1) '${g.accessPointCount} erişim noktası',
          if (!n.isSupported) 'Desteklenmiyor (kurumsal)',
        ].join(' • ')),
        trailing: SignalBars(bars: signalBars(n.rssi)),
        onTap: n.isSupported
            ? () {
                _ssidCtrl.text = g.ssid;
                _passCtrl.clear();
                _openNetwork = n.isOpen;
                c.selectNetwork(g.ssid);
              }
            : null,
      ));
    }
    return [
      Row(
        children: [
          const Expanded(child: Text('Wi-Fi ağınızı seçin', style: TextStyle(fontWeight: FontWeight.bold))),
          TextButton.icon(onPressed: c.scan, icon: const Icon(Icons.refresh), label: const Text('Yeniden tara')),
        ],
      ),
      const Text(
        'ESP32 yalnızca 2.4 GHz ağları görür.',
        style: TextStyle(fontSize: 12, color: AppColors.textHint),
      ),
      const SizedBox(height: 8),
      if (s.networks.isEmpty)
        const _Note('Hiç ağ bulunamadı. ESP32\'yi modeme yaklaştırın veya gizli ağ için SSID\'yi elle girin.', AppColors.warning),
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

  List<Widget> _credentials(UsbSetupState s, UsbSetupController c) {
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
              'Şifre yalnızca USB üzerinden ESP32\'ye gönderilir; uygulamada saklanmaz, loglanmaz. '
              'ESP32 bilgiyi bağlantı başarılı olunca NVS belleğine kaydeder.',
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
            TextButton(onPressed: c.backToNetworks, child: const Text('Ağ listesine dön')),
          ],
        ),
      ),
    ];
  }

  List<Widget> _done(UsbSetupState s, UsbSetupController c) {
    return [
      const Icon(Icons.check_circle, color: AppColors.success, size: 64),
      const SizedBox(height: 12),
      const Text('ESP32 Wi-Fi ağına bağlandı',
          textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      _Card(children: [
        _Line('Ağ: ${s.resultSsid ?? '-'}'),
        _Line('IP adresi: ${s.resultIp ?? '-'}'),
        const _Line('Bilgiler ESP32 NVS belleğine kaydedildi; yeniden başlatmada otomatik bağlanır.'),
      ]),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: () async {
          final nav = Navigator.of(context);
          final dev = c.lanDevice;
          await c.disconnectUsb();
          if (dev != null) {
            // Yerel ağ üzerinden eşleştirme (BOOT penceresi hâlâ açıksa otomatik) ve kontrol
            await nav.pushReplacement(
              MaterialPageRoute(builder: (_) => SetupScreen(device: dev, pairOnly: true)),
            );
          }
        },
        icon: const Icon(Icons.lan),
        label: const Text('Yerel ağ üzerinden kontrol et'),
      ),
    ];
  }

  Widget _deviceCard(UsbSetupState s) {
    final secs = (s.windowRemainingMs / 1000).ceil();
    final frac = (s.windowRemainingMs / 120000).clamp(0.0, 1.0);
    final wifi = switch (s.deviceWifiState) {
      'connected' => 'Wi-Fi\'a bağlı${s.deviceSsid != null ? ' (${s.deviceSsid})' : ''}'
          '${s.deviceIp != null ? ', IP ${s.deviceIp}' : ''}',
      'connecting' => 'Wi-Fi\'a bağlanıyor…',
      'ap' => 'Kurulum modunda (SoftAP)',
      'failed' => 'Wi-Fi bağlantısı başarısız',
      final other => other ?? '-',
    };
    return _Card(children: [
      _Line('Bağlı: ${s.selectedPort ?? ''}  •  ${s.deviceId ?? ''}  •  yazılım ${s.fw ?? ''}'),
      _Line('ESP32 şu an: $wifi'),
      Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(s.windowOpen ? Icons.lock_open : Icons.lock,
                    size: 18, color: s.windowOpen ? AppColors.success : AppColors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.windowOpen
                        ? 'BOOT yetkilendirmesi AÇIK — $secs sn kaldı'
                        : 'BOOT yetkilendirmesi KAPALI — BOOT düğmesine 3 sn basılı tutup bırakın',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: s.windowOpen ? AppColors.success : AppColors.warning,
                    ),
                  ),
                ),
              ],
            ),
            if (s.windowOpen) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(value: frac, minHeight: 4),
            ],
          ],
        ),
      ),
    ]);
  }

  /// Seri iletişim hata ayıklama günlüğü (Wi-Fi şifresi/SSID maskelidir).
  Widget _logPanel(UsbSetupState s) {
    final text = s.logLines.join('\n');
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: ExpansionTile(
        title: Text('Seri iletişim günlüğü (${s.logLines.length})', style: const TextStyle(fontSize: 14)),
        subtitle: const Text('Şifre ve ağ adları günlüğe yazılmaz', style: TextStyle(fontSize: 11)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: SelectableText(
                      text.isEmpty ? '(boş)' : text,
                      style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: text.isEmpty ? null : () => Clipboard.setData(ClipboardData(text: text)),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Kopyala'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );
}

class _Line extends StatelessWidget {
  const _Line(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(6), child: Text(text));
}

class _Note extends StatelessWidget {
  const _Note(this.text, this.color);
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
  const _Busy(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
        ]),
      );
}
