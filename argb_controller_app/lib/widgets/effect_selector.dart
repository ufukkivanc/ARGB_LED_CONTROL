import 'package:flutter/material.dart';
import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/effect_capabilities.dart';
import 'package:argb_controller/theme/app_colors.dart';

/// Interactive selector for LED lighting effects with icons, descriptions,
/// and animation speed controls.
class EffectSelector extends StatelessWidget {
  final EffectType selectedType;
  final ValueChanged<EffectType> onEffectSelected;
  final int speed;
  final ValueChanged<int> onSpeedChanged;
  final int intensity;
  final ValueChanged<int>? onIntensityChanged;

  /// Cihazın desteklediği efekt adları (null = hepsi). Desteklenmeyenler soluk gösterilir.
  final Set<String>? supportedEffects;

  const EffectSelector({
    super.key,
    required this.selectedType,
    required this.onEffectSelected,
    required this.speed,
    required this.onSpeedChanged,
    this.intensity = 50,
    this.onIntensityChanged,
    this.supportedEffects,
  });

  Widget _noteCard(String text) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 16, color: AppColors.textHint),
            const SizedBox(width: 8),
            Text(text, style: const TextStyle(fontSize: 12, color: AppColors.textHint)),
          ],
        ),
      );

  Widget _sliderCard({
    required IconData icon,
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
    required double min,
  }) {
    return Builder(builder: (context) {
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 18, color: AppColors.secondary),
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                Text(
                  '$value%',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.secondary,
                  ),
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 5,
                activeTrackColor: AppColors.secondary,
                inactiveTrackColor: AppColors.surfaceLight,
                thumbColor: Colors.white,
                overlayColor: AppColors.secondary.withValues(alpha: 0.2),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              ),
              child: Slider(
                value: value.toDouble().clamp(min, 100.0),
                min: min,
                max: 100,
                onChanged: (val) => onChanged(val.round()),
              ),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final effects = Effect.builtInEffects;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Hız / Yoğunluk (yalnızca bu efektin kullandığı parametreler) ──
        if (effectCaps(selectedType).speed)
          _sliderCard(
            icon: Icons.speed_rounded,
            label: 'EFEKT HIZI',
            value: speed,
            onChanged: onSpeedChanged,
            min: 1,
          )
        else
          _noteCard('Bu efekt hızdan etkilenmez.'),
        if (effectCaps(selectedType).intensity && onIntensityChanged != null)
          _sliderCard(
            icon: Icons.tune_rounded,
            label: effectIntensityLabel(selectedType),
            value: intensity,
            onChanged: onIntensityChanged!,
            min: 0,
          ),

        // ── Effects Grid ───────────────────────────────────────────────
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: effects.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2.2,
          ),
          itemBuilder: (context, index) {
            final effect = effects[index];
            final isSelected = effect.type == selectedType;

            return InkWell(
              onTap: () {
                final ok = supportedEffects == null || supportedEffects!.contains(effect.type.name);
                if (!ok) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Bu efekt cihaz yazılımında henüz desteklenmiyor.')),
                  );
                  return;
                }
                onEffectSelected(effect.type);
              },
              borderRadius: BorderRadius.circular(14),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppColors.primary.withValues(alpha: 0.2)
                      : AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isSelected
                        ? AppColors.primary
                        : Colors.white.withValues(alpha: 0.06),
                    width: isSelected ? 1.8 : 1,
                  ),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.3),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          )
                        ]
                      : null,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.surfaceLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        effect.icon,
                        size: 20,
                        color: isSelected ? Colors.white : AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            effect.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.w600,
                              color: isSelected
                                  ? Colors.white
                                  : AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            effect.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
        ),
      ],
    );
  }
}
