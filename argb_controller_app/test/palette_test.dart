import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'package:argb_controller/main.dart';
import 'package:argb_controller/models/device_state.dart';
import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/led_color.dart';
import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/providers/device_provider.dart';
import 'package:argb_controller/screens/device_settings_screen.dart';
import 'package:argb_controller/services/device_discovery.dart';
import 'package:argb_controller/services/serial/serial_transport.dart';
import 'package:argb_controller/services/token_store.dart';
import 'package:argb_controller/state/app_state.dart';
import 'package:argb_controller/state/connection_controller.dart';
import 'package:argb_controller/state/usb_setup_controller.dart';
import 'package:argb_controller/theme/app_theme.dart';
import 'package:argb_controller/widgets/palette_editor.dart';

import 'support/fake_esp32.dart';

class _NoUsb implements SerialBackend {
  @override
  bool get supported => false;
  @override
  List<SerialPortInfo> listPorts() => const [];
  @override
  Future<SerialTransport> open(String portName, {int baudRate = 115200}) => Future.error(const SerialException('test'));
}

const _red = LedColor(r: 255, g: 0, b: 0);
const _green = LedColor(r: 0, g: 255, b: 0);
const _blue = LedColor(r: 0, g: 0, b: 255);

Map<String, dynamic> _wire(LedColor c) => {'r': c.r, 'g': c.g, 'b': c.b};

List<Override> _overrides() => [
      discoveryProvider.overrideWithValue(DeviceDiscovery(
        useMdns: false,
        probeTimeout: const Duration(milliseconds: 50),
        httpClientFactory: () => MockClient((r) async => throw Exception('offline')),
      )),
      serialBackendProvider.overrideWithValue(_NoUsb()),
    ];

void main() {
  group('palet protokolü', () {
    test('state: palette dizisi ayrıştırılır; yoksa boş (eski firmware)', () {
      final j = channelJson()..['palette'] = [_wire(_red), _wire(_green), _wire(_blue)];
      final c = ChannelState.tryParse(j)!;
      expect(c.palette, [_red, _green, _blue]);
      expect(ChannelState.tryParse(channelJson())!.palette, isEmpty);
    });

    test('en fazla 5 renk; geçersiz öğeler atlanır', () {
      final seven = [for (var i = 0; i < 7; i++) {'r': i * 10, 'g': 0, 'b': 0}];
      expect(paletteFromWire(seven).length, kMaxPaletteColors);
      expect(paletteFromWire([_wire(_red), 'x', {'r': 'a', 'g': 0, 'b': 0}, _wire(_blue)]).length, 2);
      // aralık dışı değerler 0..255'e sıkıştırılır
      expect(paletteFromWire([{'r': 999, 'g': -5, 'b': 0}]).single, const LedColor(r: 255, g: 0, b: 0));
      expect(paletteFromWire(null), isEmpty);
    });

    test('set farkı: yalnızca palet değiştiyse palette alanı gider', () {
      const base = DeviceState(
        isOn: true, color: _red, effectType: EffectType.breathing, brightness: 200, speed: 50, direction: 1, intensity: 50,
      );
      final withPal = base.copyWith(palette: [_red, _green]);
      final f = deviceStateDiffToFields(base, withPal);
      expect(f.keys, ['palette']);
      expect(f['palette'], [_wire(_red), _wire(_green)]);
      expect(deviceStateDiffToFields(withPal, withPal.copyWith()), isEmpty);
      // efekt değişince palet korunur ve yalnızca efekt gönderilir
      final f2 = deviceStateDiffToFields(withPal, withPal.copyWith(effectType: EffectType.comet));
      expect(f2.keys, ['effect']);
      // paleti temizleme
      expect(deviceStateDiffToFields(withPal, base)['palette'], isEmpty);
    });

    test('DeviceState eşitliği ve withFields palete duyarlı', () {
      const a = DeviceState(
        isOn: true, color: _red, effectType: EffectType.wave, brightness: 1, speed: 1, direction: 1, intensity: 1,
      );
      expect(a == a.copyWith(palette: [_red]), isFalse);
      expect(a.copyWith(palette: [_red]) == a.copyWith(palette: [_red]), isTrue);
      final c = ChannelState.tryParse(channelJson())!.withFields({'palette': [_wire(_blue)]});
      expect(c.palette, [_blue]);
      expect(c.toDeviceState().palette, [_blue]);
    });

    test('DeviceInfo: özellikler ve LED sınırları', () {
      final i = DeviceInfo.tryParse({
        'deviceId': 'x',
        'features': ['palette', 'liveLedCount'],
        'maxLedsPerChannel': 512,
        'maxTotalLeds': 1024,
        'warnLedsPerChannel': 300,
        'warnTotalLeds': 600,
        'channelConfigs': [
          {'ch': 1, 'enabled': true, 'ledCount': 30, 'pending': {'ledCount': 60, 'enabled': true, 'colorOrder': 'GRB'}},
        ],
      })!;
      expect(i.supportsPalette, isTrue);
      expect(i.maxLedsPerChannel, 512);
      expect(i.warnTotalLeds, 600);
      expect(i.channels.first.pendingLedCount, 60);
      // eski firmware
      final old = DeviceInfo.tryParse({'deviceId': 'x'})!;
      expect(old.supportsPalette, isFalse);
      expect(old.maxLedsPerChannel, 512);
    });
  });

  group('DeviceNotifier palet', () {
    test('palet ayarı yalnızca palette alanını gönderir; efekt ve renk etkilenmez', () {
      final sent = <Map<String, dynamic>>[];
      final n = DeviceNotifier(onSend: sent.add);
      final fx = n.state.effectType;
      final col = n.state.color;
      n.setPalette([_red, _green, _blue]);
      expect(sent.single.keys, ['palette']);
      expect(n.state.effectType, fx);
      expect(n.state.color, col);
      n.setEffect(EffectType.comet);
      expect(n.state.palette.length, 3, reason: 'efekt değişince palet korunur');
      sent.clear();
      n.setPalette(const []);
      expect(sent.single['palette'], isEmpty);
      n.setPalette([for (var i = 0; i < 9; i++) LedColor(r: i, g: 0, b: 0)]);
      expect(n.state.palette.length, 5);
    });
  });

  group('PaletteEditor', () {
    Future<void> pumpEditor(WidgetTester tester, List<List<LedColor>> log, {Size size = const Size(420, 560), bool enabled = true}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var palette = <LedColor>[];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: StatefulBuilder(builder: (context, setState) {
            return SingleChildScrollView(
              child: PaletteEditor(
                palette: palette,
                baseColor: _red,
                enabled: enabled,
                onChanged: (p) {
                  log.add(p);
                  setState(() => palette = p);
                },
              ),
            );
          }),
        ),
      ));
    }

    testWidgets('1–5 renk eklenir; 5 renkte + kaybolur; taşma yok', (tester) async {
      final log = <List<LedColor>>[];
      await pumpEditor(tester, log);
      expect(find.byKey(const Key('palette_add')), findsOneWidget);
      for (var i = 0; i < 5; i++) {
        await tester.ensureVisible(find.byKey(const Key('palette_add')));
        await tester.tap(find.byKey(const Key('palette_add')));
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);
      }
      expect(log.last.length, 5);
      expect(find.byKey(const Key('palette_add')), findsNothing, reason: 'en çok 5 renk');
      expect(find.textContaining('Palet etkin (5 renk)'), findsOneWidget);
    });

    testWidgets('gerçek renk çarkıyla seçili rengi değiştirme, sıralama, silme, temizleme', (tester) async {
      final log = <List<LedColor>>[];
      await pumpEditor(tester, log);
      for (var i = 0; i < 3; i++) {
        await tester.ensureVisible(find.byKey(const Key('palette_add')));
        await tester.tap(find.byKey(const Key('palette_add')));
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(log.last.length, 3);
      // son eklenen renk seçili: çarkın sağ kenarına dokun -> kırmızı ton
      final wheel = find.byKey(const ValueKey('palette_wheel_2'));
      expect(wheel, findsOneWidget);
      final r = tester.getRect(wheel);
      await tester.tapAt(Offset(r.center.dx + 80, r.center.dy - 70));
      await tester.pump();
      expect(log.last[2], isNot(_red), reason: 'çark seçili rengi değiştirdi');
      expect(log.last[0], _red);
      expect(log.last.length, 3);

      // sırala: 3. (seçili) rengi sola taşı
      final edited = log.last[2];
      await tester.ensureVisible(find.byKey(const Key('palette_left')));
      await tester.tap(find.byKey(const Key('palette_left')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(log.last[1], edited);
      expect(tester.widget<IconButton>(find.byKey(const Key('palette_right'))).onPressed, isNotNull);

      // 1. renge geç: sola taşıma pasif
      await tester.ensureVisible(find.byKey(const Key('palette_swatch_2')));
      await tester.tap(find.byKey(const Key('palette_swatch_0')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.widget<IconButton>(find.byKey(const Key('palette_left'))).onPressed, isNull);

      // sil
      await tester.ensureVisible(find.byKey(const Key('palette_delete')));
      await tester.tap(find.byKey(const Key('palette_delete')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(log.last.length, 2);

      // temizle
      await tester.ensureVisible(find.byKey(const Key('palette_clear')));
      await tester.tap(find.byKey(const Key('palette_clear')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(log.last, isEmpty);
      expect(find.textContaining('Palet boş'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('desteklemeyen firmware: düzenleme kapalı, açıklama gösterilir', (tester) async {
      final log = <List<LedColor>>[];
      await pumpEditor(tester, log, enabled: false);
      await tester.tap(find.byKey(const Key('palette_add')), warnIfMissed: false);
      await tester.pump();
      expect(log, isEmpty);
      expect(find.textContaining('palet desteklemiyor'), findsOneWidget);
    });
  });

  group('panoda palet (Renk/Efektler sekmeleri, tüm boyutlar)', () {
    for (final size in const [Size(420, 560), Size(550, 750), Size(800, 700), Size(1000, 750), Size(1280, 720)]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}: 5 renk ekle, efektlerde not, taşma yok', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(ProviderScope(overrides: _overrides(), child: const ArgbControllerApp(bootstrap: false)));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);

        for (var i = 0; i < 5; i++) {
          await tester.ensureVisible(find.byKey(const Key('palette_add')));
          await tester.tap(find.byKey(const Key('palette_add')));
          await tester.pump(const Duration(milliseconds: 250));
          expect(tester.takeException(), isNull, reason: 'renk ${i + 1}');
        }
        expect(find.byKey(const Key('palette_add')), findsNothing);

        await tester.ensureVisible(find.textContaining('Efektler').first);
        await tester.tap(find.textContaining('Efektler').first);
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('palette_add')), findsNothing, reason: 'Efektler sekmesine geçildi');
        expect(find.textContaining('Palet etkin (5 renk): efekt yalnızca palet renklerini kullanır'), findsOneWidget);
        // palet etkinken 2. renk kartı yok (efektler yalnızca paleti kullanır)
        expect(find.text('İKİNCİ RENK'), findsNothing);

        await tester.ensureVisible(find.text('Düzenle'));
        await tester.tap(find.text('Düzenle'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('palette_swatch_0')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('LED sayısı ayarları (cihaz ayarları ekranı)', () {
    const dev = FoundDevice(id: 'esp32-argb-TEST01', name: 'ESP32 Test', host: '192.168.1.40');

    testWidgets('alanlar cihazdaki sayıları gösterir; doğrulama, uyarı ve 4x30 doldurma (cihaza otomatik gönderim yok)', (tester) async {
      tester.view.physicalSize = const Size(550, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final tokens = MemoryTokenStore();
      await tokens.write(dev.id, 'tok');
      late FakeSocket socket;
      final controller = DeviceConnectionController(
        tokens: tokens,
        tuning: const ConnectionTuning(
          throttle: Duration(milliseconds: 30),
          authTimeout: Duration(milliseconds: 300),
          connectTimeout: Duration(milliseconds: 300),
          pingInterval: Duration(seconds: 30),
          silenceTimeout: Duration(seconds: 60),
          suppressRemote: Duration(milliseconds: 100),
          backoff: [Duration(milliseconds: 30)],
        ),
        socketFactory: (_) {
          socket = FakeSocket();
          socket.onClient = (m) {
            if (m['type'] == 'auth') {
              socket.emit({'v': 1, 'type': 'authOk', 'deviceId': dev.id, 'tokenId': 'abcd1234'});
              socket.emit(stateMsg(channels: [
                channelJson(ch: 1),
                {...channelJson(ch: 2), 'ledCount': 20},
                {...channelJson(ch: 3, enabled: false), 'ledCount': 0},
                {...channelJson(ch: 4, enabled: false), 'ledCount': 0},
              ]));
            }
          };
          return socket;
        },
      );
      await tester.runAsync(() async {
        await controller.connect(dev);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      expect(controller.state.channels.length, 4);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          ..._overrides(),
          connectionProvider.overrideWith((ref) => controller),
          tokenStoreProvider.overrideWithValue(MemoryTokenStore()),
        ],
        child: MaterialApp(theme: AppTheme.darkTheme, home: const DeviceSettingsScreen(device: dev)),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      String text(int ch) => tester.widget<TextField>(find.byKey(Key('led_count_$ch'))).controller!.text;
      Future<void> enter(int ch, String v) async {
        await tester.ensureVisible(find.byKey(Key('led_count_$ch')));
        await tester.enterText(find.byKey(Key('led_count_$ch')), v);
        await tester.pump();
      }

      // mevcut kayıtlı sayılar gösterilir (otomatik 30'a çevrilmez)
      expect([for (var c = 1; c <= 4; c++) text(c)], ['30', '20', '0', '0']);
      expect(tester.widget<FilledButton>(find.byKey(const Key('led_apply'))).onPressed, isNull, reason: 'değişiklik yok');
      expect(find.textContaining('Toplam 50 LED'), findsOneWidget);

      // 4 x 30 hazır dolum: yalnızca alanları doldurur
      await tester.ensureVisible(find.byKey(const Key('led_fill_30')));
      await tester.tap(find.byKey(const Key('led_fill_30')));
      await tester.pump();
      expect([for (var c = 1; c <= 4; c++) text(c)], ['30', '30', '30', '30']);
      expect(find.textContaining('Toplam 120 LED'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('led_apply'))).onPressed, isNotNull);
      expect(socket.sent.where((m) => m['type'] == 'setChannelConfig'), isEmpty, reason: 'Uygula\'ya basılmadan cihaza gönderim yok');

      // sınırlar
      await enter(1, '600');
      expect(find.textContaining('0–512'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('led_apply'))).onPressed, isNull);
      await enter(1, '500');
      await enter(2, '300');
      await enter(3, '300');
      expect(find.textContaining('1024 sınırını aşıyor'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('led_apply'))).onPressed, isNull);
      await enter(1, '310');
      await enter(2, '10');
      await enter(3, '10');
      await enter(4, '10');
      expect(find.textContaining('kare hızı düşebilir'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('led_apply'))).onPressed, isNotNull, reason: 'yüksek sayı yalnızca uyarıdır');
      expect(tester.takeException(), isNull);
    });
  });
}
