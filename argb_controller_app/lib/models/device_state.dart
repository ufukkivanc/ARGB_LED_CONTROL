import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/led_color.dart';

/// Seçili LED kanalının arayüz durumu.
///
/// Cihaz modunda ESP32'den gelen `state` mesajı, simülasyon modunda yerel
/// değerler bu nesneyi doldurur.
class DeviceState {
  final bool isOn;
  final LedColor color;
  final LedColor secondaryColor;
  final EffectType effectType;
  final int brightness;
  final int speed;
  final int direction;
  final int intensity;

  /// Kanal paleti (0..5 renk). Boşsa efektler kendi varsayılan renk davranışını korur; doluysa yalnızca palet renklerini kullanır.
  final List<LedColor> palette;

  const DeviceState({
    required this.isOn,
    required this.color,
    this.secondaryColor = const LedColor(r: 0, g: 210, b: 255),
    required this.effectType,
    required this.brightness,
    required this.speed,
    required this.direction,
    required this.intensity,
    this.palette = const [],
  });

  // ── Defaults ────────────────────────────────────────────────────────

  /// Sensible power-on defaults.
  factory DeviceState.initial() {
    return const DeviceState(
      isOn: false,
      color: LedColor(r: 255, g: 180, b: 107), // warm white
      effectType: EffectType.staticColor,
      brightness: 200,
      speed: 50,
      direction: 1,
      intensity: 50,
    );
  }

  // ── copyWith ────────────────────────────────────────────────────────

  DeviceState copyWith({
    bool? isOn,
    LedColor? color,
    LedColor? secondaryColor,
    EffectType? effectType,
    int? brightness,
    int? speed,
    int? direction,
    int? intensity,
    List<LedColor>? palette,
  }) {
    return DeviceState(
      isOn: isOn ?? this.isOn,
      color: color ?? this.color,
      secondaryColor: secondaryColor ?? this.secondaryColor,
      effectType: effectType ?? this.effectType,
      brightness: brightness ?? this.brightness,
      speed: speed ?? this.speed,
      direction: direction ?? this.direction,
      intensity: intensity ?? this.intensity,
      palette: palette ?? this.palette,
    );
  }

  // ── Serialization (yerel; tel biçimi için models/protocol.dart) ─────

  Map<String, dynamic> toJson() {
    return {
      'isOn': isOn,
      'color': color.toJson(),
      'secondaryColor': secondaryColor.toJson(),
      'effectType': effectType.name,
      'brightness': brightness,
      'speed': speed,
      'direction': direction,
      'intensity': intensity,
      'palette': [for (final c in palette) c.toJson()],
    };
  }

  factory DeviceState.fromJson(Map<String, dynamic> json) {
    // Efekt adıyla güvenli ayrıştırma (eski sürümlerdeki index de kabul edilir).
    EffectType effect = EffectType.staticColor;
    final raw = json['effectType'];
    if (raw is String) {
      effect = EffectType.values.firstWhere(
        (t) => t.name == raw,
        orElse: () => EffectType.staticColor,
      );
    } else if (raw is num) {
      final i = raw.toInt();
      if (i >= 0 && i < EffectType.values.length) effect = EffectType.values[i];
    }
    return DeviceState(
      isOn: json['isOn'] as bool? ?? false,
      color: json['color'] != null
          ? LedColor.fromJson(json['color'] as Map<String, dynamic>)
          : const LedColor(r: 255, g: 180, b: 107),
      secondaryColor: json['secondaryColor'] != null
          ? LedColor.fromJson(json['secondaryColor'] as Map<String, dynamic>)
          : const LedColor(r: 0, g: 210, b: 255),
      effectType: effect,
      brightness: (json['brightness'] as num?)?.toInt() ?? 200,
      speed: (json['speed'] as num?)?.toInt() ?? 50,
      direction: (json['direction'] as num?)?.toInt() ?? 1,
      intensity: (json['intensity'] as num?)?.toInt() ?? 50,
      palette: [
        if (json['palette'] is List)
          for (final e in json['palette'] as List)
            if (e is Map<String, dynamic>) LedColor.fromJson(e),
      ],
    );
  }

  // ── Equality ────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DeviceState &&
        other.isOn == isOn &&
        other.color == color &&
        other.secondaryColor == secondaryColor &&
        other.effectType == effectType &&
        other.brightness == brightness &&
        other.speed == speed &&
        other.direction == direction &&
        other.intensity == intensity &&
        _samePalette(other.palette, palette);
  }

  static bool _samePalette(List<LedColor> a, List<LedColor> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        isOn,
        color,
        secondaryColor,
        effectType,
        brightness,
        speed,
        direction,
        intensity,
        Object.hashAll(palette),
      );

  @override
  String toString() =>
      'DeviceState(on: $isOn, color: $color, effect: $effectType, '
      'brightness: $brightness, speed: $speed, dir: $direction, '
      'intensity: $intensity)';
}
