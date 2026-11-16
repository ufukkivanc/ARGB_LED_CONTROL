// GERÇEK DONANIM testi: üretim seri katmanı (libserialport + SerialSetupClient) ↔ gerçek ESP32.
//
// Varsayılan olarak ATLANIR. Çalıştırmak için (PowerShell, proje: argb_controller_app):
//   $env:PATH = "$PWD\build\windows\x64\runner\Debug;$env:PATH"   # serialport.dll
//   $env:ESP32_COM_PORT = "COM3"
//   flutter test test/hardware/real_esp32_test.dart
// BOOT penceresi açıkken tarama da denenir: kart üzerindeki BOOT'a 3 sn basıp bırakın, sonra testi çalıştırın.
// Wi-Fi şifresi ASLA gönderilmez.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:argb_controller/services/serial/serial_backend.dart';
import 'package:argb_controller/services/serial/serial_debug_log.dart';
import 'package:argb_controller/services/serial/serial_setup_client.dart';

void main() {
  final port = Platform.environment['ESP32_COM_PORT'];

  test('gerçek ESP32: hello/status (önekli veya öneksiz yanıt) + isteğe bağlı tarama', () async {
    final log = SerialDebugLog(maxLines: 400);
    final backend = createSerialBackend();
    expect(backend.supported, isTrue);
    expect(backend.listPorts().map((p) => p.name), contains(port));

    final sw = Stopwatch()..start();
    final transport = await backend.open(port!);
    final client = SerialSetupClient(transport, log: log);
    // ignore: avoid_print
    print('[${sw.elapsedMilliseconds} ms] $port açıldı');

    final hello = await client.hello(
      // ignore: avoid_print
      onProgress: (i, n, booting) => print('  hello denemesi $i/$n${booting ? ' (ESP32 yeniden başlıyor)' : ''}'),
    );
    // ignore: avoid_print
    print('[${sw.elapsedMilliseconds} ms] hello: ${hello == null ? 'YANIT YOK' : '${hello.deviceId} fw=${hello.fw} window=${hello.window} state=${hello.state}'} boot_görüldü=${client.sawBoot}');
    expect(hello, isNotNull, reason: 'ESP32 hello yanıtı alınamadı');
    expect(hello!.deviceId, startsWith('esp32-argb-'));

    final st = await client.status();
    expect(st, isNotNull);
    // ignore: avoid_print
    print('status: window=${st!.window} remaining=${st.remainingMs} ms');

    if (st.window) {
      final r = await client.scan();
      // ignore: avoid_print
      print('scan: ok=${r.ok} error=${r.error} ağ=${r.networks.length}');
      expect(r.ok, isTrue);
      expect(r.networks, isNotEmpty);
    } else {
      final r = await client.scan(timeout: const Duration(seconds: 3));
      expect(r.error, 'window_closed', reason: 'pencere kapalıyken tarama reddedilmeli');
    }

    // ignore: avoid_print
    print('--- günlük (SSID/şifre maskeli) ---\n${log.lines.join('\n')}');
    expect(log.lines.join('\n').contains('"pass"'), isFalse);
    await client.close();
  }, skip: port == null ? 'ESP32_COM_PORT tanımlı değil (gerçek donanım testi)' : false, timeout: const Timeout(Duration(seconds: 60)));
}
