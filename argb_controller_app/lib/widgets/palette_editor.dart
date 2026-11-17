import 'package:flutter/material.dart';
import 'package:argb_controller/models/led_color.dart';
import 'package:argb_controller/models/protocol.dart' show kMaxPaletteColors;
import 'package:argb_controller/theme/app_colors.dart';
import 'package:argb_controller/widgets/color_wheel.dart';

/// Kanal başına çok renkli palet (1–5 renk) düzenleyicisi.
///
/// - Renk ekle (+), seç, gerçek renk çarkıyla değiştir, sola/sağa sırala, sil, tümünü temizle.
/// - Palet boşsa efektler kendi varsayılan renk davranışını korur; doluysa yalnızca palet renklerini kullanır.
/// - Mevcut bileşenleri yeniden kullanır ([ColorWheel]); kart stili renk çarkı kartıyla aynıdır.
class PaletteEditor extends StatefulWidget {
  const PaletteEditor({
    super.key,
    required this.palette,
    required this.onChanged,
    required this.baseColor,
    this.wheelSize = 200,
    this.enabled = true,
    this.maxColors = kMaxPaletteColors,
  });

  final List<LedColor> palette;
  final ValueChanged<List<LedColor>> onChanged;

  /// "+" ile eklenen yeni rengin başlangıç değeri (seçili renk yoksa).
  final LedColor baseColor;
  final double wheelSize;

  /// false: cihaz yazılımı palet desteklemiyor (eski firmware).
  final bool enabled;
  final int maxColors;

  @override
  State<PaletteEditor> createState() => _PaletteEditorState();
}

class _PaletteEditorState extends State<PaletteEditor> {
  int _sel = -1;

  @override
  void didUpdateWidget(covariant PaletteEditor old) {
    super.didUpdateWidget(old);
    // Palet dışarıdan (başka istemci) küçüldüyse seçimi geçerli aralığa çek
    if (_sel >= widget.palette.length) _sel = widget.palette.length - 1;
  }

  List<LedColor> get _p => widget.palette;

  void _emit(List<LedColor> next) => widget.onChanged(List<LedColor>.unmodifiable(next));

  void _add() {
    if (_p.length >= widget.maxColors) return;
    final base = (_sel >= 0 && _sel < _p.length) ? _p[_sel] : widget.baseColor;
    final c = LedColor(r: base.r, g: base.g, b: base.b);
    setState(() => _sel = _p.length);
    _emit([..._p, c]);
  }

  void _edit(int i, LedColor c) {
    if (i < 0 || i >= _p.length) return;
    final next = [..._p];
    next[i] = LedColor(r: c.r, g: c.g, b: c.b);
    _emit(next);
  }

  void _move(int delta) {
    final j = _sel + delta;
    if (_sel < 0 || j < 0 || j >= _p.length) return;
    final next = [..._p];
    final t = next[_sel];
    next[_sel] = next[j];
    next[j] = t;
    setState(() => _sel = j);
    _emit(next);
  }

  void _delete() {
    if (_sel < 0 || _sel >= _p.length) return;
    final next = [..._p]..removeAt(_sel);
    setState(() => _sel = next.isEmpty ? -1 : (_sel >= next.length ? next.length - 1 : _sel));
    _emit(next);
  }

  void _clear() {
    setState(() => _sel = -1);
    _emit(const []);
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final hasSel = _sel >= 0 && _sel < p.length;
    final en = widget.enabled;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1),
      ),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ÇOK RENKLİ PALET',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.1,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          if (p.isNotEmpty) ...[
            Container(
              height: 10,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                gradient: LinearGradient(
                  colors: [
                    for (final c in (p.length == 1 ? [p.first, p.first] : p)) c.toColor(),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < p.length; i++)
                _swatch(i, p[i], selected: i == _sel, enabled: en),
              if (p.length < widget.maxColors)
                Tooltip(
                  message: 'Renk ekle',
                  child: InkWell(
                    key: const Key('palette_add'),
                    onTap: en ? _add : null,
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.surfaceLight,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 1.5),
                      ),
                      child: Icon(Icons.add_rounded, color: en ? AppColors.textPrimary : AppColors.textHint),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            !en
                ? 'Bu cihaz yazılımı palet desteklemiyor (firmware güncellemesi gerekir).'
                : p.isEmpty
                    ? 'Palet boş: efektler kendi renklerini kullanır. En çok ${widget.maxColors} renk ekleyebilirsiniz.'
                    : 'Palet etkin (${p.length} renk): efekt yalnızca bu renkleri kullanır.',
            style: const TextStyle(fontSize: 11, color: AppColors.textHint),
          ),
          if (en && p.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IconButton(
                  key: const Key('palette_left'),
                  tooltip: 'Sola taşı',
                  onPressed: hasSel && _sel > 0 ? () => _move(-1) : null,
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
                ),
                IconButton(
                  key: const Key('palette_right'),
                  tooltip: 'Sağa taşı',
                  onPressed: hasSel && _sel < p.length - 1 ? () => _move(1) : null,
                  icon: const Icon(Icons.arrow_forward_ios_rounded, size: 18),
                ),
                IconButton(
                  key: const Key('palette_delete'),
                  tooltip: 'Seçili rengi sil',
                  onPressed: hasSel ? _delete : null,
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
                TextButton(
                  key: const Key('palette_clear'),
                  onPressed: _clear,
                  child: const Text('Temizle'),
                ),
              ],
            ),
          ],
          if (en && hasSel) ...[
            const SizedBox(height: 8),
            ColorWheel(
              key: ValueKey('palette_wheel_$_sel'),
              color: p[_sel],
              onColorChanged: (c) => _edit(_sel, c),
              size: widget.wheelSize,
            ),
          ],
        ],
      ),
    );
  }

  Widget _swatch(int i, LedColor c, {required bool selected, required bool enabled}) {
    return Tooltip(
      message: 'Palet rengi ${i + 1}',
      child: InkWell(
        key: Key('palette_swatch_$i'),
        onTap: enabled ? () => setState(() => _sel = selected ? -1 : i) : null,
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: c.toColor(),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Colors.white : Colors.white.withValues(alpha: 0.25),
              width: selected ? 3 : 1.5,
            ),
            boxShadow: selected
                ? [BoxShadow(color: c.toColor().withValues(alpha: 0.6), blurRadius: 10, spreadRadius: 1)]
                : null,
          ),
          child: selected ? const Icon(Icons.edit_rounded, size: 18, color: Colors.white) : null,
        ),
      ),
    );
  }
}
