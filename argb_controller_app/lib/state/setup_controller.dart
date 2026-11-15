import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/services/device_api.dart';
import 'package:argb_controller/services/device_discovery.dart';
import 'package:argb_controller/services/token_store.dart';
import 'package:argb_controller/state/connection_controller.dart' show ApiFactory;

enum SetupStep {
  intro, // SoftAP'ye bağlanma yönergesi
  connectAp, // 192.168.4.1 aranıyor
  pairing, // BOOT düğmesi ile fiziksel onay
  scan, // Wi-Fi ağı seçimi
  credentials, // SSID/şifre
  connecting, // ESP32 modeme bağlanıyor
  rediscover, // ESP32 yerel ağda yeniden aranıyor
  done,
}

class SetupState {
  final SetupStep step;
  final bool busy;
  final String? error;
  final String? info;
  final FoundDevice? device; // kurulum sırasındaki (AP) cihaz
  final List<WifiNetworkGroup> networks;
  final bool scanning;
  final bool scanDone;
  final String? selectedSsid;
  final FoundDevice? finalDevice; // yerel ağda yeniden bulunan cihaz
  final bool needsPhoneNetwork; // telefonun ev ağına dönmesi gerekiyor
  final bool pairingWindowSeen;

  const SetupState({
    this.step = SetupStep.intro,
    this.busy = false,
    this.error,
    this.info,
    this.device,
    this.networks = const [],
    this.scanning = false,
    this.scanDone = false,
    this.selectedSsid,
    this.finalDevice,
    this.needsPhoneNetwork = false,
    this.pairingWindowSeen = false,
  });

  SetupState copyWith({
    SetupStep? step,
    bool? busy,
    String? error,
    bool clearError = false,
    String? info,
    bool clearInfo = false,
    FoundDevice? device,
    List<WifiNetworkGroup>? networks,
    bool? scanning,
    bool? scanDone,
    String? selectedSsid,
    bool clearSelected = false,
    FoundDevice? finalDevice,
    bool? needsPhoneNetwork,
    bool? pairingWindowSeen,
  }) {
    return SetupState(
      step: step ?? this.step,
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
      info: clearInfo ? null : (info ?? this.info),
      device: device ?? this.device,
      networks: networks ?? this.networks,
      scanning: scanning ?? this.scanning,
      scanDone: scanDone ?? this.scanDone,
      selectedSsid: clearSelected ? null : (selectedSsid ?? this.selectedSsid),
      finalDevice: finalDevice ?? this.finalDevice,
      needsPhoneNetwork: needsPhoneNetwork ?? this.needsPhoneNetwork,
      pairingWindowSeen: pairingWindowSeen ?? this.pairingWindowSeen,
    );
  }
}

class SetupTuning {
  final Duration poll;
  final Duration pairingTimeout;
  final Duration scanTimeout;
  final Duration connectTimeout;
  final Duration rediscoverTimeout;
  const SetupTuning({
    this.poll = const Duration(seconds: 1),
    this.pairingTimeout = const Duration(seconds: 180),
    this.scanTimeout = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 45),
    this.rediscoverTimeout = const Duration(seconds: 60),
  });
}

/// İlk kurulum / Wi-Fi değiştirme sihirbazının mantığı.
///
/// GÜVENLİK: Wi-Fi şifresi yalnızca [connectToWifi] parametresi olarak geçer;
/// state'e, loglara veya kalıcı depoya yazılmaz.
class SetupController extends StateNotifier<SetupState> {
  SetupController({
    required this.tokens,
    required this.discovery,
    required this.clientName,
    this.onDeviceKnown,
    ApiFactory? apiFactory,
    this.tuning = const SetupTuning(),
    SetupStep initialStep = SetupStep.intro,
    FoundDevice? device,
    this.pairOnly = false,
  })  : _apiFactory = apiFactory ?? ((d, t) => DeviceApi(host: d.host, port: d.port, token: t)),
        super(SetupState(step: initialStep, device: device));

  final TokenStore tokens;
  final DeviceDiscovery discovery;
  final String clientName;
  final void Function(FoundDevice device)? onDeviceKnown;
  final SetupTuning tuning;
  final ApiFactory _apiFactory;
  /// true: yalnızca eşleştirme yapılır (cihaz zaten yerel ağda); Wi-Fi adımları atlanır.
  final bool pairOnly;
  bool _cancel = false;
  String? _token;

  static const String _noToken = '';

  DeviceApi _api(FoundDevice d) => _apiFactory(d, _token ?? _noToken);

  // ── 1) SoftAP'yi bul ──────────────────────────────────────────────────

  Future<void> goToConnectAp() async {
    state = state.copyWith(step: SetupStep.connectAp, clearError: true, busy: true);
    await probeAp();
  }

  Future<void> probeAp() async {
    state = state.copyWith(busy: true, clearError: true);
    FoundDevice? found;
    for (var i = 0; i < 3 && !_cancel && found == null; i++) {
      found = await discovery.probe(kSetupApHost);
    }
    if (_cancel || !mounted) return;
    if (found == null) {
      state = state.copyWith(
        busy: false,
        error: 'Kurulum ağındaki ESP32 bulunamadı. Telefonunuzun ESP32-ARGB-Setup-… '
            'ağına bağlı olduğundan emin olun (mobil veriyi kapatmak gerekebilir).',
      );
      return;
    }
    state = state.copyWith(device: found, busy: false);
    await _afterDeviceReached(found);
  }

  /// Bilinen bir cihazla başlar (token varsa taramaya/bitişe, yoksa eşleştirmeye).
  Future<void> startForDevice(FoundDevice dev) async {
    state = state.copyWith(device: dev, busy: true, clearError: true);
    if (pairOnly) {
      _token = await tokens.read(dev.id);
      if (_token != null) {
        state = state.copyWith(step: SetupStep.done, busy: false, finalDevice: dev);
        return;
      }
      state = state.copyWith(step: SetupStep.pairing, busy: false);
      unawaited(watchPairing());
      return;
    }
    await _afterDeviceReached(dev);
  }

  /// Cihaz erişilebilir olduktan sonra: token varsa taramaya, yoksa eşleştirmeye geç.
  Future<void> _afterDeviceReached(FoundDevice dev) async {
    _token = await tokens.read(dev.id);
    if (_token != null) {
      // Token hâlâ geçerli mi?
      final api = _api(dev);
      try {
        await api.info();
        api.close();
        state = state.copyWith(step: SetupStep.scan, clearError: true);
        unawaited(scan());
        return;
      } on ApiException catch (e) {
        api.close();
        if (e.code == 'unauthorized') {
          await tokens.delete(dev.id);
          _token = null;
        } else {
          state = state.copyWith(error: describeApiError(e));
          return;
        }
      }
    }
    state = state.copyWith(step: SetupStep.pairing, clearError: true);
    unawaited(watchPairing());
  }

  // ── 2) Fiziksel eşleştirme ────────────────────────────────────────────

  /// BOOT penceresi açılana kadar yoklar; açılınca token alır.
  Future<void> watchPairing() async {
    final dev = state.device;
    if (dev == null) return;
    state = state.copyWith(busy: true, clearError: true, pairingWindowSeen: false);
    final deadline = DateTime.now().add(tuning.pairingTimeout);
    final api = _api(dev);
    try {
      while (!_cancel && mounted && DateTime.now().isBefore(deadline)) {
        try {
          final d = await api.discover();
          if (d.pairingOpen) {
            state = state.copyWith(pairingWindowSeen: true);
            final res = await api.pair(clientName);
            await tokens.write(dev.id, res.token);
            _token = res.token;
            onDeviceKnown?.call(dev);
            if (pairOnly) {
              state = state.copyWith(step: SetupStep.done, busy: false, finalDevice: dev, clearError: true);
              return;
            }
            state = state.copyWith(step: SetupStep.scan, busy: false, clearError: true);
            unawaited(scan());
            return;
          }
        } on ApiException catch (e) {
          // Pencere tam bu sırada kapandıysa döngüye devam; kalıcı hatalar gösterilir.
          if (e.code != 'pairing_closed' && !e.isNetwork) {
            state = state.copyWith(busy: false, error: describeApiError(e));
            return;
          }
        }
        await Future<void>.delayed(tuning.poll);
      }
      if (!_cancel && mounted) {
        state = state.copyWith(
          busy: false,
          error: 'Eşleştirme zaman aşımına uğradı. BOOT düğmesine 3 saniye basılı tutup bırakın, '
              'sonra tekrar deneyin.',
        );
      }
    } finally {
      api.close();
    }
  }

  // ── 3) Wi-Fi tarama ───────────────────────────────────────────────────

  Future<void> scan() async {
    final dev = state.device;
    if (dev == null || _token == null) return;
    state = state.copyWith(scanning: true, scanDone: false, clearError: true);
    final api = _api(dev);
    try {
      await api.startWifiScan();
      final deadline = DateTime.now().add(tuning.scanTimeout);
      while (!_cancel && mounted && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(tuning.poll);
        final r = await api.getWifiScan();
        if (!r.running) {
          state = state.copyWith(
            scanning: false,
            scanDone: true,
            networks: groupNetworks(r.networks),
          );
          return;
        }
      }
      if (mounted) {
        state = state.copyWith(
          scanning: false,
          scanDone: true,
          error: 'Tarama zaman aşımına uğradı. Tekrar deneyin.',
        );
      }
    } on ApiException catch (e) {
      if (mounted) state = state.copyWith(scanning: false, scanDone: true, error: describeApiError(e));
    } finally {
      api.close();
    }
  }

  void selectNetwork(String ssid) {
    state = state.copyWith(
      step: SetupStep.credentials,
      selectedSsid: ssid,
      clearError: true,
    );
  }

  void selectHidden() {
    state = state.copyWith(step: SetupStep.credentials, clearSelected: true, clearError: true);
  }

  void backToScan() {
    state = state.copyWith(step: SetupStep.scan, clearError: true);
  }

  // ── 4) Bağlan ─────────────────────────────────────────────────────────

  /// Şifre yalnızca istek gövdesinde gider. Boş şifre = açık ağ.
  Future<void> connectToWifi(String ssid, String password) async {
    final dev = state.device;
    if (dev == null || _token == null) return;
    state = state.copyWith(
      step: SetupStep.connecting,
      busy: true,
      clearError: true,
      info: 'ESP32 "$ssid" ağına bağlanıyor…',
    );
    final api = _api(dev);
    try {
      await api.connectWifi(ssid, password);
    } on ApiException catch (e) {
      api.close();
      state = state.copyWith(step: SetupStep.credentials, busy: false, error: describeApiError(e), clearInfo: true);
      return;
    }

    final deadline = DateTime.now().add(tuning.connectTimeout);
    var netErrors = 0;
    try {
      while (!_cancel && mounted && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(tuning.poll);
        try {
          final s = await api.wifiStatus();
          netErrors = 0;
          if (s.state == WifiConnState.connected) {
            state = state.copyWith(info: 'Bağlandı. ESP32 yerel ağda aranıyor…');
            await rediscover(expectedIp: s.ip);
            return;
          }
          if (s.state == WifiConnState.failed || (s.error != null && s.state != WifiConnState.connecting)) {
            state = state.copyWith(
              step: SetupStep.credentials,
              busy: false,
              error: describeWifiError(s.error),
              clearInfo: true,
            );
            return;
          }
        } on ApiException catch (e) {
          if (!e.isNetwork) rethrow;
          // Bağlanırken ESP32'nin SoftAP kanalı değişir; telefon AP'den düşebilir (beklenen).
          netErrors++;
          if (netErrors >= 3) {
            state = state.copyWith(
              info: 'Kurulum ağı ile bağlantı kesildi (beklenen). ESP32 yerel ağda aranıyor…',
            );
            await rediscover();
            return;
          }
        }
      }
      state = state.copyWith(
        step: SetupStep.credentials,
        busy: false,
        error: describeWifiError('timeout'),
        clearInfo: true,
      );
    } on ApiException catch (e) {
      state = state.copyWith(step: SetupStep.credentials, busy: false, error: describeApiError(e), clearInfo: true);
    } finally {
      api.close();
    }
  }

  // ── 5) Yerel ağda yeniden bul ─────────────────────────────────────────

  Future<void> rediscover({String? expectedIp}) async {
    final dev = state.device;
    if (dev == null) return;
    state = state.copyWith(step: SetupStep.rediscover, busy: true, clearError: true, needsPhoneNetwork: false);
    final deadline = DateTime.now().add(tuning.rediscoverTimeout);
    while (!_cancel && mounted && DateTime.now().isBefore(deadline)) {
      final extra = [if (expectedIp != null && expectedIp.isNotEmpty) expectedIp];
      final found = await discovery.findById(dev.id, timeout: const Duration(seconds: 5), extraHosts: extra);
      if (_cancel || !mounted) return;
      if (found != null && !found.isSetupAp) {
        onDeviceKnown?.call(found);
        state = state.copyWith(step: SetupStep.done, busy: false, finalDevice: found, clearInfo: true);
        return;
      }
      await Future<void>.delayed(tuning.poll);
    }
    if (!mounted) return;
    state = state.copyWith(
      busy: false,
      needsPhoneNetwork: true,
      error: 'ESP32 yerel ağda bulunamadı. Telefonunuzu ev Wi-Fi ağınıza geri bağlayıp tekrar deneyin.',
    );
  }

  /// Telefon ağı değiştirildikten sonra elle yeniden arama.
  Future<void> retryRediscover() => rediscover();

  void backToIntro() {
    state = SetupState(device: state.device);
  }

  @override
  void dispose() {
    _cancel = true;
    super.dispose();
  }
}
