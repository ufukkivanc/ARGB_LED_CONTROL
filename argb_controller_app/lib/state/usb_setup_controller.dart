import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/services/device_discovery.dart';
import 'package:argb_controller/services/serial/serial_backend.dart';
import 'package:argb_controller/services/serial/serial_debug_log.dart';
import 'package:argb_controller/services/serial/serial_setup_client.dart';
import 'package:argb_controller/services/serial/serial_transport.dart';

enum UsbStep {
  selectPort, // COM port seçimi / algılama
  waitingBoot, // BOOT düğmesiyle fiziksel yetkilendirme bekleniyor
  ready, // pencere açık; "Wi-Fi Ağlarını Tara"
  scanning,
  networks,
  credentials,
  connecting,
  done,
}

class UsbSetupState {
  final UsbStep step;
  final List<SerialPortInfo> ports;
  final String? selectedPort;
  final bool busy;
  final String? error;
  final String? statusText; // "ESP32 yeniden başlıyor, bekleniyor… (3/15)" gibi ilerleme
  final String? deviceId;
  final String? fw;
  final bool windowOpen; // BOOT yetkilendirme penceresi
  final int windowRemainingMs;
  final String? deviceWifiState; // ESP32'nin şu anki Wi-Fi durumu
  final String? deviceSsid;
  final String? deviceIp;
  final List<WifiNetworkGroup> networks;
  final String? selectedSsid; // null: gizli ağ (elle)
  final String? resultSsid;
  final String? resultIp;
  final List<String> logLines;

  const UsbSetupState({
    this.step = UsbStep.selectPort,
    this.ports = const [],
    this.selectedPort,
    this.busy = false,
    this.error,
    this.statusText,
    this.deviceId,
    this.fw,
    this.windowOpen = false,
    this.windowRemainingMs = 0,
    this.deviceWifiState,
    this.deviceSsid,
    this.deviceIp,
    this.networks = const [],
    this.selectedSsid,
    this.resultSsid,
    this.resultIp,
    this.logLines = const [],
  });

  UsbSetupState copyWith({
    UsbStep? step,
    List<SerialPortInfo>? ports,
    String? selectedPort,
    bool? busy,
    String? error,
    bool clearError = false,
    String? statusText,
    bool clearStatusText = false,
    String? deviceId,
    String? fw,
    bool? windowOpen,
    int? windowRemainingMs,
    String? deviceWifiState,
    String? deviceSsid,
    String? deviceIp,
    List<WifiNetworkGroup>? networks,
    String? selectedSsid,
    bool clearSelected = false,
    String? resultSsid,
    String? resultIp,
    List<String>? logLines,
  }) {
    return UsbSetupState(
      step: step ?? this.step,
      ports: ports ?? this.ports,
      selectedPort: selectedPort ?? this.selectedPort,
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
      statusText: clearStatusText ? null : (statusText ?? this.statusText),
      deviceId: deviceId ?? this.deviceId,
      fw: fw ?? this.fw,
      windowOpen: windowOpen ?? this.windowOpen,
      windowRemainingMs: windowRemainingMs ?? this.windowRemainingMs,
      deviceWifiState: deviceWifiState ?? this.deviceWifiState,
      deviceSsid: deviceSsid ?? this.deviceSsid,
      deviceIp: deviceIp ?? this.deviceIp,
      networks: networks ?? this.networks,
      selectedSsid: clearSelected ? null : (selectedSsid ?? this.selectedSsid),
      resultSsid: resultSsid ?? this.resultSsid,
      resultIp: resultIp ?? this.resultIp,
      logLines: logLines ?? this.logLines,
    );
  }
}

class UsbTuning {
  /// Durum yoklama aralığı (BOOT penceresi geri sayımı bu yoklamayla güncellenir).
  final Duration bootPoll;
  final Duration bootTimeout;
  final int helloAttempts;
  final Duration helloPerAttempt;

  /// Geçici tarama hatalarında (scan_busy, scan_failed, scan_timeout, yanıt yok) ek deneme sayısı.
  final int scanRetries;
  final Duration scanRetryDelay;
  final Duration scanTimeout;
  const UsbTuning({
    this.bootPoll = const Duration(seconds: 1),
    this.bootTimeout = const Duration(seconds: 180),
    this.helloAttempts = 15, // port açılınca kart yeniden başlayabilir (≈ 3–6 sn)
    this.helloPerAttempt = const Duration(seconds: 1),
    this.scanRetries = 2,
    this.scanRetryDelay = const Duration(seconds: 2),
    this.scanTimeout = const Duration(seconds: 50),
  });
}

/// USB seri port ile ilk Wi-Fi kurulumu (Windows masaüstü).
///
/// GÜVENLİK: Şifre yalnızca [connectToWifi] parametresidir; state'e/günlüğe yazılmaz.
/// Kurulum komutları ESP32 tarafında yalnızca BOOT penceresi açıkken kabul edilir.
class UsbSetupController extends StateNotifier<UsbSetupState> {
  UsbSetupController(this._backend, {this.tuning = const UsbTuning()}) : super(const UsbSetupState()) {
    _log = SerialDebugLog(onChanged: _onLogChanged);
    refreshPorts();
  }

  final SerialBackend _backend;
  final UsbTuning tuning;
  late final SerialDebugLog _log;
  SerialSetupClient? _client;
  Timer? _watcher;
  bool _cancel = false;
  bool _cmdBusy = false; // tarama/bağlanma sürerken durum yoklaması yapılmaz
  bool _polling = false;
  DateTime? _waitStarted;

  bool get supported => _backend.supported;

  void _onLogChanged() {
    if (mounted) state = state.copyWith(logLines: _log.lines);
  }

  // ── Port algılama ─────────────────────────────────────────────────────

  void refreshPorts() {
    final ports = _backend.listPorts();
    String? sel = state.selectedPort;
    if (sel == null || !ports.any((p) => p.name == sel)) {
      final likely = ports.where((p) => p.likelyEsp32).toList();
      sel = likely.length == 1 ? likely.first.name : (ports.length == 1 ? ports.first.name : null);
    }
    state = state.copyWith(ports: ports, selectedPort: sel, clearError: true);
  }

  void selectPort(String? name) {
    state = name == null ? state.copyWith(clearError: true) : state.copyWith(selectedPort: name, clearError: true);
  }

  /// ESP32 benzeri (USB-UART köprülü) portlara sırayla `hello` göndererek cihazı bulur.
  Future<void> autoDetect() async {
    refreshPorts();
    final candidates = state.ports.where((p) => p.likelyEsp32).toList();
    if (candidates.isEmpty) {
      state = state.copyWith(
          error: 'ESP32 benzeri USB seri port bulunamadı. Kartın USB ile bağlı ve sürücüsünün (CP210x/CH340) yüklü olduğundan emin olun.');
      return;
    }
    state = state.copyWith(busy: true, clearError: true);
    for (final p in candidates) {
      if (_cancel || !mounted) return;
      final ok = await _tryOpen(p.name, quick: true);
      if (ok) return;
    }
    if (mounted) {
      state = state.copyWith(
        busy: false,
        clearStatusText: true,
        error: 'Hiçbir portta ESP32 ARGB denetleyicisi yanıt vermedi. Portu elle seçip "Bağlan"ı deneyin '
            '(kart yeniden başlıyorsa birkaç saniye sürebilir).',
      );
    }
  }

  Future<void> connect() async {
    final name = state.selectedPort;
    if (name == null) {
      state = state.copyWith(error: 'Önce bir COM port seçin.');
      return;
    }
    state = state.copyWith(busy: true, clearError: true);
    final ok = await _tryOpen(name, quick: false);
    if (!ok && mounted && state.error == null) {
      state = state.copyWith(busy: false, clearStatusText: true, error: 'ESP32 yanıt vermedi.');
    }
  }

  Future<bool> _tryOpen(String name, {required bool quick}) async {
    await _closeClient();
    _log.clear();
    _log.note('$name açılıyor (115200 baud)');
    SerialTransport t;
    try {
      t = await _backend.open(name);
    } on SerialException catch (e) {
      _log.note('port açılamadı: ${e.message}');
      if (!quick && mounted) state = state.copyWith(busy: false, clearStatusText: true, error: e.message);
      return false;
    } catch (_) {
      _log.note('port açılamadı (beklenmeyen hata)');
      if (!quick && mounted) {
        state = state.copyWith(busy: false, clearStatusText: true, error: 'Port açılamadı: $name');
      }
      return false;
    }
    final client = SerialSetupClient(t, log: _log);
    _client = client;
    state = state.copyWith(statusText: 'ESP32 yanıtı bekleniyor…');

    final hello = await client.hello(
      attempts: quick ? 4 : tuning.helloAttempts,
      perAttempt: tuning.helloPerAttempt,
      onProgress: (i, n, booting) {
        if (!mounted) return;
        state = state.copyWith(
          statusText: booting
              ? 'ESP32 yeniden başlıyor, bekleniyor… ($i/$n)'
              : 'ESP32 yanıtı bekleniyor… ($i/$n)',
        );
      },
    );
    if (hello == null) {
      _log.note('hello yanıtı alınamadı');
      await _closeClient();
      if (!quick && mounted) {
        state = state.copyWith(
          busy: false,
          clearStatusText: true,
          error: 'ESP32 yanıt vermedi. Doğru port mu? Seri monitör kapalı mı? '
              'Firmware\'in USB kurulum özelliğini içeren sürümü yüklü mü? Ayrıntı için aşağıdaki günlüğe bakın.',
        );
      }
      return false;
    }
    if (!mounted) return true;
    _applyDeviceStatus(hello);
    state = state.copyWith(
      selectedPort: name,
      deviceId: hello.deviceId,
      fw: hello.fw,
      busy: false,
      clearError: true,
      clearStatusText: true,
    );
    _waitStarted = DateTime.now();
    state = state.copyWith(step: hello.window ? UsbStep.ready : UsbStep.waitingBoot);
    _startWatcher();
    return true;
  }

  void _applyDeviceStatus(SerialDeviceStatus st) {
    state = state.copyWith(
      windowOpen: st.window,
      windowRemainingMs: st.remainingMs,
      deviceWifiState: st.state,
      deviceSsid: st.ssid,
      deviceIp: st.ip,
    );
  }

  // ── BOOT penceresi izleme (geri sayım) ────────────────────────────────

  void _startWatcher() {
    _watcher?.cancel();
    _watcher = Timer.periodic(tuning.bootPoll, (_) => _pollStatus());
  }

  Future<void> _pollStatus() async {
    if (_polling || _cmdBusy || _cancel || !mounted) return;
    final c = _client;
    if (c == null) return;
    final step = state.step;
    if (step != UsbStep.waitingBoot &&
        step != UsbStep.ready &&
        step != UsbStep.networks &&
        step != UsbStep.credentials) {
      return;
    }
    _polling = true;
    try {
      final st = await c.status(timeout: const Duration(milliseconds: 900));
      if (!mounted || _cancel) return;
      if (st == null) return; // tek bir kayıp yoklama önemli değil
      _applyDeviceStatus(st);
      if (st.window) {
        if (state.step == UsbStep.waitingBoot) {
          state = state.copyWith(step: UsbStep.ready, clearError: true);
        }
      } else if (state.step != UsbStep.waitingBoot) {
        _windowClosed();
      } else if (_waitStarted != null && DateTime.now().difference(_waitStarted!) > tuning.bootTimeout) {
        _watcher?.cancel();
        await _closeClient();
        if (mounted) {
          state = state.copyWith(
            step: UsbStep.selectPort,
            error: 'Kurulum penceresi açılmadı (zaman aşımı). BOOT düğmesine 3 sn basılı tutup bırakarak tekrar deneyin.',
          );
        }
      }
    } finally {
      _polling = false;
    }
  }

  void _windowClosed() {
    _waitStarted = DateTime.now();
    state = state.copyWith(
      step: UsbStep.waitingBoot,
      busy: false,
      windowOpen: false,
      windowRemainingMs: 0,
      error: describeSerialError('window_closed'),
    );
  }

  // ── Tarama ────────────────────────────────────────────────────────────

  /// Geçici sayılan (otomatik yeniden denenen) tarama hataları.
  static const _transientScanErrors = {'scan_busy', 'scan_failed', 'scan_timeout', 'timeout'};

  /// Ağları tarar. Tarama/bağlanma sürerken gelen ikinci çağrı yok sayılır (cihaza yeni istek gitmez).
  /// Geçici hatalarda [UsbTuning.scanRetries] kez otomatik yeniden dener.
  Future<void> scan() async {
    final c = _client;
    if (c == null || _cmdBusy) return;
    _cmdBusy = true;
    state = state.copyWith(step: UsbStep.scanning, busy: true, clearError: true, clearStatusText: true);
    try {
      final total = tuning.scanRetries + 1;
      ScanOutcome r = const ScanOutcome(error: 'timeout');
      for (var attempt = 1; attempt <= total; attempt++) {
        if (attempt > 1) {
          _log.note('tarama yeniden deneniyor ($attempt/$total): ${r.error}');
          state = state.copyWith(statusText: 'Tarama yeniden deneniyor… ($attempt/$total)');
          await Future<void>.delayed(tuning.scanRetryDelay);
          if (!mounted || _cancel || !identical(_client, c)) return;
        }
        r = await c.scan(timeout: tuning.scanTimeout);
        if (!mounted || _cancel) return;
        if (r.ok || !_transientScanErrors.contains(r.error)) break;
      }
      if (r.error == 'window_closed') {
        _windowClosed();
        return;
      }
      if (!r.ok) {
        state = state.copyWith(
          step: UsbStep.ready,
          busy: false,
          clearStatusText: true,
          error: describeSerialError(r.error),
        );
        return;
      }
      state = state.copyWith(
        step: UsbStep.networks,
        busy: false,
        clearStatusText: true,
        networks: groupNetworks(r.networks),
      );
    } finally {
      _cmdBusy = false;
    }
  }

  void selectNetwork(String ssid) =>
      state = state.copyWith(step: UsbStep.credentials, selectedSsid: ssid, clearError: true);

  void selectHidden() => state = state.copyWith(step: UsbStep.credentials, clearSelected: true, clearError: true);

  void backToNetworks() => state = state.copyWith(step: UsbStep.networks, clearError: true);

  // ── Bağlan ────────────────────────────────────────────────────────────

  /// Şifre boşsa açık ağ kabul edilir. Şifre saklanmaz ve günlüğe yazılmaz.
  Future<void> connectToWifi(String ssid, String password) async {
    final c = _client;
    if (c == null) return;
    _cmdBusy = true;
    state = state.copyWith(step: UsbStep.connecting, busy: true, clearError: true);
    try {
      final r = await c.connectWifi(ssid, password);
      if (!mounted) return;
      if (r.connected && r.ip != null && r.ip!.isNotEmpty) {
        _watcher?.cancel();
        state = state.copyWith(
          step: UsbStep.done,
          busy: false,
          resultSsid: r.ssid ?? ssid,
          resultIp: r.ip,
        );
        return;
      }
      if (r.error == 'window_closed') {
        _windowClosed();
        return;
      }
      state = state.copyWith(
        step: UsbStep.credentials,
        busy: false,
        error: describeSerialError(r.error),
      );
    } finally {
      _cmdBusy = false;
    }
  }

  /// Kurulum bitince yerel ağ üzerinden kullanılacak cihaz (eşleştirme sonraki adımdır).
  FoundDevice? get lanDevice {
    final id = state.deviceId;
    final ip = state.resultIp;
    if (id == null || ip == null) return null;
    return FoundDevice(id: id, name: 'ESP32 ARGB', host: ip, mode: 'sta', fw: state.fw ?? '');
  }

  Future<void> disconnectUsb() async {
    _watcher?.cancel();
    await _closeClient();
  }

  Future<void> _closeClient() async {
    final c = _client;
    _client = null;
    if (c != null) await c.close();
  }

  @override
  void dispose() {
    _cancel = true;
    _watcher?.cancel();
    final c = _client;
    _client = null;
    c?.close();
    super.dispose();
  }
}

final serialBackendProvider = Provider<SerialBackend>((ref) => createSerialBackend());

final usbSetupProvider = StateNotifierProvider.autoDispose<UsbSetupController, UsbSetupState>(
  (ref) => UsbSetupController(ref.read(serialBackendProvider)),
);
