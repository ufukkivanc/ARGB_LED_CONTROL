/// Çoklu kanal seçimi (v0.3.2) — SAF mantık, Flutter'a bağlı değildir.
///
/// Aynı kurallar iPhone web panelinde de uygulanır (firmware/src/wled/control_page.h, `SEL` nesnesi);
/// kurallar docs/PROTOCOL.md §3.8'de tanımlıdır. İkisini birlikte değiştirin.
///
/// Kurallar:
///  1. Seçilebilir kanallar = etkin kanallar (LED sayısı > 0). Kapalı kanal işaretlenemez.
///  2. İlk durum geldiğinde TÜM etkin kanallar seçilir. Sonradan etkinleşen kanal seçime kendiliğinden EKLENMEZ.
///  3. Kapanan kanal seçimden çıkarılır.
///  4. Hiçbir kanal seçili olmayabilir: bu durumda HİÇBİR kanal komutu (renk, efekt, parlaklık...) gönderilmez.
///  5. Kontroller "referans kanalı"nın değerlerini gösterir: seçili en küçük numaralı kanal
///     (seçim boşsa ilk etkin kanal — yalnızca gösterim için).
///  6. Bir kontrol değiştiğinde yalnızca DEĞİŞEN alan tüm seçili kanallara gönderilir; seçimin kendisi cihaza
///     hiçbir şey göndermez (animasyonlar sıfırlanmaz).
class ChannelSelection {
  /// Seçili kanallar (1..4).
  final Set<int> selected;

  /// İlk durum işlendi mi (kural 2).
  final bool initialized;

  const ChannelSelection({this.selected = const {}, this.initialized = false});

  bool isSelected(int ch) => selected.contains(ch);
  bool get isEmpty => selected.isEmpty;

  /// Gönderim sırası için sıralı liste.
  List<int> get sortedChannels => (selected.toList()..sort());

  /// Cihazdaki etkin kanallarla uzlaştırır (kural 1–3).
  ChannelSelection reconcile(Set<int> enabled) {
    if (enabled.isEmpty && !initialized) return this; // henüz durum yok
    if (!initialized) {
      return ChannelSelection(selected: Set.unmodifiable(enabled), initialized: true);
    }
    final next = selected.where(enabled.contains).toSet();
    if (next.length == selected.length) return this;
    return ChannelSelection(selected: Set.unmodifiable(next), initialized: true);
  }

  /// Kanalı işaretler/kaldırır. Kapalı kanal değişmez (kural 1). Son seçim de kaldırılabilir (kural 4).
  ChannelSelection toggle(int ch, Set<int> enabled) {
    if (!enabled.contains(ch)) return this;
    final next = Set<int>.from(selected);
    if (!next.remove(ch)) next.add(ch);
    return ChannelSelection(selected: Set.unmodifiable(next), initialized: true);
  }

  ChannelSelection selectAll(Set<int> enabled) =>
      ChannelSelection(selected: Set.unmodifiable(enabled), initialized: true);

  ChannelSelection clear() => const ChannelSelection(selected: {}, initialized: true);

  /// Kural 5: gösterim için referans kanal (yoksa null).
  int? referenceChannel(Set<int> enabled) {
    if (selected.isNotEmpty) return selected.reduce((a, b) => a < b ? a : b);
    if (enabled.isEmpty) return null;
    return enabled.reduce((a, b) => a < b ? a : b);
  }

  @override
  bool operator ==(Object other) =>
      other is ChannelSelection &&
      other.initialized == initialized &&
      other.selected.length == selected.length &&
      other.selected.containsAll(selected);

  @override
  int get hashCode => Object.hash(initialized, Object.hashAllUnordered(selected));

  @override
  String toString() => 'ChannelSelection($sortedChannels, init=$initialized)';
}
