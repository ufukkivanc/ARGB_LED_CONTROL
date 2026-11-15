import 'package:argb_controller/models/effect.dart';

/// Bir efektin hangi parametrelerden etkilendiği (docs/PROTOCOL.md §3.5 ile aynı tablo;
/// firmware animation_engine ile eşleşmelidir).
class EffectCaps {
  final bool speed;
  final bool intensity;
  final bool color;
  final bool color2;
  final bool direction;
  const EffectCaps({
    this.speed = false,
    this.intensity = false,
    this.color = false,
    this.color2 = false,
    this.direction = false,
  });
}

EffectCaps effectCaps(EffectType t) {
  switch (t) {
    case EffectType.staticColor:
      return const EffectCaps(color: true);
    case EffectType.rainbow:
      return const EffectCaps(speed: true, intensity: true, direction: true);
    case EffectType.rainbowCycle:
      return const EffectCaps(speed: true, intensity: true);
    case EffectType.breathing:
      return const EffectCaps(speed: true, intensity: true, color: true);
    case EffectType.colorFade:
      return const EffectCaps(speed: true, color: true, color2: true);
    case EffectType.colorWipe:
      return const EffectCaps(speed: true, color: true, color2: true, direction: true);
    case EffectType.runningLights:
      return const EffectCaps(speed: true, intensity: true, color: true, direction: true);
    case EffectType.theaterChase:
      return const EffectCaps(speed: true, intensity: true, color: true, color2: true, direction: true);
    case EffectType.fire:
      return const EffectCaps(speed: true, intensity: true);
    case EffectType.meteorRain:
      return const EffectCaps(speed: true, intensity: true, color: true, direction: true);
    case EffectType.twinkle:
      return const EffectCaps(speed: true, intensity: true, color: true, color2: true);
    case EffectType.sparkle:
      return const EffectCaps(speed: true, intensity: true, color: true, color2: true);
    case EffectType.policeLights:
      return const EffectCaps(speed: true, color: true, color2: true);
    case EffectType.wave:
      return const EffectCaps(speed: true, intensity: true, color: true, color2: true, direction: true);
    case EffectType.gradientMove:
      return const EffectCaps(speed: true, color: true, color2: true, direction: true);
    case EffectType.comet:
      return const EffectCaps(speed: true, intensity: true, color: true, direction: true);
    case EffectType.pulsing:
      return const EffectCaps(speed: true, intensity: true, color: true);
    case EffectType.randomTransitions:
      return const EffectCaps(speed: true, intensity: true);
    case EffectType.customGradient:
      return const EffectCaps(intensity: true, color: true, color2: true);
    case EffectType.musicReactive:
      return const EffectCaps(speed: true, intensity: true, color: true, color2: true);
  }
}

/// Yoğunluk kaydırıcısının efekte göre anlamı.
String effectIntensityLabel(EffectType t) {
  switch (t) {
    case EffectType.rainbow:
      return 'DAĞILIM';
    case EffectType.rainbowCycle:
    case EffectType.randomTransitions:
      return 'DOYGUNLUK';
    case EffectType.breathing:
    case EffectType.pulsing:
      return 'DERİNLİK';
    case EffectType.runningLights:
    case EffectType.wave:
      return 'DALGA BOYU';
    case EffectType.theaterChase:
      return 'ARALIK';
    case EffectType.fire:
      return 'ALEV';
    case EffectType.meteorRain:
    case EffectType.comet:
      return 'KUYRUK UZUNLUĞU';
    case EffectType.customGradient:
      return 'ORTA NOKTA';
    case EffectType.musicReactive:
      return 'DARBE ŞİDDETİ';
    default:
      return 'YOĞUNLUK';
  }
}
