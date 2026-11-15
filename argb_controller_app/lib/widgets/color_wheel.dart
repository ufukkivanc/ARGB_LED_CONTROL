import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:argb_controller/models/led_color.dart';

/// An interactive circular HSV Color Wheel with smooth drag/tap selection
/// and a row of quick preset color swatches.
class ColorWheel extends StatefulWidget {
  final LedColor color;
  final ValueChanged<LedColor> onColorChanged;
  final double size;

  const ColorWheel({
    super.key,
    required this.color,
    required this.onColorChanged,
    this.size = 250,
  });

  @override
  State<ColorWheel> createState() => _ColorWheelState();
}

class _ColorWheelState extends State<ColorWheel> {
  late double _hue; // 0..360
  late double _saturation; // 0..1

  @override
  void initState() {
    super.initState();
    _updateFromColor(widget.color);
  }

  @override
  void didUpdateWidget(covariant ColorWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color != widget.color) {
      _updateFromColor(widget.color);
    }
  }

  void _updateFromColor(LedColor color) {
    final hsv = color.toHSV();
    _hue = hsv.hue;
    _saturation = hsv.saturation;
  }

  void _handleTouch(Offset localPosition, double radius) {
    final center = Offset(radius, radius);
    final dx = localPosition.dx - center.dx;
    final dy = localPosition.dy - center.dy;

    final distance = math.sqrt(dx * dx + dy * dy);
    final clampedDistance = distance.clamp(0.0, radius);

    // Calculate angle in radians and convert to degrees (0..360)
    var angle = math.atan2(dy, dx);
    var hue = (angle * 180 / math.pi);
    if (hue < 0) hue += 360;

    final saturation = (clampedDistance / radius).clamp(0.0, 1.0);

    setState(() {
      _hue = hue;
      _saturation = saturation;
    });

    final newColor = LedColor.fromHSV(
      _hue,
      _saturation,
      1.0,
      brightness: widget.color.brightness,
    );
    widget.onColorChanged(newColor);
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.size / 2;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Interactive Wheel ──────────────────────────────────────────
        Center(
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (details) => _handleTouch(details.localPosition, radius),
              onPanUpdate: (details) => _handleTouch(details.localPosition, radius),
              onTapDown: (details) => _handleTouch(details.localPosition, radius),
              child: CustomPaint(
                size: Size(widget.size, widget.size),
                painter: _ColorWheelPainter(
                  hue: _hue,
                  saturation: _saturation,
                  currentColor: widget.color.toColor(),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),

        // ── Preset Color Swatches ──────────────────────────────────────
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildPresetChip(LedColor.red, 'Kırmızı'),
              _buildPresetChip(LedColor.orange, 'Turuncu'),
              _buildPresetChip(LedColor.amber, 'Amber'),
              _buildPresetChip(LedColor.yellow, 'Sarı'),
              _buildPresetChip(LedColor.green, 'Yeşil'),
              _buildPresetChip(LedColor.cyan, 'Camgöbeği'),
              _buildPresetChip(LedColor.blue, 'Mavi'),
              _buildPresetChip(LedColor.purple, 'Mor'),
              _buildPresetChip(LedColor.pink, 'Pembe'),
              _buildPresetChip(LedColor.warmWhite, 'Sıcak Beyaz'),
              _buildPresetChip(LedColor.coolWhite, 'Soğuk Beyaz'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPresetChip(LedColor preset, String label) {
    final isSelected = widget.color.r == preset.r &&
        widget.color.g == preset.g &&
        widget.color.b == preset.b;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: () {
            final newColor = preset.copyWith(brightness: widget.color.brightness);
            _updateFromColor(newColor);
            widget.onColorChanged(newColor);
          },
          borderRadius: BorderRadius.circular(20),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: preset.toColor(),
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.2),
                width: isSelected ? 3 : 1.5,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: preset.toColor().withValues(alpha: 0.6),
                        blurRadius: 10,
                        spreadRadius: 2,
                      )
                    ]
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      )
                    ],
            ),
            child: isSelected
                ? Icon(
                    Icons.check,
                    size: 18,
                    color: preset.brightness > 128 &&
                            (preset.r * 0.299 + preset.g * 0.587 + preset.b * 0.114) > 160
                        ? Colors.black
                        : Colors.white,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class _ColorWheelPainter extends CustomPainter {
  final double hue;
  final double saturation;
  final Color currentColor;

  _ColorWheelPainter({
    required this.hue,
    required this.saturation,
    required this.currentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // 1. Draw outer ambient glow
    final glowPaint = Paint()
      ..color = currentColor.withValues(alpha: 0.15)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);
    canvas.drawCircle(center, radius + 4, glowPaint);

    // 2. Draw Color Wheel (SweepGradient of all hues)
    final sweepGradient = const SweepGradient(
      colors: [
        Color(0xFFFF0000), // Red 0°
        Color(0xFFFFFF00), // Yellow 60°
        Color(0xFF00FF00), // Green 120°
        Color(0xFF00FFFF), // Cyan 180°
        Color(0xFF0000FF), // Blue 240°
        Color(0xFFFF00FF), // Magenta 300°
        Color(0xFFFF0000), // Red 360°
      ],
    );

    final wheelPaint = Paint()
      ..shader = sweepGradient.createShader(
        Rect.fromCircle(center: center, radius: radius),
      )
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, radius, wheelPaint);

    // 3. Draw Radial White Gradient for saturation from center to edge
    final saturationGradient = RadialGradient(
      colors: [
        Colors.white,
        Colors.white.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 1.0],
    );

    final satPaint = Paint()
      ..shader = saturationGradient.createShader(
        Rect.fromCircle(center: center, radius: radius),
      )
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, radius, satPaint);

    // 4. Subtle inner dark border
    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, radius, borderPaint);

    // 5. Thumb Indicator calculation
    final thumbAngle = hue * math.pi / 180;
    final thumbDist = saturation * radius;
    final thumbPos = Offset(
      center.dx + thumbDist * math.cos(thumbAngle),
      center.dy + thumbDist * math.sin(thumbAngle),
    );

    // Thumb shadow
    canvas.drawCircle(
      thumbPos,
      14,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // Thumb outer white ring
    canvas.drawCircle(
      thumbPos,
      13,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0,
    );

    // Thumb inner color fill
    canvas.drawCircle(
      thumbPos,
      10,
      Paint()
        ..color = currentColor
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _ColorWheelPainter oldDelegate) {
    return oldDelegate.hue != hue ||
        oldDelegate.saturation != saturation ||
        oldDelegate.currentColor != currentColor;
  }
}
