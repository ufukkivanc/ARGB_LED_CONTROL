import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/services/device_api.dart';
import 'package:argb_controller/services/device_discovery.dart';
import 'package:argb_controller/services/device_socket.dart';
import 'package:argb_controller/services/token_store.dart';

enum LinkStatus {
  idle,
  connecting,
  authenticating,
  connected,
  reconnecting,
  needsPairing,
}

/// Uygulama modu: yerel simülasyon veya gerçek ESP32.
enum AppMode { simulation, device }

class DeviceConnection {
  final LinkStatus status;
  final FoundDevice? device;
  final DeviceInfo? info;
  final Map<int, ChannelState> channels;
  final int rev;
  final String? error;
  final int attempt;

  const DeviceConnection({
    this.status = LinkStatus.idle,
    this.device,
    this.info,
    this.channels = const {},
    this.rev = -1,
    this.error,
    this.attempt = 0,
  });

  bool get isConnected => status == LinkStatus.connected;

  DeviceConnection copyWith({
    LinkStatus? status,
    FoundDevice? device,
    DeviceInfo? info,
    Map<int, ChannelState>? channels,
    int? rev,
    String? error,
    bool clearError = false,
    int? attempt,
    bool clearInfo = false,
  }) {
    return DeviceConnection(
      status: status ?? this.status,
      device: device ?? this.device,
      info: clearInfo ? null : (info ?? this.info),
      channels: channels ?? this.channels,
      rev: rev ?? this.rev,
      error: clearError ? null : (error ?? this.error),
      attempt: attempt ?? this.attempt,
    );
  }
}

/// Zamanlama ayarları (testlerde kısaltılabilir).
class ConnectionTuning {
  final Duration throttle;
  final Duration authTimeout;
  final Duration connectTimeout;
  final Duration pingInterval;
  final Duration silenceTimeout;
  final Duration suppressRemote;
  final List<Duration> backoff;

  const ConnectionTuning({
    this.throttle = const Duration(milliseconds: 50), // en çok 20 mesaj/sn
    this.authTimeout = const Duration(seconds: 6),
    this.connectTimeout = const Duration(seconds: 5),
    this.pingInterval = const Duration(seconds: 15),
    this.silenceTimeout = const Duration(seconds: 40),
    this.suppressRemote = const Duration(milliseconds: 600),
    this.backoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
    ],
  });
}

typedef ApiFactory = DeviceApi Function(FoundDevice device, String token);

/// ESP32 ile WebSocket oturumunu yönetir: auth, state senkronu, throttle'lı komut
/// gönderimi, ping ve kontrollü yeniden bağlanma.
///
/// GÜVENLİK: Token yalnızca ilk `auth` mesajında gönderilir; hiçbir log/URL'ye yazılmaz.
class DeviceConnectionController extends StateNotifier<DeviceConnection> {
  DeviceConnectionController({
    required this.tokens,
    SocketFactory? socketFactory,
    this.discovery,
    ApiFactory? apiFactory,
    this.tuning = const ConnectionTuning(),
  })  : _socketFactory = socketFactory ?? defaultSocketFactory,
        _apiFactory = apiFactory ??
            ((d, t) => DeviceApi(host: d.host, port: d.port, token: t)),
        super(const DeviceConnection());

  final TokenStore tokens;
  final DeviceDiscovery? discovery;
  final ConnectionTuning tuning;
  final SocketFactory _socketFactory;
  final ApiFactory _apiFactory;

  FoundDevice? _target;
  bool _want = false;
  DeviceSocket? _sock;
  StreamSubscription<String>? _sub;
  Timer? _authTimer;
  Timer? _pingTimer;
  Timer? _retryTimer;
  Timer? _flushTimer;
  DateTime _lastMsg = DateTime.now();
  DateTime _lastFlush = DateTime.fromMillisecondsSinceEpoch(0);
  int _attempt = 0;
  int _idCounter = 0;
  int _session = 0; // eski oturumların geç gelen olaylarını yok saymak için

  final Map<int, Map<String, dynamic>> _pending = {};
  final Map<String, ({List<int> chs, Map<String, dynamic> fields})> _inFlight = {};
  final Map<int, Map<String, dynamic>> _lastSent = {};
  final Map<int, Map<String, ({DateTime at, dynamic value})>> _touched = {};

  int sentMessages = 0; // test/teşhis için

  // ── Genel API ─────────────────────────────────────────────────────────

  Future<void> connect(FoundDevice device) async {
    await _teardown(keepWant: false);
    _target = device;
    _want = true;
    _attempt = 0;
    state = DeviceConnection(status: LinkStatus.connecting, device: device);
    await _open();
  }

  /// Kullanıcı bağlantıyı kapatır (yeniden bağlanma yok).
  Future<void> disconnect() async {
    _want = false;
    await _teardown(keepWant: false);
    state = DeviceConnection(device: _target, status: LinkStatus.idle);
  }

  /// Elle yeniden deneme (çevrimdışı banner'ındaki buton).
  Future<void> retryNow() async {
    if (_target == null) return;
    _retryTimer?.cancel();
    _want = true;
    _attempt = 0;
    await _closeSocket();
    state = state.copyWith(status: LinkStatus.connecting, clearError: true);
    await _open();
  }

  void requestState() => _sendRaw({'v': kProtocolVersion, 'type': 'getState'});

  /// Kısmi alan güncellemesi. Throttle + birleştirme uygulanır.
  void sendSet(int ch, Map<String, dynamic> fields) {
    if (!state.isConnected || fields.isEmpty) return;
    if (_queueFields(ch, fields)) _schedule();
  }

  /// Aynı alanları birden çok kanala gönderir (çoklu kanal seçimi). Kanal başına eleme yapılır: o alanı zaten
  /// aynı değerde olan kanal atlanır (efekti/rengi değişmeyen kanalın animasyonu dokunulmadan kalır). Aynı alan
  /// kümesine sahip kanallar tek bir `set` mesajında (`ch: [..]`) birleştirilir.
  void sendSetMulti(Iterable<int> chs, Map<String, dynamic> fields) {
    if (!state.isConnected || fields.isEmpty) return;
    var any = false;
    for (final ch in chs) {
      if (_queueFields(ch, fields)) any = true;
    }
    if (any) _schedule();
  }

  bool _queueFields(int ch, Map<String, dynamic> fields) {
    final last = _lastSent.putIfAbsent(ch, () => {});
    final pend = _pending.putIfAbsent(ch, () => {});
    final touched = _touched.putIfAbsent(ch, () => {});
    final now = DateTime.now();
    fields.forEach((k, v) {
      // Gereksiz trafik: son bilinen/gönderilen değerle aynıysa ve bekleyen yoksa atla
      if (!pend.containsKey(k) && last.containsKey(k) && _eq(last[k], v)) return;
      pend[k] = v;
      touched[k] = (at: now, value: v);
    });
    return pend.isNotEmpty;
  }

  // ── Bağlantı ──────────────────────────────────────────────────────────

  Future<void> _open() async {
    final dev = _target;
    if (dev == null || !_want) return;
    final session = ++_session;

    final token = await tokens.read(dev.id);
    if (session != _session) return;
    if (token == null) {
      _want = false;
      state = state.copyWith(status: LinkStatus.needsPairing, clearError: true);
      return;
    }

    state = state.copyWith(
      status: _attempt == 0 ? LinkStatus.connecting : LinkStatus.reconnecting,
      attempt: _attempt,
    );

    final uri = Uri(scheme: 'ws', host: dev.host, port: dev.port, path: '/ws');
    final sock = _socketFactory(uri);
    _sock = sock;
    try {
      await sock.ready.timeout(tuning.connectTimeout);
    } catch (_) {
      if (session != _session) return;
      await _closeSocket();
      _scheduleRetry('Cihaza ulaşılamıyor');
      return;
    }
    if (session != _session) {
      await sock.close();
      return;
    }

    _lastMsg = DateTime.now();
    _sub = sock.messages.listen(
      (m) => _onMessage(session, m),
      onDone: () => _onClosed(session),
      onError: (_) => _onClosed(session),
    );
    state = state.copyWith(status: LinkStatus.authenticating);
    sock.send(jsonEncode({'v': kProtocolVersion, 'type': 'auth', 'token': token}));
    _authTimer?.cancel();
    _authTimer = Timer(tuning.authTimeout, () {
      if (session == _session && state.status == LinkStatus.authenticating) {
        _closeSocket().then((_) => _scheduleRetry('Kimlik doğrulama zaman aşımı'));
      }
    });
  }

  void _onMessage(int session, String raw) {
    if (session != _session) return;
    _lastMsg = DateTime.now();
    dynamic j;
    try {
      j = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (j is! Map) return;
    switch (j['type']) {
      case 'authOk':
        _authTimer?.cancel();
        _attempt = 0;
        _lastSent.clear();
        _touched.clear();
        _pending.clear();
        _inFlight.clear();
        state = state.copyWith(
          status: LinkStatus.connected,
          clearError: true,
          attempt: 0,
          rev: -1,
        );
        _startPing(session);
        _fetchInfo(session);
      case 'state':
        _applyState(j);
      case 'ack':
        _inFlight.remove(j['id']);
      case 'error':
        _onError(j);
      default:
        break;
    }
  }

  void _applyState(Map j) {
    final rev = (j['rev'] as num?)?.toInt() ?? 0;
    final partial = j['partial'] == true;
    if (rev < state.rev && partial) return; // eski kısmi güncelleme
    final list = j['channels'];
    if (list is! List) return;

    final merged = Map<int, ChannelState>.from(partial ? state.channels : const {});
    final now = DateTime.now();
    for (final raw in list) {
      final ch = ChannelState.tryParse(raw);
      if (ch == null) continue;

      // Yakın zamanda kendi gönderdiğimiz alanları, geri dönen eski değerle ezme
      final touched = _touched[ch.ch];
      var result = ch;
      if (touched != null) {
        final keep = <String, dynamic>{};
        touched.forEach((k, t) {
          if (now.difference(t.at) < tuning.suppressRemote) keep[k] = t.value;
        });
        if (keep.isNotEmpty) result = ch.withFields(keep);
      }
      merged[ch.ch] = result;

      // Cihazın bilinen değerleri "son gönderilen" kabul edilir (dedupe için)
      final last = _lastSent.putIfAbsent(ch.ch, () => {});
      final fields = channelToFields(ch);
      fields.forEach((k, v) {
        if (_touched[ch.ch]?[k] == null ||
            now.difference(_touched[ch.ch]![k]!.at) >= tuning.suppressRemote) {
          last[k] = v;
        }
      });
    }
    state = state.copyWith(channels: merged, rev: rev);
  }

  void _onError(Map j) {
    final code = j['code'];
    final id = j['id'];
    final inflight = id is String ? _inFlight.remove(id) : null;
    if (code == 'busy' && inflight != null) {
      // Kuyruk doluydu: yalnızca henüz yenisi olmayan alanları yeniden gönder
      for (final ch in inflight.chs) {
        final pend = _pending.putIfAbsent(ch, () => {});
        inflight.fields.forEach((k, v) => pend.putIfAbsent(k, () => v));
      }
      _flushTimer?.cancel();
      _flushTimer = Timer(const Duration(milliseconds: 100), _flush);
    } else if (code == 'unauthorized') {
      _handleUnauthorized();
    }
  }

  Future<void> _handleUnauthorized() async {
    final dev = _target;
    _want = false;
    await _closeSocket();
    if (dev != null) await tokens.delete(dev.id);
    state = state.copyWith(
      status: LinkStatus.needsPairing,
      error: 'Eşleştirme geçersiz. Cihazı yeniden eşleştirin.',
    );
  }

  void _onClosed(int session) {
    if (session != _session) return;
    final code = _sock?.closeCode;
    _cleanupTimers();
    _sub?.cancel();
    _sub = null;
    _sock = null;
    _session++; // bu oturumun geç olaylarını kes

    if (!_want) return;
    if (code == 4403 || code == 4401) {
      // Token iptal edilmiş veya cihaz tarafından tanınmıyor
      final dev = _target;
      _want = false;
      if (dev != null) tokens.delete(dev.id);
      state = state.copyWith(
        status: LinkStatus.needsPairing,
        error: code == 4403
            ? 'Bu istemcinin eşleştirmesi cihazdan kaldırıldı.'
            : 'Eşleştirme geçersiz. Cihazı yeniden eşleştirin.',
      );
      return;
    }
    if (code == 4429) {
      _scheduleRetry('Çok fazla deneme; kısa süre bekleniyor', minDelay: const Duration(seconds: 60));
      return;
    }
    _scheduleRetry('Bağlantı kesildi');
  }

  void _scheduleRetry(String reason, {Duration? minDelay}) {
    if (!_want) return;
    final idx = _attempt < tuning.backoff.length ? _attempt : tuning.backoff.length - 1;
    var delay = tuning.backoff[idx];
    if (minDelay != null && delay < minDelay) delay = minDelay;
    _attempt++;
    state = state.copyWith(
      status: LinkStatus.reconnecting,
      error: reason,
      attempt: _attempt,
    );
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () async {
      if (!_want) return;
      // IP değişmiş olabilir: birkaç başarısız denemeden sonra cihazı kimliğiyle yeniden ara
      final dev = _target;
      if (_attempt >= 3 && dev != null && discovery != null) {
        final found = await discovery!.findById(dev.id, timeout: const Duration(seconds: 5), extraHosts: [dev.host]);
        if (found != null && _want) {
          _target = found;
          state = state.copyWith(device: found);
        }
      }
      await _open();
    });
  }

  // ── Giden mesajlar ────────────────────────────────────────────────────

  void _schedule() {
    if (_flushTimer?.isActive ?? false) return;
    final elapsed = DateTime.now().difference(_lastFlush);
    if (elapsed >= tuning.throttle) {
      _flush();
    } else {
      _flushTimer = Timer(tuning.throttle - elapsed, _flush);
    }
  }

  void _flush() {
    _flushTimer?.cancel();
    if (!state.isConnected) {
      _pending.clear();
      return;
    }
    _lastFlush = DateTime.now();
    // Aynı alan/değer kümesine sahip kanalları grupla: tek mesaj, cihazda tek komut (hız sınırına da dost)
    final groups = <String, ({List<int> chs, Map<String, dynamic> fields})>{};
    final keys = _pending.keys.toList()..sort();
    for (final ch in keys) {
      final f = _pending[ch]!;
      if (f.isEmpty) continue;
      final sortedKeys = f.keys.toList()..sort();
      final sig = jsonEncode([for (final k in sortedKeys) [k, f[k]]]);
      final g = groups.putIfAbsent(sig, () => (chs: <int>[], fields: Map<String, dynamic>.from(f)));
      g.chs.add(ch);
    }
    for (final g in groups.values) {
      final id = 'c${++_idCounter}';
      _inFlight[id] = (chs: g.chs, fields: g.fields);
      if (_inFlight.length > 64) _inFlight.remove(_inFlight.keys.first);
      for (final ch in g.chs) {
        final last = _lastSent.putIfAbsent(ch, () => {});
        g.fields.forEach((k, v) => last[k] = v);
      }
      _sendRaw({
        'v': kProtocolVersion,
        'type': 'set',
        'id': id,
        'ch': g.chs.length == 1 ? g.chs.first : g.chs,
        ...g.fields,
      });
    }
    _pending.clear();
  }

  void _sendRaw(Map<String, dynamic> msg) {
    final s = _sock;
    if (s == null) return;
    sentMessages++;
    s.send(jsonEncode(msg));
  }

  void _startPing(int session) {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(tuning.pingInterval, (_) {
      if (session != _session) return;
      if (DateTime.now().difference(_lastMsg) > tuning.silenceTimeout) {
        _closeSocket().then((_) => _scheduleRetry('Cihazdan yanıt yok'));
        return;
      }
      _sendRaw({'v': kProtocolVersion, 'type': 'ping'});
    });
  }

  Future<void> _fetchInfo(int session) async {
    final dev = _target;
    if (dev == null) return;
    final token = await tokens.read(dev.id);
    if (token == null) return;
    final api = _apiFactory(dev, token);
    try {
      final info = await api.info();
      if (session == _session && mounted) state = state.copyWith(info: info);
    } catch (_) {
      // Bilgi alınamazsa kontrol yine de çalışır
    } finally {
      api.close();
    }
  }

  /// /api/info'yu yeniden okur (LED sayısı/özellikler değiştikten sonra).
  Future<void> refreshInfo() => _fetchInfo(_session);

  // ── Temizlik ──────────────────────────────────────────────────────────

  void _cleanupTimers() {
    _authTimer?.cancel();
    _pingTimer?.cancel();
    _flushTimer?.cancel();
  }

  Future<void> _closeSocket() async {
    _cleanupTimers();
    _session++;
    await _sub?.cancel();
    _sub = null;
    final s = _sock;
    _sock = null;
    if (s != null) await s.close();
  }

  Future<void> _teardown({required bool keepWant}) async {
    _retryTimer?.cancel();
    if (!keepWant) _want = false;
    await _closeSocket();
    _pending.clear();
    _inFlight.clear();
  }

  @override
  void dispose() {
    _want = false;
    _retryTimer?.cancel();
    _cleanupTimers();
    _sub?.cancel();
    _sock?.close();
    super.dispose();
  }

  static bool _eq(dynamic a, dynamic b) => jsonEncode(a) == jsonEncode(b);
}

/// Bir kanalın protokol alanları (dedupe/suppress karşılaştırması için).
Map<String, dynamic> channelToFields(ChannelState c) => {
      'power': c.power,
      'color': colorToWire(c.color),
      'color2': colorToWire(c.color2),
      'effect': c.effect.name,
      'brightness': c.brightness,
      'speed': c.speed,
      'direction': c.direction,
      'intensity': c.intensity,
      'palette': paletteToWire(c.palette),
    };
