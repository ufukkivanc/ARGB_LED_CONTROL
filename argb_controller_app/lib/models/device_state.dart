import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/led_color.dart';

/// Full runtime state of the LED controller device.
///
/// This is the mutable snapshot sent to / received from the ESP32.
class DeviceState {
  final bool isOn;
  final LedColor color;
  final EffectType effectType;
  final int brightness;
  final int speed;
  final int direction;
  final int intensity;

  const DeviceState({
    required this.isOn,
    required this.color,
    required this.effectType,
    required this.brightness,
    required this.speed,
    required this.direction,
    required this.intensity,
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
    EffectType? effectType,
    int? brightness,
    int? speed,
    int? direction,
    int? intensity,
  }) {
    return DeviceState(
      isOn: isOn ?? this.isOn,
      color: color ?? this.color,
      effectType: effectType ?? this.effectType,
      brightness: brightness ?? this.brightness,
      speed: speed ?? this.speed,
      direction: direction ?? this.direction,
      intensity: intensity ?? this.intensity,
    );
  }

  // ── Serialization ───────────────────────────────────────────────────

  Map<String, dynamic> toJson() {
    return {
      'isOn': isOn,
      'color': color.toJson(),
      'effectType': effectType.index,
      'brightness': brightness,
      'speed': speed,
      'direction': direction,
      'intensity': intensity,
    };
  }

  factory DeviceState.fromJson(Map<String, dynamic> json) {
    return DeviceState(
      isOn: json['isOn'] as bool? ?? false,
      color: json['color'] != null
          ? LedColor.fromJson(json['color'] as Map<String, dynamic>)
          : const LedColor(r: 255, g: 180, b: 107),
      effectType:
          EffectType.values[(json['effectType'] as num?)?.toInt() ?? 0],
      brightness: (json['brightness'] as num?)?.toInt() ?? 200,
      speed: (json['speed'] as num?)?.toInt() ?? 50,
      direction: (json['direction'] as num?)?.toInt() ?? 1,
      intensity: (json['intensity'] as num?)?.toInt() ?? 50,
    );
  }

  // ── Equality ────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DeviceState &&
        other.isOn == isOn &&
        other.color == color &&
        other.effectType == effectType &&
        other.brightness == brightness &&
        other.speed == speed &&
        other.direction == direction &&
        other.intensity == intensity;
  }

  @override
  int get hashCode => Object.hash(
        isOn,
        color,
        effectType,
        brightness,
        speed,
        direction,
        intensity,
      );

  @override
  String toString() =>
      'DeviceState(on: $isOn, color: $color, effect: $effectType, '
      'brightness: $brightness, speed: $speed, dir: $direction, '
      'intensity: $intensity)';
}
