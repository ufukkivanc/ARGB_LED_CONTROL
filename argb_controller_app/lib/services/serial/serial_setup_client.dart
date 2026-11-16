import 'dart:async';
import 'dart:convert';

import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/services/serial/serial_debug_log.dart';
import 'package:argb_controller/services/serial/serial_transport.dart';

/// Tarama sonucu.
class ScanOutcome {
  final List<WifiNetwork> networks;
  final String? error; // window_closed | scan_busy | scan_timeout | timeout | ...
  const ScanOutcome({this.networks = const [], this.error});
  bool get ok => error == null;
}

/// Bağlanma sonucu.
class ConnectOutcome {
  final bool connected;
  final String? ssid;
  final String? ip;
  final String? error; // auth_failed | not_found | timeout | window_closed | invalid_* ...
  const ConnectOutcome({this.connected = false, this.ssid, this.ip, this.error});
}

/// Cihazın "hello/status" yanıtı.
class SerialDeviceStatus {
  final String deviceId;
  final String fw;
  final bool window;
  final int remainingMs;
  final String state;
  final String? ssid;
  final String? ip;
  final String? error;
  const SerialDeviceStatus({
    required this.deviceId,
    required this.fw,
    required this.window,
    required this.remainingMs,
    required this.state,
    this.ssid,
    this.ip,
    this.error,
  });

  static SerialDeviceStatus? tryParse(Map m) {
    if (m['deviceId'] is! String) return null;
    return SerialDeviceStatus(
      deviceId: m['deviceId'] as String,
      fw: (m['fw'] as String?) ?? '',
      window: m['window'] == true,
      remainingMs: (m['remainingMs'] as num?)?.toInt() ?? 0,
      state: (m['state'] as String?) ?? 'unknown',
      ssid: m['ssid'] as String?,
      ip: m['ip'] as String?,
      error: m['error'] as String?,
    );
  }
}

/// ESP32 USB seri kurulum protokolü istemcisi (firmware: serial_provisioning.cpp).
///
/// Çerçeveleme: satır tabanlı JSON. Cihaz yanıtı iki biçimde kabul edilir:
///  1. `ARGB:{...}`  (güncel firmware, log satırlarıyla karışmayı önlemek için önekli)
///  2. `{...}`       (önek taşımayan çıplak JSON — bazı firmware sürümleri böyle yanıt verir)
/// Yanıt sayılması için JSON nesnesinin string bir `type` alanı olmalıdır; diğer satırlar
/// (boot/heartbeat logları) ve bozuk satırlar yok sayılır, böylece seri monitör logları protokolü bozmaz.
///
/// GÜVENLİK: Wi-Fi şifresi yalnızca [connectWifi] içinde bir kez kodlanıp yazılır;
/// saklanmaz ve hata ayıklama günlüğüne yazılmaz ([SerialDebugLog] maskeler).
class SerialSetupClient {
  SerialSetupClient(this._transport, {SerialDebugLog? log}) : _log = log {
    _sub = _transport.data.listen(_onData, onError: (_) {});
  }

  final SerialTransport _transport;
  final SerialDebugLog? _log;
  late final StreamSubscription<List<int>> _sub;
  final List<int> _buf = [];
  final _messages = StreamController<Map<String, dynamic>>.broadcast();

  /// Port açıldıktan sonra cihazın yeniden başladığına dair işaret görüldü mü?
  bool sawBoot = false;

  Stream<Map<String, dynamic>> get messages => _messages.stream;

  static const _maxBuffer = 16 * 1024;

  /// Bir satırdan protokol mesajını çıkarır (önekli veya çıplak JSON); yoksa null.
  static Map<String, dynamic>? parseProtocolLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return null;
    final pre = t.indexOf('ARGB:');
    final start = pre >= 0 ? pre + 5 : t.indexOf('{');
    if (start < 0 || start >= t.length) return null;
    try {
      final j = jsonDecode(t.substring(start).trim());
      if (j is Map<String, dynamic> && j['type'] is String) return j;
    } catch (_) {
      // log satırıyla iç içe geçmiş/bozuk satır
    }
    return null;
  }

  static bool _looksLikeBoot(String line) =>
      line.contains('rst:0x') ||
      line.contains('ets Jul') ||
      line.contains('ESP32 Smart ARGB Controller - Firmware') ||
      line.contains('All systems initialized');

  void _onData(List<int> bytes) {
    _buf.addAll(bytes);
    if (_buf.length > _maxBuffer) _buf.removeRange(0, _buf.length - _maxBuffer);
    while (true) {
      final nl = _buf.indexOf(10);
      if (nl < 0) break;
      final line = utf8.decode(_buf.sublist(0, nl), allowMalformed: true).trim();
      _buf.removeRange(0, nl + 1);
      if (line.isEmpty) continue;
      final msg = parseProtocolLine(line);
      if (msg != null) {
        _log?.add('◀', line);
        _messages.add(msg);
      } else {
        if (_looksLikeBoot(line)) {
          sawBoot = true;
          _log?.note('ESP32 yeniden başlıyor (boot günlüğü algılandı)');
        } else if (!line.startsWith('[Heartbeat]')) {
          _log?.add('··', line); // cihaz log satırı (şifre satırları maskelenir)
        }
      }
    }
  }

  void _send(Map<String, dynamic> cmd) {
    final text = jsonEncode(cmd);
    _log?.add('▶', text); // wifi komutu tamamen maskelenir
    _transport.write(utf8.encode('$text\n'));
  }

  /// İlk eşleşen mesajı (veya `error`) bekler. Dinleme, gönderimden ÖNCE başlar.
  Future<Map<String, dynamic>?> _request(
    Map<String, dynamic> cmd,
    Set<String> types, {
    Duration timeout = const Duration(seconds: 3),
  }) {
    final c = Completer<Map<String, dynamic>?>();
    late StreamSubscription<Map<String, dynamic>> sub;
    final timer = Timer(timeout, () {
      if (!c.isCompleted) c.complete(null);
    });
    sub = messages.listen((m) {
      if (types.contains(m['type']) || m['type'] == 'error') {
        if (!c.isCompleted) c.complete(m);
      }
    });
    _send(cmd);
    return c.future.whenComplete(() {
      timer.cancel();
      sub.cancel();
    });
  }

  /// Cihaz yanıt verene kadar dener. Port açılınca bazı kartlar yeniden başlar (boot ≈ 3–6 sn);
  /// bu yüzden varsayılan toplam bekleme ≈ 15 sn'dir. [onProgress]: (deneme, toplam, bootGörüldü).
  Future<SerialDeviceStatus?> hello({
    int attempts = 15,
    Duration perAttempt = const Duration(milliseconds: 1000),
    void Function(int attempt, int total, bool booting)? onProgress,
  }) async {
    for (var i = 0; i < attempts; i++) {
      onProgress?.call(i + 1, attempts, sawBoot);
      final m = await _request({'cmd': 'hello'}, {'hello'}, timeout: perAttempt);
      if (m != null && m['type'] == 'hello') return SerialDeviceStatus.tryParse(m);
    }
    return null;
  }

  Future<SerialDeviceStatus?> status({Duration timeout = const Duration(milliseconds: 1500)}) async {
    final m = await _request({'cmd': 'status'}, {'status'}, timeout: timeout);
    if (m != null && m['type'] == 'status') return SerialDeviceStatus.tryParse(m);
    return null;
  }

  /// ESP32'nin kendi Wi-Fi donanımıyla çevredeki 2.4 GHz ağları tarar.
  Future<ScanOutcome> scan({Duration timeout = const Duration(seconds: 28)}) async {
    final m = await _request({'cmd': 'scan'}, {'scanResult'}, timeout: timeout);
    if (m == null) return const ScanOutcome(error: 'timeout');
    if (m['type'] == 'error') return ScanOutcome(error: (m['code'] as String?) ?? 'error');
    final nets = <WifiNetwork>[];
    final raw = m['networks'];
    if (raw is List) {
      for (final n in raw) {
        final p = WifiNetwork.tryParse(n);
        if (p != null) nets.add(p);
      }
    }
    return ScanOutcome(networks: nets);
  }

  /// Bilgiyi gönderir; cihazın bağlanma sonucunu (başarı + IP veya hata) bekler.
  Future<ConnectOutcome> connectWifi(
    String ssid,
    String password, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final done = Completer<ConnectOutcome>();
    late StreamSubscription<Map<String, dynamic>> sub;
    var accepted = false;
    final timer = Timer(timeout, () async {
      if (done.isCompleted) return;
      // Olay kaçmış olabilir: durumu sor
      final st = await status();
      if (done.isCompleted) return;
      if (st != null && st.state == 'connected') {
        done.complete(ConnectOutcome(connected: true, ssid: st.ssid, ip: st.ip));
      } else {
        done.complete(const ConnectOutcome(error: 'timeout'));
      }
    });
    sub = messages.listen((m) {
      if (done.isCompleted) return;
      switch (m['type']) {
        case 'error':
          done.complete(ConnectOutcome(error: (m['code'] as String?) ?? 'error'));
        case 'wifiAccepted':
          accepted = true;
        case 'event':
          if (!accepted) return;
          if (m['state'] == 'connected') {
            done.complete(ConnectOutcome(connected: true, ssid: m['ssid'] as String?, ip: m['ip'] as String?));
          } else if (m['state'] == 'failed') {
            done.complete(ConnectOutcome(error: (m['error'] as String?) ?? 'failed'));
          }
      }
    });
    _send({'cmd': 'wifi', 'ssid': ssid, 'pass': password});
    return done.future.whenComplete(() {
      timer.cancel();
      sub.cancel();
    });
  }

  Future<void> close() async {
    await _sub.cancel();
    await _messages.close();
    await _transport.close();
  }
}

/// Kurulum hata kodunu Türkçe metne çevirir.
String describeSerialError(String? code) {
  switch (code) {
    case 'window_closed':
      return 'Kurulum penceresi kapalı. ESP32 üzerindeki BOOT düğmesine 3 saniye basılı tutup bırakın.';
    case 'scan_busy':
      return 'ESP32 başka bir tarama yapıyor. Birkaç saniye sonra tekrar deneyin.';
    case 'scan_timeout':
    case 'timeout':
      return 'Cihaz zamanında yanıt vermedi.';
    case 'invalid_ssid':
      return 'Geçersiz ağ adı (1–32 bayt olmalı).';
    case 'invalid_password':
      return 'Geçersiz şifre (açık ağ için boş, aksi halde 8–63 karakter).';
    case 'auth_failed':
    case 'not_found':
      return describeWifiError(code);
    case 'failed':
      return 'Bağlantı kurulamadı.';
    case 'bad_json':
    case 'unknown_cmd':
    case 'missing_cmd':
    case 'line_too_long':
      return 'Cihaz komutu anlamadı ($code). Firmware sürümünü kontrol edin.';
    default:
      return 'Cihaz hatası: ${code ?? 'bilinmiyor'}';
  }
}
