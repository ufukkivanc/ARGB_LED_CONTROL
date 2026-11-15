import 'package:flutter/material.dart';

import 'package:argb_controller/models/led_color.dart';

/// All supported LED effect types.
enum EffectType {
  staticColor,
  rainbow,
  rainbowCycle,
  breathing,
  colorFade,
  colorWipe,
  runningLights,
  theaterChase,
  fire,
  meteorRain,
  twinkle,
  sparkle,
  policeLights,
  wave,
  gradientMove,
  comet,
  pulsing,
  randomTransitions,
  customGradient,
  musicReactive,
}

/// Represents a single LED strip effect with all configurable parameters.
class Effect {
  final String id;
  final EffectType type;
  final String name;
  final IconData icon;
  final String description;
  final int speed;
  final int brightness;
  final int direction;
  final LedColor primaryColor;
  final LedColor? secondaryColor;
  final int intensity;

  const Effect({
    required this.id,
    required this.type,
    required this.name,
    required this.icon,
    required this.description,
    this.speed = 50,
    this.brightness = 255,
    this.direction = 1,
    this.primaryColor = const LedColor(r: 255, g: 255, b: 255),
    this.secondaryColor,
    this.intensity = 50,
  });

  Effect copyWith({
    String? id,
    EffectType? type,
    String? name,
    IconData? icon,
    String? description,
    int? speed,
    int? brightness,
    int? direction,
    LedColor? primaryColor,
    LedColor? secondaryColor,
    bool clearSecondaryColor = false,
    int? intensity,
  }) {
    return Effect(
      id: id ?? this.id,
      type: type ?? this.type,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      description: description ?? this.description,
      speed: speed ?? this.speed,
      brightness: brightness ?? this.brightness,
      direction: direction ?? this.direction,
      primaryColor: primaryColor ?? this.primaryColor,
      secondaryColor:
          clearSecondaryColor ? null : (secondaryColor ?? this.secondaryColor),
      intensity: intensity ?? this.intensity,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Effect &&
        other.id == id &&
        other.type == type &&
        other.speed == speed &&
        other.brightness == brightness &&
        other.direction == direction &&
        other.primaryColor == primaryColor &&
        other.secondaryColor == secondaryColor &&
        other.intensity == intensity;
  }

  @override
  int get hashCode => Object.hash(
        id,
        type,
        speed,
        brightness,
        direction,
        primaryColor,
        secondaryColor,
        intensity,
      );

  @override
  String toString() => 'Effect($name, type: $type, speed: $speed)';

  // ── Built-in effects ────────────────────────────────────────────────

  static final List<Effect> builtInEffects = [
    const Effect(
      id: 'effect_static',
      type: EffectType.staticColor,
      name: 'Sabit Renk',
      icon: Icons.circle,
      description: 'Tek bir sabit renk gösterir.',
      speed: 1,
      primaryColor: LedColor.warmWhite,
    ),
    const Effect(
      id: 'effect_rainbow',
      type: EffectType.rainbow,
      name: 'Gökkuşağı',
      icon: Icons.looks,
      description:
          'Tüm LED şeridi boyunca gökkuşağı renkleri akar.',
      speed: 50,
      primaryColor: LedColor.red,
    ),
    const Effect(
      id: 'effect_rainbow_cycle',
      type: EffectType.rainbowCycle,
      name: 'Gökkuşağı Döngüsü',
      icon: Icons.sync,
      description:
          'Gökkuşağı renkleri hızla döner ve sürekli değişir.',
      speed: 60,
      primaryColor: LedColor.red,
    ),
    const Effect(
      id: 'effect_breathing',
      type: EffectType.breathing,
      name: 'Nefes',
      icon: Icons.air,
      description:
          'Seçilen renk nefes alır gibi yavaşça parlayıp söner.',
      speed: 40,
      primaryColor: LedColor.blue,
    ),
    const Effect(
      id: 'effect_color_fade',
      type: EffectType.colorFade,
      name: 'Renk Geçişi',
      icon: Icons.gradient,
      description:
          'Renkler arasında yumuşak geçiş yapar.',
      speed: 45,
      primaryColor: LedColor.red,
      secondaryColor: LedColor.blue,
    ),
    const Effect(
      id: 'effect_color_wipe',
      type: EffectType.colorWipe,
      name: 'Renk Silme',
      icon: Icons.format_paint,
      description:
          'Renk şerit boyunca bir uçtan diğerine yayılır.',
      speed: 55,
      primaryColor: LedColor.green,
    ),
    const Effect(
      id: 'effect_running_lights',
      type: EffectType.runningLights,
      name: 'Koşan Işıklar',
      icon: Icons.directions_run,
      description:
          'Işık noktaları şerit boyunca koşar gibi hareket eder.',
      speed: 60,
      primaryColor: LedColor.cyan,
    ),
    const Effect(
      id: 'effect_theater_chase',
      type: EffectType.theaterChase,
      name: 'Tiyatro Kovalamaca',
      icon: Icons.theaters,
      description:
          'Tiyatro tabelası tarzında sıralı yanıp sönen ışıklar.',
      speed: 65,
      primaryColor: LedColor.warmWhite,
    ),
    const Effect(
      id: 'effect_fire',
      type: EffectType.fire,
      name: 'Ateş',
      icon: Icons.local_fire_department,
      description:
          'Gerçekçi ateş / alev simülasyonu efekti.',
      speed: 70,
      primaryColor: LedColor.orange,
      secondaryColor: LedColor.red,
      intensity: 75,
    ),
    const Effect(
      id: 'effect_meteor_rain',
      type: EffectType.meteorRain,
      name: 'Meteor Yağmuru',
      icon: Icons.flash_on,
      description:
          'Gökyüzünden düşen meteor izleri gibi ışık çizgileri.',
      speed: 75,
      primaryColor: LedColor.purple,
      intensity: 60,
    ),
    const Effect(
      id: 'effect_twinkle',
      type: EffectType.twinkle,
      name: 'Pırıltı',
      icon: Icons.auto_awesome,
      description:
          'Rastgele LED\'ler yıldız gibi parıldar.',
      speed: 45,
      primaryColor: LedColor.warmWhite,
      intensity: 50,
    ),
    const Effect(
      id: 'effect_sparkle',
      type: EffectType.sparkle,
      name: 'Kıvılcım',
      icon: Icons.flare,
      description:
          'Hızlı ve parlak kıvılcım patlamaları.',
      speed: 80,
      primaryColor: LedColor.coolWhite,
      intensity: 70,
    ),
    const Effect(
      id: 'effect_police_lights',
      type: EffectType.policeLights,
      name: 'Polis Işıkları',
      icon: Icons.local_police,
      description:
          'Kırmızı ve mavi yanıp sönen polis sireni efekti.',
      speed: 85,
      primaryColor: LedColor.red,
      secondaryColor: LedColor.blue,
      intensity: 90,
    ),
    const Effect(
      id: 'effect_wave',
      type: EffectType.wave,
      name: 'Dalga',
      icon: Icons.waves,
      description:
          'Renk dalgaları şerit boyunca akıcı şekilde ilerler.',
      speed: 50,
      primaryColor: LedColor.blue,
      secondaryColor: LedColor.cyan,
    ),
    const Effect(
      id: 'effect_gradient_move',
      type: EffectType.gradientMove,
      name: 'Hareketli Gradyan',
      icon: Icons.linear_scale,
      description:
          'İki renk arası gradyan şerit üzerinde kayar.',
      speed: 40,
      primaryColor: LedColor.purple,
      secondaryColor: LedColor.pink,
    ),
    const Effect(
      id: 'effect_comet',
      type: EffectType.comet,
      name: 'Kuyruklu Yıldız',
      icon: Icons.rocket_launch,
      description:
          'Kuyruklu yıldız gibi parlak bir baş ve solan kuyruk.',
      speed: 70,
      primaryColor: LedColor.cyan,
      intensity: 65,
    ),
    const Effect(
      id: 'effect_pulsing',
      type: EffectType.pulsing,
      name: 'Nabız',
      icon: Icons.favorite,
      description:
          'Kalp atışı gibi ritmik parlaklık değişimi.',
      speed: 55,
      primaryColor: LedColor.red,
      intensity: 55,
    ),
    const Effect(
      id: 'effect_random_transitions',
      type: EffectType.randomTransitions,
      name: 'Rastgele Geçişler',
      icon: Icons.shuffle,
      description:
          'Rastgele renkler arasında akıcı geçişler yapar.',
      speed: 50,
      primaryColor: LedColor.warmWhite,
    ),
    const Effect(
      id: 'effect_custom_gradient',
      type: EffectType.customGradient,
      name: 'Özel Gradyan',
      icon: Icons.palette,
      description:
          'Kendi seçtiğiniz renklerle özel gradyan oluşturun.',
      speed: 35,
      primaryColor: LedColor.red,
      secondaryColor: LedColor.blue,
    ),
    const Effect(
      id: 'effect_music_reactive',
      type: EffectType.musicReactive,
      name: 'Müziğe Tepkili',
      icon: Icons.music_note,
      description:
          'Müziğin ritmine göre ışıklar dans eder.',
      speed: 50,
      primaryColor: LedColor.purple,
      secondaryColor: LedColor.cyan,
      intensity: 80,
    ),
  ];

  /// Look-up an effect by its [EffectType].
  static Effect byType(EffectType type) {
    return builtInEffects.firstWhere(
      (e) => e.type == type,
      orElse: () => builtInEffects.first,
    );
  }
}
