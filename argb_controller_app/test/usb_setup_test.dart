import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:argb_controller/services/serial/serial_debug_log.dart';
import 'package:argb_controller/services/serial/serial_setup_client.dart';
import 'package:argb_controller/services/serial/serial_transport.dart';
import 'package:argb_controller/state/usb_setup_controller.dart';

/// Firmware (serial_provisioning.cpp) davranışını taklit eden sahte ESP32 seri hattı.
class FakeSerialEsp32 implements SerialTransport {
  final _out = StreamController<List<int>>.broadcast();
  final List<String> receivedLines = [];
  bool window = false;
  String wifiState = 'ap';
  String? error;
  bool connectFails = false;
  String? connectedSsid;
  final List<Map<String, dynamic>> networks = [
    {'ssid': 'Home', 'rssi': -48, 'security': 'WPA2_PSK', 'channel': 6},
    {'ssid': 'Home', 'rssi': -72, 'security': 'WPA2_PSK', 'channel': 11},
    {'ssid': 'Guest', 'rssi': -80, 'security': 'OPEN', 'channel': 1},
  ];
  String? lastPassword; // yalnızca doğrulama için
  bool prefix = true; // false: bazı firmware sürümleri gibi ÖNEKSİZ (çıplak) JSON yanıtı
  int remainingMs = 90000;

  @override
  Stream<List<int>> get data => _out.stream;

  void _emit(String line) => _out.add(utf8.encode('$line\n'));
  void _arg(Map<String, dynamic> m) => _emit('${prefix ? 'ARGB:' : ''}${jsonEncode(m)}');
  void emitBootLog() {
    _emit('ets Jul 29 2019 12:21:46');
    _emit('rst:0x1 (POWERON_RESET),boot:0x13 (SPI_FAST_FLASH_BOOT)');
    _emit('ESP32 Smart ARGB Controller - Firmware 1.0.0');
  }


  Map<String, dynamic> _status(String type) => {
        'v': 1,
        'type': type,
        'deviceId': 'esp32-argb-TEST01',
        'fw': '1.0.0',
        'window': window,
        'remainingMs': window ? remainingMs : 0,
        'state': wifiState,
        if (wifiState == 'connected') ...{'ssid': connectedSsid, 'ip': '192.168.1.77'},
        if (error != null) 'error': error,
      };

  @override
  void write(List<int> bytes) {
    final line = utf8.decode(bytes).trim();
    receivedLines.add(line);
    // Seri monitör logları protokolün arasına karışır
    _emit('[Heartbeat] Wi-Fi: AP (ESP32-ARGB-Setup-AB12) | Heap: 180 KB');
    final cmd = jsonDecode(line) as Map<String, dynamic>;
    scheduleMicrotask(() {
      switch (cmd['cmd']) {
        case 'hello':
          _arg(_status('hello'));
        case 'status':
          _arg(_status('status'));
        case 'scan':
          if (!window) {
            _arg({'v': 1, 'type': 'error', 'code': 'window_closed'});
            return;
          }
          _arg({'v': 1, 'type': 'scanStarted'});
          Timer(const Duration(milliseconds: 30), () {
            _emit('[WiFiManager] noise line without prefix');
            _arg({'v': 1, 'type': 'scanResult', 'networks': networks});
          });
        case 'wifi':
          if (!window) {
            _arg({'v': 1, 'type': 'error', 'code': 'window_closed'});
            return;
          }
          lastPassword = cmd['pass'] as String?;
          _arg({'v': 1, 'type': 'wifiAccepted'});
          wifiState = 'connecting';
          _arg({..._status('event')});
          Timer(const Duration(milliseconds: 30), () {
            if (connectFails) {
              wifiState = 'failed';
              error = 'auth_failed';
              _arg({..._status('event')});
            } else {
              wifiState = 'connected';
              connectedSsid = cmd['ssid'] as String?;
              error = null;
              _arg({..._status('event')});
              window = false;
            }
          });
      }
    });
  }

  @override
  Future<void> close() async {
    if (!_out.isClosed) await _out.close();
  }
}

class FakeBackend implements SerialBackend {
  FakeBackend(this.esp, {this.ports = const [SerialPortInfo(name: 'COM3', description: 'Silicon Labs CP210x', vendorId: 0x10C4, productId: 0xEA60)]});
  final SerialTransport esp;
  final List<SerialPortInfo> ports;
  @override
  bool get supported => true;
  @override
  List<SerialPortInfo> listPorts() => ports;
  @override
  Future<SerialTransport> open(String portName, {int baudRate = 115200}) async => esp;
}

const _fast = UsbTuning(
  bootPoll: Duration(milliseconds: 20),
  bootTimeout: Duration(seconds: 2),
  helloAttempts: 3,
  helloPerAttempt: Duration(milliseconds: 300),
);

Future<void> until(bool Function() c, {int ms = 3000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!c() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(c(), isTrue, reason: 'koşul zamanında sağlanmadı');
}

void main() {
  group('SerialSetupClient (protokol)', () {
    test('log satırları protokolü bozmaz; hello/status/scan çalışır', () async {
      final esp = FakeSerialEsp32()..window = true;
      final c = SerialSetupClient(esp);
      final h = await c.hello(attempts: 2, perAttempt: const Duration(milliseconds: 300));
      expect(h!.deviceId, 'esp32-argb-TEST01');
      expect(h.window, isTrue);
      final r = await c.scan();
      expect(r.ok, isTrue);
      expect(r.networks.length, 3);
      await c.close();
    });

    test('pencere kapalıyken tarama window_closed ile reddedilir', () async {
      final esp = FakeSerialEsp32();
      final c = SerialSetupClient(esp);
      final r = await c.scan(timeout: const Duration(seconds: 1));
      expect(r.error, 'window_closed');
      await c.close();
    });

    test('bağlanma başarısı IP döner; başarısızlık hata kodu döner', () async {
      final esp = FakeSerialEsp32()..window = true;
      final c = SerialSetupClient(esp);
      final ok = await c.connectWifi('Home', 'secret-pass1', timeout: const Duration(seconds: 2));
      expect(ok.connected, isTrue);
      expect(ok.ip, '192.168.1.77');
      expect(esp.lastPassword, 'secret-pass1'); // cihaza gitti

      final esp2 = FakeSerialEsp32()
        ..window = true
        ..connectFails = true;
      final c2 = SerialSetupClient(esp2);
      final bad = await c2.connectWifi('Home', 'wrongpass1', timeout: const Duration(seconds: 2));
      expect(bad.connected, isFalse);
      expect(bad.error, 'auth_failed');
      expect(describeSerialError(bad.error), contains('şifre'));
      await c.close();
      await c2.close();
    });

    test('pencere kapalıyken wifi komutu reddedilir', () async {
      final esp = FakeSerialEsp32();
      final c = SerialSetupClient(esp);
      final r = await c.connectWifi('Home', 'password123', timeout: const Duration(seconds: 1));
      expect(r.error, 'window_closed');
      await c.close();
    });

    test('yanıt vermeyen cihazda hello null döner', () async {
      final silent = _Silent();
      final c = SerialSetupClient(silent);
      expect(await c.hello(attempts: 2, perAttempt: const Duration(milliseconds: 100)), isNull);
      await c.close();
    });
  });


  group('çıplak (öneksiz) JSON ve log toleransı', () {
    test('parseProtocolLine: önekli, öneksiz, log gürültüsü ve bozuk satırlar', () {
      expect(SerialSetupClient.parseProtocolLine('ARGB:{"v":1,"type":"hello"}')!['type'], 'hello');
      expect(SerialSetupClient.parseProtocolLine('{"v":1,"type":"status","window":true}')!['window'], true);
      expect(SerialSetupClient.parseProtocolLine('[Heartbeat] Wi-Fi: STA (1.2.3.4) | CH1: [Power:ON]'), isNull);
      expect(SerialSetupClient.parseProtocolLine('{"v":1,"nope":true}'), isNull, reason: 'type alanı yok');
      expect(SerialSetupClient.parseProtocolLine('{"v":1,"type":"hel'), isNull, reason: 'yarım satır');
      expect(SerialSetupClient.parseProtocolLine(''), isNull);
      expect(SerialSetupClient.parseProtocolLine('[log] ARGB:{"type":"error","code":"window_closed"}')!['code'], 'window_closed');
    });

    test('öneksiz firmware yanıtı: hello/status/scan/wifi çalışır (gerçek karttaki durum)', () async {
      final esp = FakeSerialEsp32()
        ..prefix = false
        ..window = true;
      final c = SerialSetupClient(esp);
      final h = await c.hello(attempts: 2, perAttempt: const Duration(milliseconds: 300));
      expect(h, isNotNull);
      expect(h!.deviceId, 'esp32-argb-TEST01');
      expect((await c.scan()).networks.length, 3);
      final r = await c.connectWifi('HomeNet', 'password123', timeout: const Duration(seconds: 2));
      expect(r.connected, isTrue);
      expect(r.ip, '192.168.1.77');
      await c.close();
    });

    test('boot günlüğü algılanır ve hello yine de başarılı olur (yeniden başlama toleransı)', () async {
      final esp = FakeSerialEsp32()..window = true;
      final c = SerialSetupClient(esp);
      esp.emitBootLog();
      final seen = <bool>[];
      final h = await c.hello(
        attempts: 3,
        perAttempt: const Duration(milliseconds: 300),
        onProgress: (i, n, booting) => seen.add(booting),
      );
      expect(h, isNotNull);
      expect(c.sawBoot, isTrue);
      await c.close();
    });
  });

  group('hata ayıklama günlüğü gizliliği', () {
    test('wifi komutu, SSID ve şifre günlüğe yazılmaz', () async {
      final esp = FakeSerialEsp32()..window = true;
      final log = SerialDebugLog();
      final c = SerialSetupClient(esp, log: log);
      await c.hello(attempts: 1, perAttempt: const Duration(milliseconds: 300));
      await c.scan();
      await c.connectWifi('HomeNet', 'SuperGizliSifre123', timeout: const Duration(seconds: 2));
      final all = log.lines.join('\n');
      expect(all.contains('SuperGizliSifre123'), isFalse);
      expect(all.contains('HomeNet'), isFalse, reason: 'SSID de günlüğe yazılmaz');
      expect(all.contains('Home'), isFalse, reason: 'tarama sonuçlarındaki ağ adları yazılmaz');
      expect(all.contains('"cmd":"wifi"'), isTrue);
      expect(all.contains('<gizli>'), isTrue);
      await c.close();
    });

    test('redact: AP şifre satırı ve çeşitli alanlar maskelenir', () {
      expect(SerialDebugLog.redact('[WiFiManager] Password: abc12345 (Device-Specific Secure Key)').contains('abc12345'), isFalse);
      expect(SerialDebugLog.redact('{"cmd":"wifi","ssid":"X","pass":"Y"}'), '{"cmd":"wifi","ssid":"<gizli>","pass":"<gizli>"}');
      expect(SerialDebugLog.redact('{"type":"status","ssid":"Evim","ip":"1.2.3.4"}').contains('Evim'), isFalse);
      expect(SerialDebugLog.redact('{"password":"p"}').contains('"p"'), isFalse);
    });
  });

  group('BOOT yetkilendirme durumu (geri sayım)', () {
    test('pencere süresi ve cihaz Wi-Fi durumu ekrana yansır; kapanınca BOOT beklenir', () async {
      final esp = FakeSerialEsp32()
        ..prefix = false
        ..window = true
        ..remainingMs = 100000;
      final c = UsbSetupController(FakeBackend(esp), tuning: _fast);
      await c.connect();
      expect(c.state.step, UsbStep.ready);
      expect(c.state.windowOpen, isTrue);
      expect(c.state.windowRemainingMs, 100000);
      expect(c.state.deviceWifiState, 'ap');

      esp.remainingMs = 70000; // zaman akar
      await until(() => c.state.windowRemainingMs == 70000);

      esp.window = false; // pencere süresi doldu
      await until(() => c.state.step == UsbStep.waitingBoot);
      expect(c.state.windowOpen, isFalse);
      expect(c.state.error, contains('BOOT'));

      esp.window = true; // kullanıcı tekrar BOOT'a bastı
      esp.remainingMs = 118000;
      await until(() => c.state.step == UsbStep.ready);
      expect(c.state.windowRemainingMs, 118000);
      c.dispose();
    });

    test('günlük state\'e yansır ve şifre içermez', () async {
      final esp = FakeSerialEsp32()..window = true;
      final c = UsbSetupController(FakeBackend(esp), tuning: _fast);
      await c.connect();
      await c.scan();
      c.selectNetwork('Home');
      await c.connectToWifi('Home', 'Gizli-Parola-99');
      expect(c.state.step, UsbStep.done);
      expect(c.state.logLines, isNotEmpty);
      expect(c.state.logLines.join('\n').contains('Gizli-Parola-99'), isFalse);
      expect(c.state.toString().contains('Gizli-Parola-99'), isFalse);
      c.dispose();
    });
  });

  group('UsbSetupController (akış)', () {
    test('port algılama: tek CP210x portu otomatik seçilir', () {
      final c = UsbSetupController(FakeBackend(FakeSerialEsp32()), tuning: _fast);
      expect(c.state.selectedPort, 'COM3');
      expect(c.state.ports.single.likelyEsp32, isTrue);
      c.dispose();
    });

    test('tam akış: bağlan -> BOOT bekle -> tara -> seç -> bağlan -> IP', () async {
      final esp = FakeSerialEsp32(); // pencere kapalı
      final c = UsbSetupController(FakeBackend(esp), tuning: _fast);

      await c.connect();
      expect(c.state.step, UsbStep.waitingBoot);
      expect(c.state.deviceId, 'esp32-argb-TEST01');

      // Kullanıcı BOOT düğmesine basar
      Future<void>.delayed(const Duration(milliseconds: 80), () => esp.window = true);
      await until(() => c.state.step == UsbStep.ready);

      await c.scan();
      expect(c.state.step, UsbStep.networks);
      expect(c.state.networks.map((g) => g.ssid), ['Home', 'Guest']);
      expect(c.state.networks.first.accessPointCount, 2);

      c.selectNetwork('Home');
      await c.connectToWifi('Home', 'password123');
      expect(c.state.step, UsbStep.done);
      expect(c.state.resultIp, '192.168.1.77');
      expect(c.lanDevice!.host, '192.168.1.77');
      expect(c.lanDevice!.id, 'esp32-argb-TEST01');
      // Şifre state'te tutulmaz
      expect(c.state.toString().contains('password123'), isFalse);
      expect(c.state.error, isNull);
      c.dispose();
    });

    test('yanlış şifre: credentials adımına döner, tekrar denenebilir', () async {
      final esp = FakeSerialEsp32()
        ..window = true
        ..connectFails = true;
      final c = UsbSetupController(FakeBackend(esp), tuning: _fast);
      await c.connect();
      await c.scan();
      c.selectNetwork('Home');
      await c.connectToWifi('Home', 'wrongpass1');
      expect(c.state.step, UsbStep.credentials);
      expect(c.state.error, contains('şifre'));

      esp.connectFails = false;
      esp.wifiState = 'ap';
      await c.connectToWifi('Home', 'rightpass1');
      expect(c.state.step, UsbStep.done);
      c.dispose();
    });

    test('tarama sırasında pencere kapanırsa tekrar BOOT beklenir', () async {
      final esp = FakeSerialEsp32()..window = true;
      final c = UsbSetupController(FakeBackend(esp), tuning: _fast);
      await c.connect();
      esp.window = false; // süre doldu
      await c.scan();
      expect(c.state.step, UsbStep.waitingBoot);
      expect(c.state.error, contains('BOOT'));
      c.dispose();
    });

    test('ESP32 yanıt vermezse anlaşılır hata', () async {
      final c = UsbSetupController(FakeBackend(_Silent()), tuning: _fast);
      await c.connect();
      expect(c.state.step, UsbStep.selectPort);
      expect(c.state.error, contains('yanıt vermedi'));
      c.dispose();
    });

    test('desteklenmeyen platformda supported=false', () {
      final c = UsbSetupController(_Unsupported(), tuning: _fast);
      expect(c.supported, isFalse);
      expect(c.state.ports, isEmpty);
      c.dispose();
    });
  });
}

class _Silent implements SerialTransport, SerialBackend {
  final _s = StreamController<List<int>>.broadcast();
  @override
  Stream<List<int>> get data => _s.stream;
  @override
  void write(List<int> bytes) {}
  @override
  Future<void> close() async {}
  @override
  bool get supported => true;
  @override
  List<SerialPortInfo> listPorts() => const [SerialPortInfo(name: 'COM9')];
  @override
  Future<SerialTransport> open(String portName, {int baudRate = 115200}) async => this;
}

class _Unsupported implements SerialBackend {
  @override
  bool get supported => false;
  @override
  List<SerialPortInfo> listPorts() => const [];
  @override
  Future<SerialTransport> open(String portName, {int baudRate = 115200}) =>
      Future.error(const SerialException('x'));
}
