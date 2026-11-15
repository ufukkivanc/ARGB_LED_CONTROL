import 'package:flutter/material.dart';
import 'package:argb_controller/theme/app_colors.dart';

/// A modern brightness control with real-time percentage display,
/// smooth slider, and quick percentage preset buttons.
class BrightnessSlider extends StatelessWidget {
  final int brightness; // 0..255
  final ValueChanged<int> onBrightnessChanged;
  final Color? activeColor;

  const BrightnessSlider({
    super.key,
    required this.brightness,
    required this.onBrightnessChanged,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final percent = ((brightness / 255.0) * 100).round();
    final effectiveColor = activeColor ?? AppColors.primary;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.06),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Title & Percentage Readout ───────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    percent > 50
                        ? Icons.brightness_7_rounded
                        : (percent > 0
                            ? Icons.brightness_4_rounded
                            : Icons.brightness_2_rounded),
                    color: effectiveColor,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'PARLAKLIK',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.1,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: effectiveColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$percent%',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: effectiveColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ── Slider ───────────────────────────────────────────────────
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              activeTrackColor: effectiveColor,
              inactiveTrackColor: AppColors.surfaceLight,
              thumbColor: Colors.white,
              overlayColor: effectiveColor.withValues(alpha: 0.2),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
            ),
            child: Slider(
              value: brightness.toDouble().clamp(0.0, 255.0),
              min: 0,
              max: 255,
              onChanged: (val) {
                onBrightnessChanged(val.round());
              },
            ),
          ),
          const SizedBox(height: 6),

          // ── Quick Presets ────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildPresetButton(context, 25, (255 * 0.25).round()),
              _buildPresetButton(context, 50, (255 * 0.50).round()),
              _buildPresetButton(context, 75, (255 * 0.75).round()),
              _buildPresetButton(context, 100, 255),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPresetButton(BuildContext context, int displayPercent, int targetValue) {
    final isSelected = (brightness - targetValue).abs() < 12;

    return InkWell(
      onTap: () => onBrightnessChanged(targetValue),
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? (activeColor ?? AppColors.primary).withValues(alpha: 0.25)
              : AppColors.surfaceLight,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? (activeColor ?? AppColors.primary)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Text(
          '$displayPercent%',
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected
                ? (activeColor ?? AppColors.primary)
                : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
