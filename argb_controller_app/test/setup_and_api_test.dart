import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/services/device_api.dart';
import 'package:argb_controller/services/device_discovery.dart';
import 'package:argb_controller/services/token_store.dart';
import 'package:argb_controller/state/setup_controller.dart';

import 'support/fake_esp32.dart';

const _tuning = SetupTuning(
  poll: Duration(milliseconds: 10),
  pairingTimeout: Duration(seconds: 2),
  scanTimeout: Duration(seconds: 2),
  connectTimeout: Duration(seconds: 2),
  rediscoverTimeout: Duration(seconds: 2),
);

SetupController makeSetup(FakeEsp32Http esp, MemoryTokenStore tokens, {List<FoundDevice>? known}) {
  final discovery = DeviceDiscovery(httpClientFactory: esp.client, useMdns: false, probeTimeout: const Duration(seconds: 1));
  return SetupController(
    tokens: tokens,
    discovery: discovery,
    clientName: 'Flutter test',
    tuning: _tuning,
    apiFactory: (d, t) => DeviceApi(host: d.host, port: d.port, token: t, client: esp.client()),
    onDeviceKnown: known?.add,
  );
}

Future<void> until(bool Function() cond, {int ms = 3000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(cond(), isTrue, reason: 'koşul zamanında sağlanmadı');
}

void main() {
  group('DeviceApi', () {
    test('discover token gerektirmez; info token olmadan 401', () async {
      final esp = FakeEsp32Http();
      final api = DeviceApi(host: 'x', client: esp.client());
      final d = await api.discover();
      expect(d.deviceId, 'esp32-argb-TEST01');
      expect(d.pairingOpen, isFalse);
      await expectLater(api.info(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'unauthorized')));
    });

    test('pair: pencere kapalıyken pairing_closed, açıkken token', () async {
      final esp = FakeEsp32Http();
      final api = DeviceApi(host: 'x', client: esp.client());
      await expectLater(api.pair('t'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'pairing_closed')));
      esp.pairingOpen = true;
      final r = await api.pair('t');
      expect(r.token.length, 64);
      api.token = r.token;
      final info = await api.info();
      expect(info.supportedEffects, contains('breathing'));
    });

    test('ağ hatası network koduna çevrilir', () async {
      final esp = FakeEsp32Http();
      final api = DeviceApi(host: 'x', client: esp.client(), timeout: const Duration(milliseconds: 200));
      // geçersiz yol 404 -> http_404/not_found
      expect(() async => api.listTokens(), throwsA(isA<ApiException>()));
    });
  });

  group('Kurulum sihirbazı (mock ESP32)', () {
    test('tam akış: AP -> BOOT eşleştirme -> tarama -> bağlan -> yeniden keşif -> bitti', () async {
      final esp = FakeEsp32Http();
      final tokens = MemoryTokenStore();
      final known = <FoundDevice>[];
      final c = makeSetup(esp, tokens, known: known);

      final probe = c.goToConnectAp();
      // Kullanıcı BOOT düğmesine basar
      Future<void>.delayed(const Duration(milliseconds: 80), () => esp.pairingOpen = true);
      await probe;
      await until(() => c.state.step == SetupStep.scan && c.state.scanDone);

      expect(await tokens.read(esp.deviceId), isNotNull);
      // Aynı SSID birleşti, kurumsal ağ desteklenmiyor olarak işaretli
      final groups = c.state.networks;
      expect(groups.map((g) => g.ssid), containsAll(['Home', 'Cafe', 'Corp']));
      expect(groups.where((g) => g.ssid == 'Home').single.accessPointCount, 2);
      expect(groups.firstWhere((g) => g.ssid == 'Corp').best.isSupported, isFalse);
      expect(groups.firstWhere((g) => g.ssid == 'Cafe').best.isOpen, isTrue);

      c.selectNetwork('Home');
      await c.connectToWifi('Home', 'password123');
      await until(() => c.state.step == SetupStep.done);

      expect(esp.wifiSsid, 'Home');
      expect(esp.wifiPassword, 'password123');
      expect(c.state.finalDevice, isNotNull);
      expect(c.state.finalDevice!.isSetupAp, isFalse);
      expect(known, isNotEmpty);
      // Şifre state'te hiçbir yerde tutulmaz
      expect(c.state.toString().contains('password123'), isFalse);
      expect(c.state.info?.contains('password123') ?? false, isFalse);
      c.dispose();
    });

    test('cihaz scan_failed bildirirse bir kez otomatik yeniden tarar', () async {
      final esp = FakeEsp32Http()..scanFailures = 1;
      final c = makeSetup(esp, MemoryTokenStore());
      esp.pairingOpen = true;
      await c.goToConnectAp();
      await until(() => c.state.scanDone);
      expect(esp.scanStarts, 2);
      expect(c.state.error, isNull);
      expect(c.state.networks.map((g) => g.ssid), contains('Home'));
      c.dispose();
    });

    test('tarama iki kez başarısız: hata gösterilir, tarama sürerken ikinci istek gitmez', () async {
      final esp = FakeEsp32Http()..scanFailures = 2;
      final c = makeSetup(esp, MemoryTokenStore());
      esp.pairingOpen = true;
      await c.goToConnectAp();
      await until(() => c.state.scanning);
      await c.scan(); // sürerken: yok sayılır
      await until(() => c.state.scanDone);
      expect(esp.scanStarts, 2);
      expect(c.state.error, contains('tarama'));
      expect(c.state.networks, isEmpty);
      await c.scan(); // kullanıcı tekrar dener
      await until(() => c.state.scanDone && c.state.networks.isNotEmpty);
      expect(c.state.error, isNull);
      c.dispose();
    });

    test('yanlış şifre: credentials adımına döner ve sebep gösterilir', () async {
      final esp = FakeEsp32Http()..connectShouldFail = true;
      final tokens = MemoryTokenStore();
      final c = makeSetup(esp, tokens);
      esp.pairingOpen = true;
      await c.goToConnectAp();
      await until(() => c.state.scanDone);
      await c.connectToWifi('Home', 'wrongpass1');
      expect(c.state.step, SetupStep.credentials);
      expect(c.state.error, contains('şifre'));
      c.dispose();
    });

    test('AP bulunamazsa anlaşılır hata', () async {
      final c = SetupController(
        tokens: MemoryTokenStore(),
        discovery: DeviceDiscovery(
          useMdns: false,
          probeTimeout: const Duration(milliseconds: 100),
          httpClientFactory: () => MockClient((r) async => throw Exception('down')),
        ),
        clientName: 't',
        tuning: _tuning,
      );
      await c.goToConnectAp();
      expect(c.state.error, contains('bulunamadı'));
      expect(c.state.busy, isFalse);
      c.dispose();
    });

    test('pairOnly: yalnızca eşleştirir ve biter', () async {
      final esp = FakeEsp32Http()..mode = 'sta';
      final tokens = MemoryTokenStore();
      final discovery = DeviceDiscovery(httpClientFactory: esp.client, useMdns: false);
      final c = SetupController(
        tokens: tokens,
        discovery: discovery,
        clientName: 't',
        tuning: _tuning,
        pairOnly: true,
        apiFactory: (d, t) => DeviceApi(host: d.host, token: t, client: esp.client()),
      );
      final dev = (await discovery.probe('192.168.1.40'))!;
      final f = c.startForDevice(dev);
      Future<void>.delayed(const Duration(milliseconds: 60), () => esp.pairingOpen = true);
      await f;
      await until(() => c.state.step == SetupStep.done);
      expect(await tokens.read(esp.deviceId), isNotNull);
      c.dispose();
    });
  });

  group('WLED erişim modu (DeviceApi)', () {
    test('varsayılan KAPALI; readonly token ile açılır; control fiziksel onay ister', () async {
      final esp = FakeEsp32Http()..validToken = 'a' * 64;
      final api = DeviceApi(host: 'x', token: 'a' * 64, client: esp.client());
      final w0 = await api.wledAccess();
      expect(w0.compiled, isTrue);
      expect(w0.mode, 'off');

      expect((await api.setWledMode('readonly')).mode, 'readonly');

      // Kimlik doğrulamasız kontrolü açmak: BOOT penceresi kapalıyken reddedilir
      await expectLater(
        api.setWledMode('control'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'pairing_closed')),
      );
      expect(esp.wledMode, 'readonly', reason: 'reddedilince mod değişmemeli');

      esp.pairingOpen = true; // kullanıcı BOOT'a bastı
      expect((await api.setWledMode('control')).mode, 'control');

      // Geri kapatmak yalnızca token ister
      esp.pairingOpen = false;
      expect((await api.setWledMode('off')).mode, 'off');
    });

    test('token olmadan WLED modu okunamaz/değiştirilemez; geçersiz mod reddedilir', () async {
      final esp = FakeEsp32Http()..validToken = 'a' * 64;
      final anon = DeviceApi(host: 'x', client: esp.client());
      await expectLater(anon.wledAccess(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'unauthorized')));
      await expectLater(anon.setWledMode('control'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'unauthorized')));

      final api = DeviceApi(host: 'x', token: 'a' * 64, client: esp.client());
      await expectLater(api.setWledMode('god'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_value')));
    });

    test('WLED derlenmemiş firmware: compiled=false', () async {
      final esp = FakeEsp32Http()
        ..validToken = 'a' * 64
        ..wledCompiled = false;
      final api = DeviceApi(host: 'x', token: 'a' * 64, client: esp.client());
      expect((await api.wledAccess()).compiled, isFalse);
    });
  });

  group('Token deposu', () {
    test('MemoryTokenStore kalıcı değildir; silme çalışır', () async {
      final t = MemoryTokenStore();
      expect(t.isPersistent, isFalse);
      await t.write('a', 'x');
      expect(await t.read('a'), 'x');
      await t.delete('a');
      expect(await t.read('a'), isNull);
    });
  });
}
