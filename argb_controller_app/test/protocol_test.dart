import 'package:flutter_test/flutter_test.dart';

import 'package:argb_controller/models/device_state.dart';
import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/effect_capabilities.dart';
import 'package:argb_controller/models/led_color.dart';
import 'package:argb_controller/models/protocol.dart';

import 'support/fake_esp32.dart';

void main() {
  group('hız (speed) semantiği', () {
    test('firmware formülüyle birebir: 1 -> 5000 ms, 100 -> 500 ms', () {
      expect(speedToPeriodMs(1), 5000);
      expect(speedToPeriodMs(100), 500);
      // firmware: 5000 - (49 * 4500 / 99) = 5000 - 2227 (tamsayı bölme)
      expect(speedToPeriodMs(50), 2773);
    });

    test('hız arttıkça periyot kısalır (animasyon hızlanır)', () {
      var prev = speedToPeriodMs(1);
      for (var s = 2; s <= 100; s++) {
        final cur = speedToPeriodMs(s);
        expect(cur, lessThanOrEqualTo(prev), reason: 'speed=$s');
        prev = cur;
      }
      expect(speedToPeriodMs(80), lessThan(speedToPeriodMs(20)));
    });

    test('aralık dışı değerler sıkıştırılır', () {
      expect(speedToPeriodMs(-5), speedToPeriodMs(1));
      expect(speedToPeriodMs(1000), speedToPeriodMs(100));
    });
  });

  group('efekt adları', () {
    test('20 efekt, firmware types.h sırası ve adlarıyla aynı', () {
      const firmware = [
        'staticColor', 'rainbow', 'rainbowCycle', 'breathing', 'colorFade', 'colorWipe',
        'runningLights', 'theaterChase', 'fire', 'meteorRain', 'twinkle', 'sparkle',
        'policeLights', 'wave', 'gradientMove', 'comet', 'pulsing', 'randomTransitions',
        'customGradient', 'musicReactive',
      ];
      expect(EffectType.values.map((e) => e.name).toList(), firmware);
    });

    test('bilinmeyen efekt adı null döner (sessizce staticColor olmaz)', () {
      expect(effectTypeFromName('nope'), isNull);
      expect(effectTypeFromName(null), isNull);
      expect(effectTypeFromName('comet'), EffectType.comet);
    });

    test('her efekt için yetenek tablosu tanımlı; statik efekt hızsız', () {
      for (final t in EffectType.values) {
        expect(() => effectCaps(t), returnsNormally);
      }
      expect(effectCaps(EffectType.staticColor).speed, isFalse);
      expect(effectCaps(EffectType.rainbow).speed, isTrue);
      expect(effectCaps(EffectType.colorFade).color2, isTrue);
    });
  });

  group('tel biçimi', () {
    test('renk yalnızca {r,g,b} olarak kodlanır (brightness yok)', () {
      final w = colorToWire(const LedColor(r: 1, g: 2, b: 3, brightness: 100));
      expect(w, {'r': 1, 'g': 2, 'b': 3});
    });

    test('state kanalı ayrıştırılır', () {
      final ch = ChannelState.tryParse(channelJson(effect: 'rainbow', speed: 80));
      expect(ch, isNotNull);
      expect(ch!.effect, EffectType.rainbow);
      expect(ch.speed, 80);
      expect(ch.color, const LedColor(r: 108, g: 99, b: 255));
    });

    test('geçersiz kanal/efekt reddedilir', () {
      expect(ChannelState.tryParse({...channelJson(), 'effect': 'bogus'}), isNull);
      expect(ChannelState.tryParse({...channelJson(), 'ch': 9}), isNull);
      expect(ChannelState.tryParse('x'), isNull);
    });

    test('DeviceState farkı yalnızca değişen alanları üretir; efekt adı string', () {
      final a = DeviceState.initial();
      final b = a.copyWith(effectType: EffectType.fire, speed: 90, color: const LedColor(r: 9, g: 8, b: 7));
      final f = deviceStateDiffToFields(a, b);
      expect(f.keys.toSet(), {'effect', 'speed', 'color'});
      expect(f['effect'], 'fire');
      expect(f['color'], {'r': 9, 'g': 8, 'b': 7});
    });

    test('renk değişimi efekt/hız/parlaklık alanı üretmez', () {
      final a = DeviceState.initial().copyWith(effectType: EffectType.breathing);
      final b = a.copyWith(color: const LedColor(r: 1, g: 1, b: 1));
      expect(deviceStateDiffToFields(a, b).keys, ['color']);
    });

    test('DeviceState.fromJson geçersiz efekt indeksinde çökmez', () {
      final s = DeviceState.fromJson({'effectType': 999});
      expect(s.effectType, EffectType.staticColor);
      final t = DeviceState.fromJson({'effectType': 'comet'});
      expect(t.effectType, EffectType.comet);
    });

    test('DiscoverInfo / DeviceInfo ayrıştırma', () {
      final d = DiscoverInfo.tryParse({
        'deviceId': 'x', 'name': 'n', 'model': 'm', 'fw': '1', 'proto': 1,
        'paired': true, 'pairingOpen': false, 'mode': 'sta',
      });
      expect(d!.paired, isTrue);
      expect(DiscoverInfo.tryParse({'name': 'no id'}), isNull);
      final i = DeviceInfo.tryParse({
        'deviceId': 'x', 'supportedEffects': ['staticColor'], 'wifi': {'mode': 'sta', 'ip': '1.2.3.4'},
      });
      expect(i!.supportedEffects, {'staticColor'});
      expect(i.ip, '1.2.3.4');
    });
  });

  group('Wi-Fi ağ listesi', () {
    test('aynı SSID tek satırda toplanır, en güçlü sinyal korunur', () {
      final nets = [
        const WifiNetwork(ssid: 'Home', rssi: -70, security: 'WPA2_PSK', channel: 11),
        const WifiNetwork(ssid: 'Home', rssi: -50, security: 'WPA2_PSK', channel: 6),
        const WifiNetwork(ssid: 'Cafe', rssi: -80, security: 'OPEN', channel: 1),
        const WifiNetwork(ssid: '', rssi: -40, security: 'OPEN', channel: 1),
      ];
      final g = groupNetworks(nets);
      expect(g.length, 2);
      expect(g.first.ssid, 'Home');
      expect(g.first.best.rssi, -50);
      expect(g.first.accessPointCount, 2);
      expect(g.last.best.isOpen, isTrue);
    });

    test('sinyal çubukları ve desteklenmeyen güvenlik', () {
      expect(signalBars(-40), 4);
      expect(signalBars(-90), 0);
      expect(const WifiNetwork(ssid: 'c', rssi: -50, security: 'WPA2_ENTERPRISE', channel: 1).isSupported, isFalse);
    });

    test('hata metinleri ayrıdır', () {
      expect(describeWifiError('auth_failed'), contains('şifre'));
      expect(describeWifiError('not_found'), contains('bulunamadı'));
      expect(describeWifiError('timeout'), contains('zaman aşımı'));
      expect(describeApiError(const ApiException('pairing_closed')), contains('BOOT'));
    });
  });
}
