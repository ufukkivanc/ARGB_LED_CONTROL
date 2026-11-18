import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:argb_controller/models/device_state.dart';
import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/led_color.dart';
import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/models/scene.dart';
import 'package:argb_controller/state/app_state.dart';
import 'package:argb_controller/state/connection_controller.dart';

/// Seçili kanalın arayüz durumunu yöneten notifier.
///
/// - Simülasyon modu: değişiklikler yalnızca yerel state'i günceller.
/// - Cihaz modu: yerel state iyimser (optimistic) güncellenir ve değişen alanlar
///   [onSend] ile (throttle'lı) ESP32'ye gönderilir; cihazdan gelen state
///   [applyRemote] ile uzlaştırılır (cihaz kazanır).
///
/// Mimari garanti: renk güncellemesi yalnızca renk alanını değiştirir; efekt,
/// hız, parlaklık ve güç durumu etkilenmez.
class DeviceNotifier extends StateNotifier<DeviceState> {
  DeviceNotifier({
    this.onSend,
    DeviceState? initial,
  }) : super(
          initial ??
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

  /// Cihaz modunda alan değişikliklerini göndermek için (null = simülasyon).
  void Function(Map<String, dynamic> fields)? onSend;

  /// false dönerse kullanıcı değişikliği yok sayılır (cihaz modunda hiçbir kanal seçili değil).
  bool Function()? canApply;

  /// [touched]: kullanıcının dokunduğu alanlar. Gösterilen (referans) kanalda değer aynı olsa bile diğer seçili
  /// kanallara gidebilmesi için açıkça gönderilir; zaten aynı olan kanalları bağlantı katmanı kanal başına eler.
  void _update(DeviceState next, List<String> touched) {
    if (canApply != null && !canApply!()) return;
    final fields = deviceStateDiffToFields(state, next);
    if (touched.isNotEmpty && onSend != null) {
      final all = deviceStateToFields(next);
      for (final k in touched) {
        fields.putIfAbsent(k, () => all[k]);
      }
    }
    if (next != state) state = next;
    if (fields.isNotEmpty) onSend?.call(fields);
  }

  /// Cihazdan gelen durumu uygular (geri gönderim yapmaz).
  void applyRemote(DeviceState remote) {
    if (remote != state) state = remote;
  }

  void togglePower() => _update(state.copyWith(isOn: !state.isOn), const ['power']);

  void setPower(bool isOn) => _update(state.copyWith(isOn: isOn), const ['power']);

  /// Yalnızca birincil rengi günceller (efekti değiştirmez).
  void setColor(LedColor color) => _update(state.copyWith(color: color), const ['color']);

  /// İkincil rengi günceller (colorFade, gradient vb.).
  void setSecondaryColor(LedColor color) =>
      _update(state.copyWith(secondaryColor: color), const ['color2']);

  /// Kanal paletini (0..5 renk) değiştirir. Boş liste paleti temizler. Efekt/animasyon fazı etkilenmez.
  void setPalette(List<LedColor> palette) =>
      _update(state.copyWith(palette: List.unmodifiable(palette.take(kMaxPaletteColors))), const ['palette']);

  void setEffect(EffectType effectType) =>
      _update(state.copyWith(effectType: effectType), const ['effect']);

  /// Parlaklık 0..255.
  void setBrightness(int brightness) =>
      _update(state.copyWith(brightness: brightness.clamp(0, 255)), const ['brightness']);

  /// Hız 1..100 (1 = yavaş, 100 = hızlı; bkz. docs/PROTOCOL.md §3.5).
  void setSpeed(int speed) => _update(state.copyWith(speed: speed.clamp(1, 100)), const ['speed']);

  /// Yoğunluk 0..100.
  void setIntensity(int intensity) =>
      _update(state.copyWith(intensity: intensity.clamp(0, 100)), const ['intensity']);

  void setDirection(int direction) =>
      _update(state.copyWith(direction: direction >= 0 ? 1 : -1), const ['direction']);

  /// Hazır sahneyi tek atomik güncelleme olarak uygular.
  void applyScene(Scene scene) {
    _update(state.copyWith(
      isOn: true,
      color: scene.primaryColor,
      secondaryColor: scene.secondaryColor,
      effectType: scene.effectType,
      brightness: scene.brightness,
      speed: scene.speed,
      direction: scene.direction,
      intensity: scene.intensity,
    ), const ['power', 'color', 'color2', 'effect', 'brightness', 'speed', 'direction', 'intensity']);
  }
}

/// Global Riverpod provider for the LED Controller device state.
final deviceProvider = StateNotifierProvider<DeviceNotifier, DeviceState>((ref) {
  final notifier = DeviceNotifier();

  void wireSender() {
    final mode = ref.read(appModeProvider);
    if (mode == AppMode.device) {
      // Değişen alan yalnızca SEÇİLİ kanallara gider; seçim boşsa hiçbir şey gönderilmez (yerel durum da değişmez).
      notifier.canApply = () => !ref.read(channelSelectionProvider).isEmpty;
      notifier.onSend = (fields) {
        final chs = ref.read(channelSelectionProvider).sortedChannels;
        if (chs.isEmpty) return;
        ref.read(connectionProvider.notifier).sendSetMulti(chs, fields);
      };
    } else {
      notifier.canApply = null;
      notifier.onSend = null;
    }
  }

  void syncFromDevice() {
    if (ref.read(appModeProvider) != AppMode.device) return;
    final conn = ref.read(connectionProvider);
    final refCh = ref.read(referenceChannelProvider);
    final ch = refCh == null ? null : conn.channels[refCh];
    if (ch != null) notifier.applyRemote(ch.toDeviceState());
  }

  wireSender();
  ref.listen<AppMode>(appModeProvider, (_, __) {
    wireSender();
    syncFromDevice();
  });
  ref.listen<DeviceConnection>(connectionProvider, (_, __) => syncFromDevice());
  ref.listen<int?>(referenceChannelProvider, (_, __) => syncFromDevice());

  return notifier;
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
