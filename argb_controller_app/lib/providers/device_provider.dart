import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:argb_controller/models/device_state.dart';
import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/led_color.dart';
import 'package:argb_controller/models/scene.dart';

/// State notifier managing the ESP32 ARGB LED device state.
///
/// Architecture Guarantee:
/// Color updates modify ONLY the color parameters.
/// The active effect selection, speed, direction, brightness, and power state
/// remain completely unaffected and active.
class DeviceNotifier extends StateNotifier<DeviceState> {
  DeviceNotifier()
      : super(
          const DeviceState(
            isOn: true,
            color: LedColor(r: 108, g: 99, b: 255), // Neon Purple
            effectType: EffectType.breathing, // Active animation on launch
            brightness: 220,
            speed: 55,
            direction: 1,
            intensity: 60,
          ),
        );

  /// Toggles power ON / OFF preserving all other state parameters.
  void togglePower() {
    state = state.copyWith(isOn: !state.isOn);
  }

  /// Sets power state explicitly.
  void setPower(bool isOn) {
    state = state.copyWith(isOn: isOn);
  }

  /// Updates ONLY the primary color parameter in real time.
  ///
  /// CRITICAL:
  /// - Does NOT switch effectType to staticColor.
  /// - Preserves active animation effect, speed, brightness, and power.
  /// - Real-time updates immediately propagate to color-aware animations.
  void setColor(LedColor color) {
    state = state.copyWith(color: color);
  }

  /// Updates the active animation effect.
  ///
  /// Preserves the currently selected color, brightness, and power.
  void setEffect(EffectType effectType) {
    state = state.copyWith(effectType: effectType);
  }

  /// Updates ONLY the brightness parameter (0..255).
  ///
  /// Preserves the active animation, colors, speed, and power.
  void setBrightness(int brightness) {
    state = state.copyWith(brightness: brightness.clamp(0, 255));
  }

  /// Updates ONLY the animation speed parameter (1..100).
  void setSpeed(int speed) {
    state = state.copyWith(speed: speed.clamp(1, 100));
  }

  /// Applies a preset lighting scene.
  void applyScene(Scene scene) {
    state = state.copyWith(
      isOn: true,
      color: scene.primaryColor,
      effectType: scene.effectType,
      brightness: scene.brightness,
      speed: scene.speed,
      direction: scene.direction,
      intensity: scene.intensity,
    );
  }
}

/// Global Riverpod provider for the LED Controller device state.
final deviceProvider = StateNotifierProvider<DeviceNotifier, DeviceState>((ref) {
  return DeviceNotifier();
});

/// Granular selector for device power state.
final isPowerOnProvider = Provider<bool>((ref) {
  return ref.watch(deviceProvider).isOn;
});

/// Granular selector for active primary color.
final activeColorProvider = Provider<LedColor>((ref) {
  return ref.watch(deviceProvider).color;
});

/// Granular selector for active animation effect.
final activeEffectProvider = Provider<EffectType>((ref) {
  return ref.watch(deviceProvider).effectType;
});

/// Granular selector for brightness.
final activeBrightnessProvider = Provider<int>((ref) {
  return ref.watch(deviceProvider).brightness;
});

/// Granular selector for animation speed.
final activeSpeedProvider = Provider<int>((ref) {
  return ref.watch(deviceProvider).speed;
});
