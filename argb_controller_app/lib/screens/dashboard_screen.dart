import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/led_color.dart';
import 'package:argb_controller/models/scene.dart';
import 'package:argb_controller/providers/device_provider.dart';
import 'package:argb_controller/theme/app_colors.dart';
import 'package:argb_controller/widgets/brightness_slider.dart';
import 'package:argb_controller/widgets/color_wheel.dart';
import 'package:argb_controller/widgets/effect_selector.dart';
import 'package:argb_controller/widgets/led_strip_preview.dart';

/// The primary control dashboard for the ESP32 Smart ARGB LED Controller.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  int _selectedTabIndex = 0; // 0: Color, 1: Effects, 2: Scenes

  void _togglePower() {
    ref.read(deviceProvider.notifier).togglePower();
  }

  void _updateColor(LedColor newColor) {
    // CRITICAL: Updates ONLY the color parameter.
    // The active animation effect is NOT stopped or changed to staticColor.
    ref.read(deviceProvider.notifier).setColor(newColor);
  }

  void _updateBrightness(int brightness) {
    ref.read(deviceProvider.notifier).setBrightness(brightness);
  }

  void _updateEffect(EffectType effectType) {
    ref.read(deviceProvider.notifier).setEffect(effectType);
  }

  void _updateSpeed(int speed) {
    ref.read(deviceProvider.notifier).setSpeed(speed);
  }

  void _applyScene(Scene scene) {
    ref.read(deviceProvider.notifier).applyScene(scene);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Sahne uygulandı: ${scene.name}'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  String _getEffectName(EffectType type) {
    if (type == EffectType.staticColor) return 'Sabit Renk';
    final match = Effect.builtInEffects.where((e) => e.type == type);
    if (match.isNotEmpty) return match.first.name;
    return type.name;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(deviceProvider);
    final currentColor = state.color.toColor();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Column(
          children: [
            Text(
              'ESP32 ARGB CONTROLLER',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.wifi, size: 12, color: AppColors.success),
                SizedBox(width: 4),
                Text(
                  'ESP32-ARGB (Simülasyon Modu)',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Yenile',
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Cihaz durumu güncellendi (Simülasyon)'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                // ── 1. Power & Status Card ─────────────────────────────
                _buildPowerCard(state, currentColor),
                const SizedBox(height: 16),

                // ── 2. Live Simulated LED Strip ────────────────────────
                LedStripPreview(
                  isOn: state.isOn,
                  color: state.color,
                  effectType: state.effectType,
                  brightness: state.brightness,
                  speed: state.speed,
                  pixelCount: 20,
                ),
                const SizedBox(height: 16),

                // ── 3. Color Swatch & Realtime Info Preview ─────────────
                _buildColorInfoCard(state, currentColor),
                const SizedBox(height: 16),

                // ── 4. Brightness Slider ───────────────────────────────
                BrightnessSlider(
                  brightness: state.brightness,
                  onBrightnessChanged: _updateBrightness,
                  activeColor: state.isOn ? currentColor : AppColors.textHint,
                ),
                const SizedBox(height: 20),

                // ── 5. Navigation Tab Switcher ──────────────────────────
                _buildTabSwitcher(),
                const SizedBox(height: 16),

                // ── 6. Tab Content ─────────────────────────────────────
                if (_selectedTabIndex == 0) ...[
                  // Active effect reminder banner when in color tab
                  if (state.effectType != EffectType.staticColor)
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceLight,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.auto_awesome, size: 16, color: AppColors.secondary),
                              const SizedBox(width: 8),
                              Text(
                                'Aktif Efekt: ${_getEffectName(state.effectType)}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                          TextButton(
                            onPressed: () => _updateEffect(EffectType.staticColor),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text(
                              'Sabit Renk Yap',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: AppColors.secondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Color Wheel View
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.06),
                        width: 1,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                    child: ColorWheel(
                      color: state.color,
                      onColorChanged: _updateColor,
                      size: 240,
                    ),
                  ),
                ] else if (_selectedTabIndex == 1) ...[
                  // Effects View
                  EffectSelector(
                    selectedType: state.effectType,
                    onEffectSelected: _updateEffect,
                    speed: state.speed,
                    onSpeedChanged: _updateSpeed,
                  ),
                ] else ...[
                  // Scenes View
                  _buildScenesGrid(),
                ],

                const SizedBox(height: 20),

                // ── 7. Hardware Telemetry Card ─────────────────────────
                _buildTelemetryCard(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPowerCard(dynamic state, Color currentColor) {
    final isOn = state.isOn as bool;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isOn
              ? currentColor.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.06),
          width: 1.5,
        ),
        boxShadow: [
          if (isOn)
            BoxShadow(
              color: currentColor.withValues(alpha: 0.15),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          // Power Button with Glow Ring
          InkWell(
            onTap: _togglePower,
            borderRadius: BorderRadius.circular(30),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOn ? currentColor : AppColors.surfaceLight,
                boxShadow: isOn
                    ? [
                        BoxShadow(
                          color: currentColor.withValues(alpha: 0.7),
                          blurRadius: 16,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
                border: Border.all(
                  color: isOn ? Colors.white : AppColors.textHint,
                  width: 2,
                ),
              ),
              child: Icon(
                Icons.power_settings_new_rounded,
                size: 28,
                color: isOn ? Colors.white : AppColors.textHint,
              ),
            ),
          ),
          const SizedBox(width: 16),

          // Device status description
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      isOn ? 'GÜÇ AÇIK' : 'GÜÇ KAPALI',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        color: isOn ? Colors.white : AppColors.textHint,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isOn ? AppColors.success : AppColors.error,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  isOn
                      ? '60 LED Aktif • Parlaklık: ${((state.brightness / 255.0) * 100).round()}%'
                      : 'Şerit bekleme modunda',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),

          // Active Mode Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _getEffectName(state.effectType as EffectType),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isOn ? AppColors.primaryLight : AppColors.textHint,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColorInfoCard(dynamic state, Color currentColor) {
    final hexCode = (state.color as LedColor).toHex();
    final hsv = (state.color as LedColor).toHSV();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Color circle swatch
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: currentColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: currentColor.withValues(alpha: 0.5),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),

          // Color Details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hexCode,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'RGB(${state.color.r}, ${state.color.g}, ${state.color.b})  •  H:${hsv.hue.round()}° S:${(hsv.saturation * 100).round()}%',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),

          // Quick set to Warm White button
          Tooltip(
            message: 'Sıcak Beyaz Renk',
            child: IconButton(
              onPressed: () => _updateColor(LedColor.warmWhite),
              icon: const Icon(
                Icons.wb_incandescent_outlined,
                color: AppColors.warning,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabSwitcher() {
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          _buildTabItem(0, 'Renk Çarkı', Icons.color_lens_rounded),
          _buildTabItem(1, 'Efektler', Icons.auto_awesome_rounded),
          _buildTabItem(2, 'Sahneler', Icons.bookmark_rounded),
        ],
      ),
    );
  }

  Widget _buildTabItem(int index, String label, IconData icon) {
    final isSelected = _selectedTabIndex == index;

    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _selectedTabIndex = index),
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected ? AppColors.primaryLight : AppColors.textHint,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected ? Colors.white : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScenesGrid() {
    final scenes = Scene.builtInScenes;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: scenes.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 2.3,
      ),
      itemBuilder: (context, index) {
        final scene = scenes[index];
        final sceneColor = scene.primaryColor.toColor();

        return InkWell(
          onTap: () => _applyScene(scene),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.06),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: sceneColor.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: sceneColor.withValues(alpha: 0.5),
                      width: 1,
                    ),
                  ),
                  child: Icon(scene.icon, size: 20, color: sceneColor),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        scene.name,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Parlaklık: ${((scene.brightness / 255.0) * 100).round()}%',
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppColors.textHint,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTelemetryCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.04),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _TelemetryItem(label: 'Çip', value: 'ESP32-S3'),
          _TelemetryItem(label: 'LED Türü', value: 'WS2812B'),
          _TelemetryItem(label: 'Pin', value: 'GPIO 2'),
          _TelemetryItem(label: 'Gecikme', value: '12 ms'),
        ],
      ),
    );
  }
}

class _TelemetryItem extends StatelessWidget {
  final String label;
  final String value;

  const _TelemetryItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: AppColors.textHint,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
