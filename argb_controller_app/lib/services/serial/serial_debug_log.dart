/// Seri haberleşme hata ayıklama günlüğü.
///
/// GİZLİLİK: Wi-Fi şifresi ve SSID asla yazılmaz. Tüm satırlar [redact] ile süzülür:
///  - `{"cmd":"wifi",...}` komutu tamamen maskelenir,
///  - `ssid`/`pass`/`password` alanları maskelenir,
///  - tarama sonuçları (çevredeki ağ adları) yalnızca sayı olarak özetlenir,
///  - cihazın "Password:" log satırı (kurulum AP şifresi) maskelenir.
class SerialDebugLog {
  SerialDebugLog({this.maxLines = 150, this.onChanged});

  final int maxLines;
  final void Function()? onChanged;
  final List<String> _lines = [];

  List<String> get lines => List.unmodifiable(_lines);

  void add(String direction, String raw) {
    final line = '$direction ${redact(raw)}';
    _lines.add(line);
    if (_lines.length > maxLines) _lines.removeRange(0, _lines.length - maxLines);
    // Yalnızca debug derlemelerde (assert açıkken) konsola da yaz; satır zaten maskelidir.
    assert(() {
      // ignore: avoid_print
      print('[usb-serial] $line');
      return true;
    }());
    onChanged?.call();
  }

  void note(String text) => add('··', text);

  void clear() {
    _lines.clear();
    onChanged?.call();
  }

  static final _ssidRe = RegExp(r'"ssid"\s*:\s*"(?:[^"\\]|\\.)*"');
  static final _passRe = RegExp(r'"(?:pass|password)"\s*:\s*"(?:[^"\\]|\\.)*"');

  static String redact(String raw) {
    var s = raw.trim();
    if (s.length > 200) s = '${s.substring(0, 200)}…';
    if (s.contains('"cmd":"wifi"') || s.contains('"cmd": "wifi"')) {
      return '{"cmd":"wifi","ssid":"<gizli>","pass":"<gizli>"}';
    }
    if (s.contains('"type":"scanResult"')) {
      final n = RegExp(r'"ssid"').allMatches(raw).length;
      return '{"type":"scanResult", $n ağ (adlar günlüğe yazılmaz)}';
    }
    if (RegExp(r'Password\s*:', caseSensitive: false).hasMatch(s)) {
      return '[cihaz günlüğü: şifre satırı gizlendi]';
    }
    s = s.replaceAllMapped(_ssidRe, (_) => '"ssid":"<gizli>"');
    s = s.replaceAllMapped(_passRe, (_) => '"pass":"<gizli>"');
    return s;
  }
}
