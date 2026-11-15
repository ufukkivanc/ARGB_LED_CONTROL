import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:argb_controller/models/protocol.dart';

/// ESP32 HTTP API istemcisi (docs/PROTOCOL.md §6).
///
/// GÜVENLİK: Token ve Wi-Fi şifresi hiçbir zaman loglanmaz, URL'ye konmaz;
/// token yalnızca `Authorization: Bearer` başlığında taşınır.
class DeviceApi {
  DeviceApi({
    required this.host,
    this.port = 80,
    String? token,
    http.Client? client,
    this.timeout = const Duration(seconds: 5),
  })  : _token = token,
        _client = client ?? http.Client();

  final String host;
  final int port;
  final Duration timeout;
  final http.Client _client;
  String? _token;

  set token(String? t) => _token = t;
  bool get hasToken => _token != null && _token!.isNotEmpty;

  Uri _uri(String path) => Uri(scheme: 'http', host: host, port: port, path: path);

  Map<String, String> _headers({bool json = false}) => {
        if (json) 'Content-Type': 'application/json',
        if (_token != null && _token!.isNotEmpty) 'Authorization': 'Bearer $_token',
      };

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final req = http.Request(method, _uri(path));
    req.headers.addAll(_headers(json: body != null));
    if (body != null) req.body = jsonEncode(body);

    http.Response res;
    try {
      final streamed = await _client.send(req).timeout(timeout);
      res = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw const ApiException('timeout_client');
    } catch (_) {
      throw const ApiException('network');
    }

    dynamic decoded;
    if (res.body.isNotEmpty) {
      try {
        decoded = jsonDecode(res.body);
      } catch (_) {
        decoded = null;
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return decoded ?? <String, dynamic>{};

    final m = decoded is Map ? decoded : const {};
    throw ApiException(
      (m['code'] as String?) ?? 'http_${res.statusCode}',
      httpStatus: res.statusCode,
      field: m['field'] as String?,
      message: m['message'] as String?,
    );
  }

  void close() => _client.close();

  // ── Herkese açık ─────────────────────────────────────────────────────

  Future<DiscoverInfo> discover() async {
    final j = await _send('GET', '/api/discover');
    final d = DiscoverInfo.tryParse(j);
    if (d == null) throw const ApiException('bad_response');
    return d;
  }

  /// Eşleştirme: BOOT penceresi açıkken token döner. Token yalnızca bu yanıtta gelir.
  Future<({String token, String tokenId, String deviceId})> pair(String clientName) async {
    final j = await _send('POST', '/api/pair', body: {'clientName': clientName});
    if (j is! Map || j['token'] is! String) throw const ApiException('bad_response');
    return (
      token: j['token'] as String,
      tokenId: (j['tokenId'] as String?) ?? '',
      deviceId: (j['deviceId'] as String?) ?? '',
    );
  }

  // ── Token gerekir ────────────────────────────────────────────────────

  Future<DeviceInfo> info() async {
    final j = await _send('GET', '/api/info');
    final d = DeviceInfo.tryParse(j);
    if (d == null) throw const ApiException('bad_response');
    return d;
  }

  Future<void> openPairing() => _send('POST', '/api/pair/open');

  Future<void> startWifiScan() => _send('POST', '/api/wifi/scan');

  /// (running, ağlar)
  Future<({bool running, List<WifiNetwork> networks})> getWifiScan() async {
    final j = await _send('GET', '/api/wifi/scan');
    if (j is! Map) throw const ApiException('bad_response');
    final nets = <WifiNetwork>[];
    final raw = j['networks'];
    if (raw is List) {
      for (final n in raw) {
        final p = WifiNetwork.tryParse(n);
        if (p != null) nets.add(p);
      }
    }
    return (running: j['status'] == 'running', networks: nets);
  }

  /// Şifre yalnızca bu istek gövdesinde gider; saklanmaz/loglanmaz.
  Future<void> connectWifi(String ssid, String password) =>
      _send('POST', '/api/wifi/connect', body: {'ssid': ssid, 'password': password});

  Future<WifiStatus> wifiStatus() async {
    final j = await _send('GET', '/api/wifi/status');
    final s = WifiStatus.tryParse(j);
    if (s == null) throw const ApiException('bad_response');
    return s;
  }

  Future<void> resetWifi() => _send('POST', '/api/wifi/reset');
  Future<void> reboot() => _send('POST', '/api/reboot');
  Future<void> factoryReset() => _send('POST', '/api/factory-reset', body: {'confirm': 'RESET'});

  Future<List<PairedClient>> listTokens() async {
    final j = await _send('GET', '/api/auth/tokens');
    final out = <PairedClient>[];
    if (j is Map && j['tokens'] is List) {
      for (final t in j['tokens'] as List) {
        if (t is Map && t['tokenId'] is String) {
          out.add(PairedClient(
            tokenId: t['tokenId'] as String,
            clientName: (t['clientName'] as String?) ?? 'client',
            current: t['current'] == true,
          ));
        }
      }
    }
    return out;
  }

  Future<void> revokeToken(String tokenId) => _send('DELETE', '/api/auth/tokens/$tokenId');
}
