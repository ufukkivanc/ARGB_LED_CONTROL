import 'package:flutter/material.dart';

import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/led_color.dart';

/// A saved lighting scene/preset.
class Scene {
  final String id;
  final String name;
  final EffectType effectType;
  final LedColor primaryColor;
  final LedColor? secondaryColor;
  final int brightness;
  final int speed;
  final int direction;
  final int intensity;
  final IconData icon;
  final bool isBuiltIn;

  const Scene({
    required this.id,
    required this.name,
    required this.effectType,
    required this.primaryColor,
    this.secondaryColor,
    this.brightness = 255,
    this.speed = 50,
    this.direction = 1,
    this.intensity = 50,
    this.icon = Icons.lightbulb_outline,
    this.isBuiltIn = false,
  });

  // ── copyWith ────────────────────────────────────────────────────────

  Scene copyWith({
    String? id,
    String? name,
    EffectType? effectType,
    LedColor? primaryColor,
    LedColor? secondaryColor,
    bool clearSecondaryColor = false,
    int? brightness,
    int? speed,
    int? direction,
    int? intensity,
    IconData? icon,
    bool? isBuiltIn,
  }) {
    return Scene(
      id: id ?? this.id,
      name: name ?? this.name,
      effectType: effectType ?? this.effectType,
      primaryColor: primaryColor ?? this.primaryColor,
      secondaryColor:
          clearSecondaryColor ? null : (secondaryColor ?? this.secondaryColor),
      brightness: brightness ?? this.brightness,
      speed: speed ?? this.speed,
      direction: direction ?? this.direction,
      intensity: intensity ?? this.intensity,
      icon: icon ?? this.icon,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
    );
  }

  // ── Serialization ───────────────────────────────────────────────────

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'effectType': effectType.index,
      'primaryColor': primaryColor.toJson(),
      if (secondaryColor != null) 'secondaryColor': secondaryColor!.toJson(),
      'brightness': brightness,
      'speed': speed,
      'direction': direction,
      'intensity': intensity,
      'iconCodePoint': icon.codePoint,
      'iconFontFamily': icon.fontFamily,
      'isBuiltIn': isBuiltIn,
    };
  }

  factory Scene.fromJson(Map<String, dynamic> json) {
    return Scene(
      id: json['id'] as String,
      name: json['name'] as String,
      effectType: EffectType.values[json['effectType'] as int],
      primaryColor: LedColor.fromJson(json['primaryColor'] as Map<String, dynamic>),
      secondaryColor: json['secondaryColor'] != null
          ? LedColor.fromJson(json['secondaryColor'] as Map<String, dynamic>)
          : null,
      brightness: (json['brightness'] as num?)?.toInt() ?? 255,
      speed: (json['speed'] as num?)?.toInt() ?? 50,
      direction: (json['direction'] as num?)?.toInt() ?? 1,
      intensity: (json['intensity'] as num?)?.toInt() ?? 50,
      icon: IconData(
        json['iconCodePoint'] as int? ?? Icons.lightbulb_outline.codePoint,
        fontFamily: json['iconFontFamily'] as String? ?? 'MaterialIcons',
      ),
      isBuiltIn: json['isBuiltIn'] as bool? ?? false,
    );
  }

  // ── Equality ────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Scene && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Scene($name, effect: $effectType)';

  // ── Built-in scenes ────────────────────────────────────────────────

  static final List<Scene> builtInScenes = [
    const Scene(
      id: 'scene_relax',
      name: 'Rahatla',
      effectType: EffectType.breathing,
      primaryColor: LedColor(r: 255, g: 147, b: 41),
      brightness: 140,
      speed: 25,
      intensity: 30,
      icon: Icons.self_improvement,
      isBuiltIn: true,
    ),
    const Scene(
      id: 'scene_gaming',
      name: 'Oyun',
      effectType: EffectType.rainbowCycle,
      primaryColor: LedColor(r: 108, g: 99, b: 255),
      secondaryColor: LedColor(r: 0, g: 210, b: 255),
      brightness: 255,
      speed: 75,
      intensity: 80,
      icon: Icons.sports_esports,
      isBuiltIn: true,
    ),
    const Scene(
      id: 'scene_party',
      name: 'Parti',
      effectType: EffectType.musicReactive,
      primaryColor: LedColor(r: 255, g: 0, b: 128),
      secondaryColor: LedColor(r: 0, g: 255, b: 128),
      brightness: 255,
      speed: 90,
      intensity: 95,
      icon: Icons.celebration,
      isBuiltIn: true,
    ),
    const Scene(
      id: 'scene_cinema',
      name: 'Sinema',
      effectType: EffectType.staticColor,
      primaryColor: LedColor(r: 20, g: 10, b: 50),
      brightness: 60,
      speed: 1,
      intensity: 20,
      icon: Icons.movie,
      isBuiltIn: true,
    ),
    const Scene(
      id: 'scene_night',
      name: 'Gece',
      effectType: EffectType.breathing,
      primaryColor: LedColor(r: 30, g: 0, b: 80),
      brightness: 40,
      speed: 15,
      intensity: 15,
      icon: Icons.nightlight_round,
      isBuiltIn: true,
    ),
    const Scene(
      id: 'scene_reading',
      name: 'Okuma',
      effectType: EffectType.staticColor,
      primaryColor: LedColor(r: 255, g: 230, b: 200),
      brightness: 200,
      speed: 1,
      intensity: 10,
      icon: Icons.menu_book,
      isBuiltIn: true,
    ),
    const Scene(
      id: 'scene_rainbow',
      name: 'Gökkuşağı',
      effectType: EffectType.rainbow,
      primaryColor: LedColor.red,
      brightness: 220,
      speed: 55,
      intensity: 60,
      icon: Icons.looks,
      isBuiltIn: true,
    ),
    const Scene(
      id: 'scene_ambient',
      name: 'Ortam',
      effectType: EffectType.gradientMove,
      primaryColor: LedColor(r: 80, g: 0, b: 200),
      secondaryColor: LedColor(r: 0, g: 100, b: 255),
      brightness: 160,
      speed: 30,
      intensity: 40,
      icon: Icons.blur_on,
      isBuiltIn: true,
    ),
  ];
}
