# Changelog

Biçim: [Keep a Changelog](https://keepachangelog.com/). Sürümler: uygulama `pubspec.yaml` (`x.y.z+n`), firmware `FIRMWARE_VERSION`; ikisi aynı numarayı taşır.

## [0.3.0] — 2026-11-18

### Eklendi
- **Çok renkli palet (kanal başına 1–5 renk):** Windows uygulamasında (Renk sekmesi) ve iPhone/WLED web panelinde renk ekleme, gerçek renk çarkıyla değiştirme, silme, sıralama, temizleme.
  Palet boşsa 20 efektin tamamı eski davranışıyla çalışır; doluysa efektler yalnızca palet renklerini kullanır (efekt başına davranış: `docs/PROTOCOL.md` §3.7).
  Palet değişimi/efekt değişimi animasyonu durdurmaz. Paletler ESP32 NVS'inde kalıcıdır; REST (`palette`), WebSocket ve WLED (`apal`, `pal`) üzerinden Windows ↔ iPhone senkron çalışır.
- **Kanal başına LED sayısı:** CH1–CH4 için ayrı sayı (0–512, toplam ≤ 1024). Windows: *Cihaz ayarları ▸ LED sayısı*, iPhone: *Ayarlar* kartı (Wi-Fi bağlantısıyla aynı yerde).
  Değişiklik **yeniden başlatmadan** uygulanır (FastLED `setLeds`), küçülürken eski LED'ler söndürülür; NVS'te kalıcı; mevcut kayıtlı sayılar otomatik değiştirilmez.
  "4 × 1 m, 30 LED/m" hazır dolumu yalnızca alanları doldurur (kullanıcı *Uygula*'ya basar). Yüksek sayılarda (>300/kanal, >600 toplam) yalnızca kare hızı uyarısı.
- **Kare süresi telemetrisi:** `info.perf` (`fps`, `renderUs`, `showUs`) ve WLED `info.leds.fps` ölçülen değeri verir.
- iPhone panelinde renk çarkı işaretçisi yeniden yazıldı: yüzde konumlu, parmağı anlık izler, başka istemciden gelen/sayfa açılışındaki renge göre konumlanır.
- Windows panelinde "N LED Aktif" yazısı cihazdaki gerçek kanal LED sayısını gösterir.

### Düzeltildi
- iPhone panelinde "Efekt listesi alınamadı": ESPAsyncWebServer `/json` kaydını `/json/*` önekiyle de eşliyordu; `/json/eff`, `/json/pal`, `/json/nodes` tam `/json` nesnesi döndürüyordu. Rota sırası düzeltildi; panel yanıtı doğrular ve `/json/eff` → `/json` → `/json/si` yedeğiyle yeniden dener.
- WLED uygulamasında ~5 sn'de bir Offline/Online: token'sız WLED WebSocket istemcileri "auth timeout" ile kapatılıyordu. Muafiyet yalnızca WLED politikası açık, WLED işaretli ve tarayıcı kaynaklı olmayan istemciler için; Flutter token doğrulaması ve 5 sn zaman aşımı aynen korunur.
- Dar pencerelerde renk ön ayar satırı artık kırpılmıyor (satır kırar).

### Değişti
- Windows masaüstü arayüzü responsive: 420–650 px kompakt tek sütun, 650–950 px çiftler/geniş kartlar, ≥ 950 px iki sütunlu dashboard; efekt/sahne ızgaraları genişliğe göre sütun sayısı değiştirir (v0.2.0 çalışması).
- Windows: ≈ 550×750 başlangıç penceresi, en az 420×560, Inno Setup tek dosya kurulum paketi, uygulama kimliği/sürüm bilgisi (v0.2.0 çalışması).
- `GET /` yanıtındaki `info`'ya `argb` uzantısı, `/json/pal` ikinci palet (`Custom Palette`), `palcount` = 2.

### Güvenlik / uyumluluk
- Yeni tokensiz yazma uç noktası yok. LED sayısı/palet yazımı mevcut WLED `control` modu yetki sınıfındadır (BOOT onaylı açılır); `{"argb":{"reboot":true}}` yalnızca bekleyen yapılandırma varsa yeniden başlatır, WLED `rb` anahtarı hâlâ yok sayılır.
- NVS geriye dönük uyumlu: palet ayrı `pal` blob anahtarındadır, eski sürümde yoksa palet boş sayılır; bozuk blob yok sayılır. REST/WS protokol sürümü 1 (eklemeli); eski Flutter v0.2.0 yeni firmware ile, yeni uygulama eski firmware ile çalışır (palet düzenleyici devre dışı kalır).

### Doğrulama durumu
- Gerçek ESP32'de (CH1'e bağlı 10 LED): palet × 20 efekt × LED sayıları (10/30/50/150 ve karışık, 4 × 30), canlı yeniden boyutlandırma, NVS'ten geri yükleme, WLED WebSocket kararlılığı doğrulandı (`firmware/test_host/palette_device_test.py`, `ws_soak_test.py`).
- **Doğrulanmadı:** CH2–CH4'e fiziksel LED bağlı değildi (çıkış görsel olarak izlenmedi); >300 LED/kanal kare süresi yük altında ölçülmedi; iPhone Safari/WLED WebView'da yeni palet ve işaretçi; Android/iOS Flutter derlemeleri; kod imzalı kurulum paketi.

## [0.2.0] — 2026-11-17
- Windows masaüstü paketleme ve kompakt pencere, responsive düzen (bkz. 0.3.0 "Değişti"), kurulum paketi, sürüm bilgisi.

## [0.1.0]
- İlk çalışan sürüm: ESP32 firmware (4 kanal, 20 efekt, token korumalı REST/WS, Wi-Fi kurulumu), Flutter uygulaması, WLED uyumluluk katmanı ve iPhone kontrol paneli. Bilinen sorun: iPhone panelinde efekt listesi (0.3.0'da düzeltildi).
