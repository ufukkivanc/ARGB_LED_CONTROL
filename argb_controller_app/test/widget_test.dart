import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argb_controller/main.dart';
import 'package:argb_controller/models/device_state.dart';
import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/led_color.dart';
import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/models/scene.dart';
import 'package:argb_controller/providers/device_provider.dart';
import 'package:argb_controller/widgets/led_strip_preview.dart';

Widget _preview(int speed, {EffectType effect = EffectType.rainbow}) => MaterialApp(
      home: Scaffold(
        body: LedStripPreview(
          isOn: true,
          color: const LedColor(r: 255, g: 0, b: 0),
          effectType: effect,
          brightness: 255,
          speed: speed,
        ),
      ),
    );

void main() {
  testWidgets('ARGB Controller Dashboard loads smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: ArgbControllerApp(bootstrap: false)));
    expect(find.text('ESP32 ARGB CONTROLLER'), findsOneWidget);
    expect(find.text('Simülasyon Modu'), findsOneWidget);
  });

  group('efekt hızı (speed) — simülasyon', () {
    testWidgets('hız değişince çalışan animasyonun periyodu GERÇEKTEN değişir', (tester) async {
      await tester.pumpWidget(_preview(10));
      final state = tester.state<LedStripPreviewState>(find.byType(LedStripPreview));
      expect(state.period, Duration(milliseconds: speedToPeriodMs(10)));

      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(_preview(90));
      expect(state.period, Duration(milliseconds: speedToPeriodMs(90)));
      expect(state.period!, lessThan(Duration(milliseconds: speedToPeriodMs(10))));
    });

    testWidgets('yüksek hız aynı sürede daha fazla ilerleme sağlar (görsel olarak hissedilir)', (tester) async {
      Future<double> advanceFor(int speed) async {
        await tester.pumpWidget(_preview(speed));
        final state = tester.state<LedStripPreviewState>(find.byType(LedStripPreview));
        final before = state.debugProgress;
        await tester.pump(const Duration(milliseconds: 250));
        final after = state.debugProgress;
        var d = after - before;
        if (d < 0) d += 1.0;
        return d;
      }

      final slow = await advanceFor(5);
      final fast = await advanceFor(95);
      expect(fast, greaterThan(slow * 3));
    });

    testWidgets('çalışırken hız değişimi mevcut fazı sıfırlamaz (sıçrama yok)', (tester) async {
      await tester.pumpWidget(_preview(20));
      final state = tester.state<LedStripPreviewState>(find.byType(LedStripPreview));
      await tester.pump(const Duration(milliseconds: 700));
      final before = state.debugProgress;
      await tester.pumpWidget(_preview(80));
      await tester.pump();
      expect((state.debugProgress - before).abs(), lessThan(0.05));
    });
  });

  group('DeviceNotifier', () {
    test('renk değişimi yalnızca renk alanını gönderir, efekti değiştirmez', () {
      final sent = <Map<String, dynamic>>[];
      final n = DeviceNotifier(
        initial: DeviceState.initial().copyWith(effectType: EffectType.breathing, speed: 30),
      )..onSend = sent.add;
      n.setColor(const LedColor(r: 1, g: 2, b: 3));
      expect(sent.single.keys, ['color']);
      expect(n.state.effectType, EffectType.breathing);
      expect(n.state.speed, 30);
    });

    test('hız kaydırıcısı değeri speed alanı olarak iletilir ve 1..100 sıkıştırılır', () {
      final sent = <Map<String, dynamic>>[];
      final n = DeviceNotifier()..onSend = sent.add;
      n.setSpeed(75);
      n.setSpeed(500);
      n.setSpeed(-3);
      expect(sent.map((m) => m['speed']).toList(), [75, 100, 1]);
    });

    test('uzaktan gelen durum geri gönderim (echo) üretmez', () {
      final sent = <Map<String, dynamic>>[];
      final n = DeviceNotifier()..onSend = sent.add;
      n.applyRemote(n.state.copyWith(brightness: 12));
      expect(n.state.brightness, 12);
      expect(sent, isEmpty);
    });

    test('simülasyonda (onSend null) yerel state çalışır', () {
      final n = DeviceNotifier();
      n.togglePower();
      n.setEffect(EffectType.fire);
      n.setIntensity(80);
      expect(n.state.isOn, isFalse);
      expect(n.state.effectType, EffectType.fire);
      expect(n.state.intensity, 80);
    });

    test('sahne tek atomik mesaj olarak gider', () {
      final sent = <Map<String, dynamic>>[];
      final n = DeviceNotifier()..onSend = sent.add;
      n.applyScene(Scene.builtInScenes.first);
      expect(sent.length, 1);
    });
  });
}
