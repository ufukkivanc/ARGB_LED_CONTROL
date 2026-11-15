import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/led_color.dart';
import 'package:argb_controller/models/protocol.dart' show speedToPeriodMs;
import 'package:argb_controller/theme/app_colors.dart';

/// A realistic simulated WS2812B addressable RGB LED strip.
///
/// Features realistic SMD-5050 LED packages, copper pads, PCB silkscreen,
/// ambient reflection glow, and real-time animation drivers for all effects.
class LedStripPreview extends StatefulWidget {
  final bool isOn;
  final LedColor color;
  final EffectType effectType;
  final int brightness; // 0..255
  final int speed; // 1..100
  final int pixelCount;

  const LedStripPreview({
    super.key,
    required this.isOn,
    required this.color,
    required this.effectType,
    required this.brightness,
    required this.speed,
    this.pixelCount = 20,
  });

  @override
  State<LedStripPreview> createState() => LedStripPreviewState();
}

class LedStripPreviewState extends State<LedStripPreview>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: _calculateDuration(widget.speed),
    )..repeat();
  }

  /// Testler için: çalışan animasyonun mevcut periyodu.
  @visibleForTesting
  Duration? get period => _animController.duration;

  @visibleForTesting
  double get debugProgress => _animController.value;

  @override
  void didUpdateWidget(covariant LedStripPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.speed != widget.speed) {
      // KÖK NEDEN DÜZELTMESİ: Çalışan bir `repeat()` animasyonunda yalnızca
      // `duration` değiştirmek zamanlamayı güncellemez (simülasyon eski süreyle
      // devam eder). Yeni periyotla yeniden `repeat(period:)` çağırmak, mevcut
      // fazı koruyarak hızı hemen değiştirir.
      final d = _calculateDuration(widget.speed);
      _animController.duration = d;
      _animController.repeat(period: d);
    }
  }

  // Hız 1 (yavaş) -> 5000 ms, 100 (hızlı) -> 500 ms; firmware ile aynı formül.
  Duration _calculateDuration(int speed) => Duration(milliseconds: speedToPeriodMs(speed));

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Color _getPixelColor(int index, double progress) {
    if (!widget.isOn || widget.brightness <= 0) {
      return const Color(0xFF151822);
    }

    final effectiveBrightness = (widget.brightness / 255.0).clamp(0.0, 1.0);
    final baseColor = widget.color.toColor();

    switch (widget.effectType) {
      case EffectType.staticColor:
        return _applyBrightness(baseColor, effectiveBrightness);

      case EffectType.rainbow:
      case EffectType.rainbowCycle:
        final hue = (progress * 360 + (index * (360 / widget.pixelCount))) % 360;
        final hsvColor = HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor();
        return _applyBrightness(hsvColor, effectiveBrightness);

      case EffectType.breathing:
      case EffectType.pulsing:
        // Sine wave breathing curve
        final breathe = (math.sin(progress * 2 * math.pi) + 1.0) / 2.0;
        final minDim = 0.12;
        final factor = minDim + (1.0 - minDim) * breathe;
        return _applyBrightness(baseColor, effectiveBrightness * factor);

      case EffectType.colorFade:
        final blend = (math.sin(progress * 2 * math.pi) + 1.0) / 2.0;
        final hsv = HSVColor.fromColor(baseColor);
        final altColor = hsv.withHue((hsv.hue + 90) % 360).toColor();
        final fadedColor = Color.lerp(baseColor, altColor, blend) ?? baseColor;
        return _applyBrightness(fadedColor, effectiveBrightness);

      case EffectType.colorWipe:
        final activeLed = (progress * widget.pixelCount).floor() % widget.pixelCount;
        if (index <= activeLed) {
          return _applyBrightness(baseColor, effectiveBrightness);
        } else {
          return const Color(0xFF181B26);
        }

      case EffectType.runningLights:
      case EffectType.theaterChase:
        final head = (progress * widget.pixelCount).floor() % widget.pixelCount;
        final dist = (index - head).abs();
        final factor = (dist == 0) ? 1.0 : (dist == 1 ? 0.4 : 0.08);
        return _applyBrightness(baseColor, effectiveBrightness * factor);

      case EffectType.meteorRain:
        final head = (progress * widget.pixelCount).floor() % widget.pixelCount;
        final tailDist = (head - index + widget.pixelCount) % widget.pixelCount;
        if (tailDist == 0) {
          return _applyBrightness(Colors.white, effectiveBrightness);
        } else if (tailDist < 5) {
          final fade = 1.0 - (tailDist / 5.0);
          return _applyBrightness(baseColor, effectiveBrightness * fade);
        } else {
          return const Color(0xFF141724);
        }

      case EffectType.comet:
        final head = (progress * widget.pixelCount).floor() % widget.pixelCount;
        final tailDist = (head - index + widget.pixelCount) % widget.pixelCount;
        if (tailDist == 0) {
          return _applyBrightness(Colors.white, effectiveBrightness);
        } else if (tailDist < 7) {
          final fade = 1.0 - (tailDist / 7.0);
          return _applyBrightness(baseColor, effectiveBrightness * fade);
        } else {
          return const Color(0xFF141724);
        }

      case EffectType.customGradient:
        final hsv = HSVColor.fromColor(baseColor);
        final pixelHue = (hsv.hue + (index * (60.0 / widget.pixelCount))) % 360;
        final col = HSVColor.fromAHSV(1.0, pixelHue, hsv.saturation, hsv.value).toColor();
        return _applyBrightness(col, effectiveBrightness);

      case EffectType.randomTransitions:
        final blend = (math.sin(progress * 2 * math.pi + (index * 0.4)) + 1.0) / 2.0;
        final hsv = HSVColor.fromColor(baseColor);
        final altColor = hsv.withHue((hsv.hue + 80) % 360).toColor();
        final blended = Color.lerp(baseColor, altColor, blend) ?? baseColor;
        return _applyBrightness(blended, effectiveBrightness);

      case EffectType.fire:
        final seed = (index * 37 + (progress * 50).floor()) % 100;
        final fireHue = 10.0 + (seed / 100.0) * 35.0; // Red to yellow
        final fireBright = 0.5 + 0.5 * (seed / 100.0);
        final fireColor = HSVColor.fromAHSV(1.0, fireHue, 1.0, fireBright).toColor();
        return _applyBrightness(fireColor, effectiveBrightness);

      case EffectType.policeLights:
        final isFirstHalf = index < widget.pixelCount / 2;
        final step = (progress * 4).floor() % 2;
        if (isFirstHalf) {
          return step == 0
              ? _applyBrightness(Colors.redAccent, effectiveBrightness)
              : const Color(0xFF1C1318);
        } else {
          return step == 1
              ? _applyBrightness(Colors.blueAccent, effectiveBrightness)
              : const Color(0xFF131824);
        }

      case EffectType.twinkle:
      case EffectType.sparkle:
        final isLit = ((index * 13 + (progress * 20).floor()) % 5) == 0;
        return isLit
            ? _applyBrightness(baseColor, effectiveBrightness)
            : const Color(0xFF161926);

      case EffectType.wave:
      case EffectType.gradientMove:
        final waveVal = (math.sin(progress * 2 * math.pi + (index * 0.5)) + 1) / 2;
        return _applyBrightness(baseColor, effectiveBrightness * (0.2 + 0.8 * waveVal));

      case EffectType.musicReactive:
        final bar = (math.sin(progress * 4 * math.pi + (index * 0.3)).abs());
        final hue = (160 + index * 6) % 360;
        final col = HSVColor.fromAHSV(1.0, hue.toDouble(), 0.9, 1.0).toColor();
        return _applyBrightness(col, effectiveBrightness * (0.15 + 0.85 * bar));
    }
  }

  Color _applyBrightness(Color color, double factor) {
    if (factor <= 0) return const Color(0xFF151822);
    final r = (color.r * 255 * factor).round().clamp(0, 255);
    final g = (color.g * 255 * factor).round().clamp(0, 255);
    final b = (color.b * 255 * factor).round().clamp(0, 255);
    return Color.fromARGB(255, r, g, b);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animController,
      builder: (context, _) {
        final progress = _animController.value;

        // Calculate average strip color for ambient backlight glow
        final centerSampleColor = _getPixelColor(widget.pixelCount ~/ 2, progress);

        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF121420),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
              width: 1,
            ),
            boxShadow: [
              if (widget.isOn && widget.brightness > 20)
                BoxShadow(
                  color: centerSampleColor.withValues(
                    alpha: (widget.brightness / 255.0 * 0.35).clamp(0.0, 0.4),
                  ),
                  blurRadius: 28,
                  spreadRadius: 2,
                  offset: const Offset(0, 6),
                ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header Status ───────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.isOn ? AppColors.success : AppColors.textHint,
                          boxShadow: widget.isOn
                              ? [
                                  BoxShadow(
                                    color: AppColors.success.withValues(alpha: 0.6),
                                    blurRadius: 6,
                                  )
                                ]
                              : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'CANLI ŞERİT SİMÜLATÖRÜ',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              letterSpacing: 1.2,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceLight,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      widget.isOn
                          ? (widget.effectType == EffectType.staticColor
                              ? 'Sabit Renk'
                              : widget.effectType.name)
                          : 'Kapalı',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // ── PCB LED Strip Body ───────────────────────────────────
              Container(
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFF0D0F18),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFF282D3D),
                    width: 1.5,
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List.generate(widget.pixelCount, (i) {
                    final pixelColor = _getPixelColor(i, progress);
                    final isGlowing = widget.isOn && widget.brightness > 10;

                    return _buildSmd5050Led(pixelColor, isGlowing);
                  }),
                ),
              ),
              const SizedBox(height: 10),

              // ── PCB Details / Silkscreen ─────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '+5V  [ ▶ ]  DIN  [ ▶ ]  GND',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: Color(0xFF555B70),
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Text(
                    '${widget.pixelCount} LED / WS2812B',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textHint,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSmd5050Led(Color color, bool isGlowing) {
    return Container(
      width: 14,
      height: 28,
      margin: const EdgeInsets.symmetric(horizontal: 1.5),
      decoration: BoxDecoration(
        color: const Color(0xFF1E212D),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: const Color(0xFF383E54),
          width: 0.8,
        ),
      ),
      child: Center(
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: isGlowing
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.8),
                      blurRadius: 8,
                      spreadRadius: 1.5,
                    ),
                  ]
                : null,
          ),
        ),
      ),
    );
  }
}
