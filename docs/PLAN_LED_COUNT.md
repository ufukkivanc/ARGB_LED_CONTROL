# Plan: LED sayısı ayarı (ayrı geliştirme)

> **Durum: UYGULANDI (v0.3, gerçek donanımda henüz doğrulanmadı).** Ayrıntılar `docs/PROTOCOL.md` §3.7 ve `docs/WLED_COMPAT.md` §9. Windows: Cihaz ayarları ▸ LED sayısı; iPhone paneli: Ayarlar kartı. Aşağıdaki metin özgün plandır.
> Efektler bu çalışmanın kapsamı dışındadır (daha sonra sadeleştirilecek).

## Mevcut durum (kodda doğrulanan)

| Yer | Davranış |
|---|---|
| Firmware | Kanal başına `ledCount` NVS'te. `setChannelConfig` (WS/HTTP komutu) `ledCount` (0–512), toplam ≤ 1024 kabul eder; değişiklik **yeniden başlatma gerektirir** (`rebootRequired`, `state.channels[].pendingConfig`). Varsayılan CH1 = 10. |
| Flutter (Windows) | LED sayısını değiştiren **arayüz yok**. Kontrol panelindeki "60 LED Aktif" yazısı simülasyon varsayılanından gelir (`DeviceConfig.ledCount = 60`); şerit önizlemesi sabit 20 pikseldir (`LedStripPreview.pixelCount`). Gerçek cihazın sayısı `info.channelConfigs[].ledCount` içinde gelir ama gösterilmez. |
| iPhone/WLED paneli | `info.leds.count` ve segment `len` gerçek değeri gösterir; ayar yok. |

## Hedef

Kullanıcı, uygulamadan her kanal için LED sayısını (ve kanalı etkinleştir/devre dışı bırak) görebilsin ve değiştirebilsin; önizleme ve etiketler gerçek sayıyı yansıtsın.

## Kapsam

1. **Gerçek sayının gösterilmesi:** `DeviceInfo.channelConfigs` → panelde "N LED" etiketi ve önizleme piksel sayısı (üst sınır ör. 60 piksel çizilir, gerisi "+N" ile belirtilir).
2. **Ayar arayüzü (cihaz ayarları ekranı):** kanal başına sayı girişi (0–512, toplam ≤ 1024; doğrulama ve mesajlar firmware hata kodlarıyla: `invalid_value`, `led_budget_exceeded`), kanal etkinleştirme anahtarı, renk sırası (GRB/RGB).
3. **Yeniden başlatma akışı:** değişiklik `rebootRequired` dönerse "Cihaz yeniden başlatılsın mı?" → `POST /api/reboot`; yeniden başlatma sonrası otomatik yeniden bağlanma ve doğrulama. Bekleyen (`pendingConfig`) değer ekranda "yeniden başlatınca geçerli" olarak gösterilir.
4. **Simülasyon modu:** simülasyonda yerel (kalıcı olmayan) LED sayısı seçimi; "60 LED" sabiti kaldırılır.
5. **Güvenlik ve güç:** büyük sayılarda `maxBrightness` / akım uyarısı (5 V besleme); yazma yalnızca token ile (mevcut `/api/command`/WS yolu). WLED yolundan LED sayısı **yazılamaz** (mevcut kural korunur).

## Teknik tasarım notları

- Protokol değişikliği gerekmez: `setChannelConfig` ve `pendingConfig` hazır. Flutter tarafında `DeviceApi`/`DeviceConnectionController` için `setChannelConfig(ch, {ledCount, enabled, colorOrder})` eklenir.
- `ChannelState.ledCount` zaten state mesajında gelir; `DeviceConnection.info.channels` ile birleştirilir.
- FastLED denetleyicileri çalışırken kaldırılamadığı için canlı yeniden boyutlandırma **yok**; yeniden başlatma modeli korunur (belge: PROTOCOL.md §3.2, §8.4).

## Testler

- Flutter: sahte ESP32 ile ayar akışı (geçerli/geçersiz değer, bütçe aşımı, `rebootRequired`, reboot sonrası doğrulama); önizleme piksel sayısı; widget taşma testleri (550×750, 420×560).
- Firmware: mevcut host testleri (`wled_map` toplam LED/segment ofsetleri) genişletilir; sınır değerleri.
- Gerçek donanım: 10 → 30 → 60 LED değişimi, yeniden başlatma sonrası kalıcılık, toplam sınırı hata mesajı.

## Riskler

- Yüksek LED sayısında 60 FPS ve RMT/FastLED zamanlaması ölçülmedi (PROTOCOL.md §15).
- Yanlış sayı (gerçek şeritten fazla) görsel bir sorun üretmez ama güç/ısı hesabını yanıltır → uyarı metni.
- Tek LED / çok LED efekt dalları (n<3) mevcut; yeni sayılarda efektlerin görünümü gerçek şeritte gözden geçirilmeli (efektlerin sadeleştirilmesiyle birlikte).

## Kabul ölçütleri

- Cihaz ayarlarından CH1 LED sayısı 10 → 30 yapılır, uygulama yeniden başlatmayı önerir/yapar, yeniden bağlanınca panelde ve iPhone WLED panelinde 30 LED görünür.
- Geçersiz/aşırı değerler anlaşılır Türkçe hata verir; hiçbir durumda veri bozulması olmaz.
- Mevcut REST/WS/WLED davranışı ve testler değişmeden geçer.
