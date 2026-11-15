import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/effect_capabilities.dart';

/// Flutter <-> firmware sözleşme testleri: firmware kaynağını okuyarak
/// efekt listesi, hız formülü ve desteklenen efekt bildiriminin uyumunu doğrular.
/// (Donanım gerektirmez; depo kökündeki firmware/ klasörü yoksa atlanır.)
void main() {
  final root = Directory('../firmware');
  final types = File('../firmware/include/types.h');
  final engine = File('../firmware/src/led/animation_engine.cpp');
  final apiJson = File('../firmware/src/api/api_json.cpp');
  final available = root.existsSync() && types.existsSync() && engine.existsSync() && apiJson.existsSync();

  List<String> firmwareEffectNames() {
    final src = types.readAsStringSync();
    final block = RegExp(r'enum class EffectType[^{]*\{([^}]*)\}').firstMatch(src)!.group(1)!;
    return RegExp(r'(\w+)\s*=\s*(\d+)')
        .allMatches(block)
        .map((m) => (int.parse(m.group(2)!), m.group(1)!))
        .toList()
        .map((e) => e)
        .fold<List<String>>(List.filled(20, ''), (acc, e) {
      acc[e.$1] = e.$2;
      return acc;
    });
  }

  group('firmware sözleşmesi', skip: available ? false : 'firmware/ bulunamadı', () {
    test('EffectType adları ve sırası Dart enum ile birebir aynı', () {
      expect(EffectType.values.map((e) => e.name).toList(), firmwareEffectNames());
    });

    test('animasyon motoru 20 efektin her birini render eder (statik düşüş yok)', () {
      final src = engine.readAsStringSync();
      for (final n in firmwareEffectNames()) {
        expect(src.contains('case EffectType::$n:'), isTrue, reason: '$n için case yok');
      }
      // Bilinmeyen değer sessizce statik renge düşmemeli
      expect(src.contains('unknown effect id'), isTrue);
    });

    test('cihaz tüm efektleri desteklenen olarak bildirir', () {
      final src = apiJson.readAsStringSync();
      final block = RegExp(r'SUPPORTED_EFFECTS\[\]\s*=\s*\{([^}]*)\}').firstMatch(src)!.group(1)!;
      final listed = RegExp(r'"(\w+)"').allMatches(block).map((m) => m.group(1)!).toSet();
      expect(listed, firmwareEffectNames().toSet());
    });

    test('hız formülü firmware kaynağında docs ile aynı', () {
      final src = engine.readAsStringSync();
      expect(src.contains('5000 - (static_cast<uint32_t>(speed - 1) * 4500 / 99)'), isTrue);
      expect(src.contains('ms < 200 ? 200 : ms'), isTrue);
    });

    test('hız yalnızca yeni faz biriktirir: faz sıfırlama yok (sıçrama olmaz)', () {
      final src = engine.readAsStringSync();
      expect(RegExp(r'setAnimProgress\(0').hasMatch(src), isFalse);
    });
  });

  group('Flutter efekt kataloğu', () {
    test('20 efektin hepsi listede ve yetenek tablosunda var', () {
      final listed = Effect.builtInEffects.map((e) => e.type).toSet();
      expect(listed, EffectType.values.toSet());
      for (final t in EffectType.values) {
        final caps = effectCaps(t);
        // Her efekt en az bir parametreden (renk/hız/yoğunluk) etkilenir
        expect(caps.speed || caps.intensity || caps.color || caps.color2, isTrue, reason: t.name);
      }
    });

    test('hızdan etkilenmeyen efektler hız kontrolünü göstermez', () {
      expect(effectCaps(EffectType.staticColor).speed, isFalse);
      expect(effectCaps(EffectType.customGradient).speed, isFalse);
      for (final t in EffectType.values) {
        if (t != EffectType.staticColor && t != EffectType.customGradient) {
          expect(effectCaps(t).speed, isTrue, reason: t.name);
        }
      }
    });
  });
}
