import 'dart:ui';

/// Represents an RGB color with brightness for LED strips.
class LedColor {
  final int r;
  final int g;
  final int b;
  final int brightness;

  const LedColor({
    required this.r,
    required this.g,
    required this.b,
    this.brightness = 255,
  });

  // ── Factory constructors ────────────────────────────────────────────

  /// Creates an [LedColor] from HSV values.
  ///
  /// [hue] in degrees 0–360, [saturation] and [value] in 0.0–1.0.
  factory LedColor.fromHSV(
    double hue,
    double saturation,
    double value, {
    int brightness = 255,
  }) {
    hue = hue % 360;
    if (hue < 0) hue += 360;
    saturation = saturation.clamp(0.0, 1.0);
    value = value.clamp(0.0, 1.0);

    final double c = value * saturation;
    final double x = c * (1 - ((hue / 60) % 2 - 1).abs());
    final double m = value - c;

    double rr, gg, bb;

    if (hue < 60) {
      rr = c;
      gg = x;
      bb = 0;
    } else if (hue < 120) {
      rr = x;
      gg = c;
      bb = 0;
    } else if (hue < 180) {
      rr = 0;
      gg = c;
      bb = x;
    } else if (hue < 240) {
      rr = 0;
      gg = x;
      bb = c;
    } else if (hue < 300) {
      rr = x;
      gg = 0;
      bb = c;
    } else {
      rr = c;
      gg = 0;
      bb = x;
    }

    return LedColor(
      r: ((rr + m) * 255).round().clamp(0, 255),
      g: ((gg + m) * 255).round().clamp(0, 255),
      b: ((bb + m) * 255).round().clamp(0, 255),
      brightness: brightness.clamp(0, 255),
    );
  }

  /// Creates an [LedColor] from a 6- or 8-digit hex string.
  ///
  /// Accepts optional leading '#'. If 8 digits, the last two bytes are
  /// treated as brightness.
  factory LedColor.fromHex(String hex) {
    String cleaned = hex.replaceAll('#', '').trim();

    if (cleaned.length == 8) {
      final int rVal = int.parse(cleaned.substring(0, 2), radix: 16);
      final int gVal = int.parse(cleaned.substring(2, 4), radix: 16);
      final int bVal = int.parse(cleaned.substring(4, 6), radix: 16);
      final int brVal = int.parse(cleaned.substring(6, 8), radix: 16);
      return LedColor(r: rVal, g: gVal, b: bVal, brightness: brVal);
    }

    if (cleaned.length == 6) {
      final int rVal = int.parse(cleaned.substring(0, 2), radix: 16);
      final int gVal = int.parse(cleaned.substring(2, 4), radix: 16);
      final int bVal = int.parse(cleaned.substring(4, 6), radix: 16);
      return LedColor(r: rVal, g: gVal, b: bVal);
    }

    return const LedColor(r: 255, g: 255, b: 255);
  }

  // ── Conversion methods ──────────────────────────────────────────────

  /// Returns a 6-digit uppercase hex string prefixed with '#'.
  String toHex() {
    return '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();
  }

  /// Returns HSV representation as a record: (hue, saturation, value).
  ///
  /// Hue in 0–360, saturation and value in 0.0–1.0.
  ({double hue, double saturation, double value}) toHSV() {
    final double rn = r / 255.0;
    final double gn = g / 255.0;
    final double bn = b / 255.0;

    final double cmax = [rn, gn, bn].reduce((a, b) => a > b ? a : b);
    final double cmin = [rn, gn, bn].reduce((a, b) => a < b ? a : b);
    final double delta = cmax - cmin;

    double hue;
    if (delta == 0) {
      hue = 0;
    } else if (cmax == rn) {
      hue = 60 * (((gn - bn) / delta) % 6);
    } else if (cmax == gn) {
      hue = 60 * (((bn - rn) / delta) + 2);
    } else {
      hue = 60 * (((rn - gn) / delta) + 4);
    }
    if (hue < 0) hue += 360;

    final double saturation = cmax == 0 ? 0 : delta / cmax;
    final double value = cmax;

    return (hue: hue, saturation: saturation, value: value);
  }

  /// Converts to a Flutter [Color].
  Color toColor() {
    final double br = brightness / 255.0;
    return Color.fromARGB(
      255,
      (r * br).round().clamp(0, 255),
      (g * br).round().clamp(0, 255),
      (b * br).round().clamp(0, 255),
    );
  }

  /// Creates a new [LedColor] from a Flutter [Color].
  factory LedColor.fromColor(Color color) {
    return LedColor(
      r: (color.r * 255).round().clamp(0, 255),
      g: (color.g * 255).round().clamp(0, 255),
      b: (color.b * 255).round().clamp(0, 255),
    );
  }

  // ── copyWith ────────────────────────────────────────────────────────

  LedColor copyWith({
    int? r,
    int? g,
    int? b,
    int? brightness,
  }) {
    return LedColor(
      r: r ?? this.r,
      g: g ?? this.g,
      b: b ?? this.b,
      brightness: brightness ?? this.brightness,
    );
  }

  // ── Serialization ───────────────────────────────────────────────────

  Map<String, dynamic> toJson() {
    return {
      'r': r,
      'g': g,
      'b': b,
      'brightness': brightness,
    };
  }

  factory LedColor.fromJson(Map<String, dynamic> json) {
    return LedColor(
      r: (json['r'] as num?)?.toInt() ?? 255,
      g: (json['g'] as num?)?.toInt() ?? 255,
      b: (json['b'] as num?)?.toInt() ?? 255,
      brightness: (json['brightness'] as num?)?.toInt() ?? 255,
    );
  }

  // ── Equality ────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LedColor &&
        other.r == r &&
        other.g == g &&
        other.b == b &&
        other.brightness == brightness;
  }

  @override
  int get hashCode => Object.hash(r, g, b, brightness);

  @override
  String toString() =>
      'LedColor(r: $r, g: $g, b: $b, brightness: $brightness)';

  // ── Static presets ──────────────────────────────────────────────────

  static const LedColor warmWhite = LedColor(r: 255, g: 180, b: 107);
  static const LedColor coolWhite = LedColor(r: 200, g: 220, b: 255);
  static const LedColor red = LedColor(r: 255, g: 0, b: 0);
  static const LedColor green = LedColor(r: 0, g: 255, b: 0);
  static const LedColor blue = LedColor(r: 0, g: 0, b: 255);
  static const LedColor purple = LedColor(r: 128, g: 0, b: 255);
  static const LedColor orange = LedColor(r: 255, g: 100, b: 0);
  static const LedColor amber = LedColor(r: 255, g: 191, b: 0);
  static const LedColor pink = LedColor(r: 255, g: 20, b: 147);
  static const LedColor cyan = LedColor(r: 0, g: 255, b: 255);
  static const LedColor yellow = LedColor(r: 255, g: 255, b: 0);
}
