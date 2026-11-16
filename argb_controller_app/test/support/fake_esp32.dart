import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:argb_controller/services/device_socket.dart';

/// Donanım gerektirmeyen ESP32 HTTP API taklidi (docs/PROTOCOL.md §6).
class FakeEsp32Http {
  FakeEsp32Http({this.deviceId = 'esp32-argb-TEST01'});

  final String deviceId;
  bool pairingOpen = false;
  bool paired = false;
  String mode = 'ap'; // ap | sta
  String? validToken;
  int slots = 4;
  String wifiState = 'ap'; // ap | connecting | connected | failed
  String? wifiError;
  String? wifiSsid;
  String? wifiPassword; // yalnızca test doğrulaması için
  int connectPolls = 0;
  int connectPollsUntilDone = 2;
  bool connectShouldFail = false;
  String wledMode = 'off';
  bool wledCompiled = true;
  int scanPollsRunning = 1;
  int _scanPolls = 0;
  final List<String> requests = [];

  List<Map<String, dynamic>> networks = [
    {'ssid': 'Home', 'rssi': -50, 'security': 'WPA2_PSK', 'channel': 6},
    {'ssid': 'Home', 'rssi': -70, 'security': 'WPA2_PSK', 'channel': 11},
    {'ssid': 'Cafe', 'rssi': -80, 'security': 'OPEN', 'channel': 1},
    {'ssid': 'Corp', 'rssi': -60, 'security': 'WPA2_ENTERPRISE', 'channel': 3},
  ];

  MockClient client() => MockClient(_handle);

  bool _authorized(http.Request r) =>
      validToken != null && r.headers['Authorization'] == 'Bearer $validToken';

  http.Response _json(int code, Object body) =>
      http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json'});

  http.Response _err(int code, String c, {String? field}) =>
      _json(code, {'v': 1, 'type': 'error', 'code': c, if (field != null) 'field': field});

  Future<http.Response> _handle(http.Request r) async {
    requests.add('${r.method} ${r.url.path}');
    final path = r.url.path;

    if (path == '/api/discover' && r.method == 'GET') {
      return _json(200, {
        'v': 1,
        'deviceId': deviceId,
        'name': 'ESP32 Test',
        'model': 'ESP32-WROOM-32',
        'fw': '1.0.0',
        'proto': 1,
        'paired': paired,
        'pairingOpen': pairingOpen,
        'mode': mode,
      });
    }
    if (path == '/api/pair' && r.method == 'POST') {
      if (!pairingOpen) return _err(403, 'pairing_closed');
      if (slots <= 0) return _err(409, 'slots_full');
      validToken = 'a' * 64;
      paired = true;
      pairingOpen = false;
      return _json(200, {'token': validToken, 'tokenId': 'abcd1234', 'deviceId': deviceId});
    }

    // Aşağısı token gerektirir
    if (!_authorized(r)) return _err(401, 'unauthorized');

    switch ('${r.method} $path') {
      case 'GET /api/info':
        return _json(200, {
          'v': 1,
          'type': 'info',
          'deviceId': deviceId,
          'name': 'ESP32 Test',
          'fw': '1.0.0',
          'proto': 1,
          'supportedEffects': ['staticColor', 'breathing'],
          'channelConfigs': [
            {'ch': 1, 'enabled': true, 'ledCount': 30, 'ledType': 'WS2812B', 'colorOrder': 'GRB', 'maxBrightness': 255, 'gpio': 18}
          ],
          'wifi': {'mode': mode, 'state': wifiState},
        });
      case 'POST /api/wifi/scan':
        _scanPolls = 0;
        return _json(202, {'status': 'running'});
      case 'GET /api/wifi/scan':
        _scanPolls++;
        final running = _scanPolls <= scanPollsRunning;
        return _json(200, {'status': running ? 'running' : 'done', 'networks': running ? [] : networks});
      case 'POST /api/wifi/connect':
        final body = jsonDecode(r.body) as Map;
        wifiSsid = body['ssid'] as String;
        wifiPassword = body['password'] as String;
        connectPolls = 0;
        wifiState = 'connecting';
        return _json(202, {'status': 'connecting'});
      case 'GET /api/wifi/status':
        if (wifiState == 'connecting') {
          connectPolls++;
          if (connectPolls >= connectPollsUntilDone) {
            if (connectShouldFail) {
              wifiState = 'failed';
              wifiError = 'auth_failed';
            } else {
              wifiState = 'connected';
              mode = 'sta';
            }
          }
        }
        return _json(200, {
          'state': wifiState,
          'mode': mode,
          'apActive': mode == 'ap',
          if (wifiState == 'connected') ...{'ssid': wifiSsid, 'ip': '192.168.1.40', 'rssi': -50},
          if (wifiState == 'failed') 'error': wifiError,
        });
      case 'GET /api/wled':
        return _json(200, {'compiled': wledCompiled, 'mode': wledMode});
      case 'POST /api/wled':
        final b = jsonDecode(r.body) as Map;
        final m = b['mode'];
        if (m != 'off' && m != 'readonly' && m != 'control') return _err(400, 'invalid_value', field: 'mode');
        // Kimlik doğrulamasız kontrol: fiziksel BOOT onayı (eşleştirme penceresi) şart
        if (m == 'control' && !pairingOpen) return _err(403, 'pairing_closed');
        wledMode = m as String;
        return _json(200, {'compiled': wledCompiled, 'mode': wledMode});
      case 'GET /api/auth/tokens':
        return _json(200, {
          'tokens': [
            {'tokenId': 'abcd1234', 'clientName': 'Flutter test', 'current': true}
          ]
        });
    }
    return _err(404, 'not_found');
  }
}

/// WebSocket taklidi: istemcinin gönderdiklerini kaydeder, cihaz davranışı [onClient] ile yazılır.
class FakeSocket implements DeviceSocket {
  FakeSocket({this.failReady = false});

  final bool failReady;
  final StreamController<String> _in = StreamController<String>.broadcast();
  final List<Map<String, dynamic>> sent = [];
  void Function(Map<String, dynamic> msg)? onClient;
  int? _closeCode;
  bool closed = false;

  @override
  Future<void> get ready => failReady ? Future.error(Exception('refused')) : Future.value();

  @override
  Stream<String> get messages => _in.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  void send(String data) {
    final m = jsonDecode(data) as Map<String, dynamic>;
    sent.add(m);
    onClient?.call(m);
  }

  void emit(Map<String, dynamic> m) {
    if (!_in.isClosed) _in.add(jsonEncode(m));
  }

  void serverClose(int code) {
    _closeCode = code;
    _in.close();
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_in.isClosed) await _in.close();
  }

  List<Map<String, dynamic>> get sets => sent.where((m) => m['type'] == 'set').toList();
}

Map<String, dynamic> channelJson({
  int ch = 1,
  bool enabled = true,
  bool power = true,
  String effect = 'breathing',
  int brightness = 220,
  int speed = 55,
  int intensity = 50,
  Map<String, int> color = const {'r': 108, 'g': 99, 'b': 255},
}) =>
    {
      'ch': ch,
      'enabled': enabled,
      'ledCount': 30,
      'power': power,
      'color': color,
      'color2': {'r': 0, 'g': 210, 'b': 255},
      'effect': effect,
      'brightness': brightness,
      'speed': speed,
      'direction': 1,
      'intensity': intensity,
    };

Map<String, dynamic> stateMsg({int rev = 1, bool partial = false, List<Map<String, dynamic>>? channels}) => {
      'v': 1,
      'type': 'state',
      'rev': rev,
      if (partial) 'partial': true,
      'channels': channels ?? [channelJson()],
    };

/// Standart cihaz davranışı: auth -> authOk + state; set -> ack + kısmi state.
void standardDevice(FakeSocket s, {int Function()? revSource}) {
  var rev = 1;
  s.onClient = (m) {
    switch (m['type']) {
      case 'auth':
        s.emit({'v': 1, 'type': 'authOk', 'deviceId': 'esp32-argb-TEST01', 'tokenId': 'abcd1234'});
        s.emit(stateMsg(rev: rev));
      case 'set':
        rev++;
        s.emit({'v': 1, 'type': 'ack', 'id': m['id'], 'rev': rev});
    }
  };
}
