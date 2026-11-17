import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'package:argb_controller/main.dart';
import 'package:argb_controller/models/device_state.dart';
import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/screens/device_settings_screen.dart';
import 'package:argb_controller/screens/devices_screen.dart';
import 'package:argb_controller/screens/setup_screen.dart';
import 'package:argb_controller/screens/usb_setup_screen.dart';
import 'package:argb_controller/services/device_discovery.dart';
import 'package:argb_controller/services/serial/serial_transport.dart';
import 'package:argb_controller/state/app_state.dart';
import 'package:argb_controller/state/connection_controller.dart';
import 'package:argb_controller/state/usb_setup_controller.dart';
import 'package:argb_controller/theme/app_theme.dart';

/// Kompakt masaüstü penceresi (≈550×750) ve minimum boyutta taşma/istisna olmadığını doğrular.
/// Windows penceresi: başlangıç 550×750, minimum 420×560 (windows/runner/main.cpp, win32_window.cpp).

class _FakeUsb implements SerialBackend {
  @override
  bool get supported => true;
  @override
  List<SerialPortInfo> listPorts() => const [
        SerialPortInfo(name: 'COM3', description: 'Silicon Labs CP210x USB to UART Bridge', vendorId: 0x10C4),
        SerialPortInfo(name: 'COM1', description: 'Communications Port'),
      ];
  @override
  Future<SerialTransport> open(String portName, {int baudRate = 115200}) => Future.error(const SerialException('test'));
}

const sizes = <String, Size>{
  'başlangıç 550x750': Size(550, 750),
  'minimum 420x560': Size(420, 560),
  'orta 800x700': Size(800, 700),
  'geniş 1000x750': Size(1000, 750),
  'geniş 1280x720': Size(1280, 720),
};

List<Override> _overrides() => [
      discoveryProvider.overrideWithValue(DeviceDiscovery(
        useMdns: false,
        probeTimeout: const Duration(milliseconds: 50),
        httpClientFactory: () => MockClient((r) async => throw Exception('offline')),
      )),
      serialBackendProvider.overrideWithValue(_FakeUsb()),
    ];

Future<void> _pump(WidgetTester tester, Size size, Widget home) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: _overrides(),
    child: MaterialApp(theme: AppTheme.darkTheme, home: home),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  for (final e in sizes.entries) {
    group('düzen — ${e.key}', () {
      testWidgets('ana panel taşma yapmaz (Renk/Efekt/Sahne sekmeleri)', (tester) async {
        tester.view.physicalSize = e.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(ProviderScope(overrides: _overrides(), child: const ArgbControllerApp(bootstrap: false)));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull, reason: 'Renk sekmesi');

        for (final label in ['Efektler', 'Sahneler']) {
          final tab = find.textContaining(label);
          if (tab.evaluate().isNotEmpty) {
            await tester.tap(tab.first);
            await tester.pump(const Duration(milliseconds: 300));
            expect(tester.takeException(), isNull, reason: '$label sekmesi');
          }
        }
        await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -2000));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'kaydırma sonu');
      });

      testWidgets('cihazlar ekranı', (tester) async {
        await _pump(tester, e.value, const DevicesScreen());
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      });

      testWidgets('kurulum sihirbazı (SoftAP)', (tester) async {
        await _pump(tester, e.value, const SetupScreen());
        expect(tester.takeException(), isNull);
      });

      testWidgets('USB kurulum ekranı', (tester) async {
        await _pump(tester, e.value, const UsbSetupScreen());
        expect(tester.takeException(), isNull);
      });

      testWidgets('cihaz ayarları ekranı', (tester) async {
        await _pump(tester, e.value, const DeviceSettingsScreen(device: FoundDevice(id: 'esp32-argb-TEST01', name: 'ESP32 ARGB', host: '192.168.1.50')));
        expect(tester.takeException(), isNull);
      });
    });
  }

  group('Windows paketleme sözleşmesi', () {
    String read(String p) => File(p).readAsStringSync();

    test('pencere: ~550x750 başlangıç, ortalanır, yeniden boyutlandırılabilir, en az 420x560', () {
      final main = read('windows/runner/main.cpp');
      expect(main.contains('? work_w - 40 : 550') || main.contains('< 550 ? work_w - 40 : 550'), isTrue);
      expect(main.contains('< 750 ? work_h - 40 : 750'), isTrue);
      expect(main.contains('L"ARGB Controller"'), isTrue);
      final win = read('windows/runner/win32_window.cpp');
      expect(win.contains('WM_GETMINMAXINFO'), isTrue);
      expect(win.contains('Scale(420,') && win.contains('Scale(560,'), isTrue);
      // Sabit boyutlu (WS_THICKFRAME'siz) pencere stili kullanılmıyor: yeniden boyutlandırma açık
      expect(win.contains('WS_OVERLAPPEDWINDOW'), isTrue);
    });

    test('kimlik: görünen ad, ürün adı, ayar klasörü anahtarları ve sürüm', () {
      final rc = read('windows/runner/Runner.rc');
      expect(rc.contains('VALUE "ProductName", "ARGB Controller"'), isTrue);
      expect(rc.contains('VALUE "FileDescription", "ARGB Controller"'), isTrue);
      expect(rc.contains('VALUE "CompanyName", "ARGB LED Control"'), isTrue);
      expect(read('windows/CMakeLists.txt').contains('set(BINARY_NAME "ARGBController")'), isTrue);
      expect(RegExp(r'^version: \d+\.\d+\.\d+\+\d+', multiLine: true).hasMatch(read('pubspec.yaml')), isTrue);
      expect(File('windows/runner/resources/app_icon.ico').lengthSync(), greaterThan(10000));
    });

    test('Inno Setup: sabit AppId, kullanıcı bazlı, kısayollar, kaldırma, ayarlara dokunmama', () {
      final iss = read('../installer/ARGBController.iss');
      expect(iss.contains('AppId={{C02320E8-F7E1-4A83-8E1D-09DE273120A7}'), isTrue, reason: 'AppId asla değişmemeli');
      expect(iss.contains('PrivilegesRequired=lowest'), isTrue);
      expect(iss.contains('{autoprograms}') && iss.contains('{autodesktop}'), isTrue);
      expect(iss.contains('Tasks: desktopicon'), isTrue);
      expect(iss.contains('UninstallDisplayName'), isTrue);
      // Kaldırmada ayar silme yalnızca etkileşimli ve onaylıdır; sessizde asla
      expect(iss.contains('not UninstallSilent()'), isTrue);
      expect(iss.contains('MB_DEFBUTTON2'), isTrue);
      // Ayar klasörü anahtarları Runner.rc ile aynı
      expect(iss.contains('#define SettingsCompany "ARGB LED Control"'), isTrue);
      expect(iss.contains('#define SettingsProduct "ARGB Controller"'), isTrue);
      // [Files] uygulama klasörüne yazar, kullanıcı verisi klasörüne değil
      expect(RegExp(r'DestDir: "\{app\}"').hasMatch(iss), isTrue);
      expect(iss.contains('DestDir: "{userappdata}'), isFalse);
    });

    test('derleme betiği: VC++ DLL, ASCII yol çözümü, imza seçeneği, sürüm okuma', () {
      final ps = read('../scripts/build-windows-installer.ps1');
      for (final d in ['msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll']) {
        expect(ps.contains(d), isTrue, reason: d);
      }
      expect(ps.contains('subst'), isTrue);
      expect(ps.contains('SignCertThumbprint'), isTrue);
      expect(ps.contains('flutter build windows --release'), isTrue);
      expect(ps.contains('Get-FileHash'), isTrue);
    });
  });

  // Kullanılmayan import uyarılarını önlemek için tür referansları
  test('referanslar', () {
    expect(DeviceState.initial().effectType, EffectType.staticColor);
    expect(kMaxChannels, 4);
    expect(AppMode.values.length, 2);
    expect(DeviceConnection().status, LinkStatus.idle);
    expect(KnownDevice(id: 'a', name: 'b', host: 'c').port, 80);
  });
}
