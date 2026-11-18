# Changelog

Biçim: [Keep a Changelog](https://keepachangelog.com/). Sürümler: uygulama `pubspec.yaml` (`x.y.z+n`), firmware `FIRMWARE_VERSION`; ikisi aynı numarayı taşır.

## [0.3.2] — 2026-11-18

### Eklendi
- **Çoklu kanal seçimi (Windows uygulaması + iPhone paneli):** CH1–CH4 için checkbox; birden çok kanal aynı anda seçilebilir, seçili
  kanallar vurgulanır, "Tümü"/"Hiçbiri". Renk çarkı, hazır renkler, 2. renk, palet, efekt, hız, yoğunluk, yön, parlaklık ve güç yalnızca
  seçili kanallara uygulanır; seçilmeyen kanalların rengi/efekti/ayarları değişmez. Hiçbir kanal seçili değilse komut gönderilmez.
  İki arayüz aynı kurallara uyar (docs/PROTOCOL.md §3.8). Seçimin kendisi cihaza komut göndermez (animasyonlar sıfırlanmaz).
- Windows: aynı alan/değere sahip kanallar tek `set` mesajında (`ch:[..]`) birleştirilir; rengi zaten aynı olan kanala komut gitmez.

### Değişti
- **Sabit GPIO eşlemesi:** CH1 → GPIO18, CH2 → GPIO19, **CH3 → GPIO22, CH4 → GPIO23** (önceden CH3=21, CH4=22). Tüm kanal pinleri
  tek merkezden: `firmware/include/config.h` → `LED_CHANNEL_HW` (pin değiştirmek için başka dosya düzenlenmez). Derleme zamanı
  `static_assert` ile rezerve/yalnızca-giriş/flash pin ve çakışma denetimi. NVS'teki eski pin değeri yok sayılır. Arayüzlerde GPIO
  numarası gösterilmez, GPIO ayarı yoktur. **CH3/CH4 kablolarını yeni pinlere taşıyın.**
- **Windows ↔ iPhone eşitliği:** Windows uygulamasına "Ters yön" anahtarı eklendi (iPhone'da vardı); iPhone hazır renkleri Windows'takiyle
  aynı 11 renk ve sıraya getirildi (test denetler).
- iPhone paneli güç ve parlaklığı üst düzey `on`/`bri` yerine seçili segmentlere gönderir (önceden tüm kanallar seçiliyken parlaklık
  kanallar arasında orantılı ölçekleniyordu; artık Windows ile aynı: seçili kanallara aynı değer).
- iPhone paneli: kanal kartı tek kanal etkinken de görünür; LED sayısı satırları "CH1…CH4" olarak adlandırıldı.
- `run_host_tests.bat`: Visual Studio Build Tools 2026 yolu da aranır.

### Korunan
- Protokol sürümü 1 (değişiklik yok), efekt motoru, kanal bağımsızlığı, NVS kayıt düzeni, REST/WebSocket senkronu, eşleştirme ve WLED erişim modları.

## [0.3.1] — 2026-11-18

### Düzeltildi
- **USB/SoftAP kurulumunda Wi-Fi taraması `scan_busy` ile başarısız oluyordu.** Kök neden: Arduino-ESP32 2.0.17 çekirdeğinin varsayılan
  otomatik yeniden bağlanması, kayıtlı ağ bulunamayınca (`Reason: 201 - NO_AP_FOUND`) her ~2,9 sn'de bir kendiliğinden `WiFi.begin()` çağırıyordu.
  Bu döngü `WiFiManager` 3 denemeden sonra SoftAP'ye düştükten sonra da sonsuza dek sürüyordu (cihazda 37 dk çalışma süresinde doğrulandı).
  Sürücü bağlantı denemesi sürerken kullanıcı taramasını `ESP_ERR_WIFI_STATE` ile reddettiğinden `WiFi.scanNetworks()` hep `WIFI_SCAN_FAILED`
  döndü ve seri kurulum `scan_busy` yanıtladı; aynı döngü SoftAP'nin kanalını da sürekli oynatıyordu.
- Çekirdeğin otomatik yeniden bağlanması kapatıldı (`setAutoReconnect(false)`, `persistent(false)`); tüm STA denemelerini `WiFiManager`
  yönetir: 3 deneme, aralarında 3 sn boş radyo, `NO_AP_FOUND`/`AUTH_FAIL` olayında 15 sn beklemeden hızlı sonuç. Başarısız döngü sonunda
  SoftAP açılır ve durum `failed` kalır (önceden AP yeni açıldıysa `ap` görünüp seri istemci başarısızlığı kaçırabiliyordu).
- Tarama tek sahipli durum makinesi oldu: süren STA denemesi tarama için duraklatılır ve sonra deneme hakkı harcanmadan sürer;
  başarısız/zaman aşımlı tarama otomatik yeniden denenir (en çok 3, `esp_wifi_scan_stop` ile temizlenerek); HTTP ve seri istekler aynı
  taramaya katılır, sonuçlar iki tüketici arasında kaybolmaz (eskiden ilk okuyan sonucu siliyordu).
- Art arda tarama istekleri yeni radyo taraması başlatmaz (`scanStarted` + `joined:true`, tek `scanResult`).
- Tarama bitişi sürücünün `SCAN_DONE` olayına (ve olaydaki durum koduna) göre belirlenir. Arduino `scanComplete()` taramadan
  20 × `max_ms_per_chan` (= 6 sn) sonra sürücü hâlâ tararken `WIFI_SCAN_FAILED` döndürür; SoftAP+STA modunda gerçek tarama ≈ 9 sn
  sürdüğünden bu erken sonuç her taramayı kesiyordu. Artık yalnızca loglanır; `esp_wifi_scan_stop()` sadece 12 sn'lik bekçide çağrılır.
- Seri loglar: tarama başlangıcı (deneme, mod, STA durumu), bitişi (süre, durum kodu, sürücü/listelenen ağ sayısı), başarısız deneme, bekçi.

### Eklendi
- SoftAP'ye düşüldükten sonra kayıtlı ağ arka planda 120 sn'de bir tek denemeyle sınanır (modem yeniden başladığında kendiliğinden döner);
  SoftAP istemcisi, açık kurulum penceresi veya tarama varken yapılmaz.
- Seri hata kodu `scan_failed`; `GET /api/wifi/scan` yanıtında eklemeli `error:"scan_failed"`.
- Windows uygulaması: USB kurulumunda geçici tarama hatalarında (`scan_busy`, `scan_failed`, `scan_timeout`, yanıt yok) 2 otomatik
  yeniden deneme ve ilerleme metni; tarama sürerken düğmeler devre dışı, ikinci istek cihaza gönderilmez; tarama zaman aşımı 50 sn (HTTP sihirbazı 55 sn).
  SoftAP/HTTP kurulum sihirbazı `scan_failed`'da bir kez otomatik yeniden tarar.
- `firmware/test_host/wifi_scan_device_test.py`: gerçek kartta seri tarama senaryoları (BOOT onayı gerekir).

### Doğrulama durumu
- Gerçek ESP32'de (COM7, SoftAP+STA): ilk tarama, art arda 3 istek (tek radyo taraması), sonuçtan hemen sonra tarama, STA denemesi sürerken
  tarama (duraklatma, deneme sayılmadı), `not_found` sonrası tarama — 24/24 geçti; 5 taramanın 5'i `SCAN_DONE` ile ≈ 9,1 sn'de bitti,
  başarısız deneme/bekçi 0; AP'deyken 257 sn boyunca `Reason: 201` yok. NVS'teki LED ayarları flaş sonrası korundu.
- Ayrıca: Flutter testleri (146; 8'i yeni), firmware derlemesi (WLED'li ve WLED'siz).
- **Doğrulanmadı (Windows derleme makinesinde yapılacak):** gerçek bir ağa bağlanma, STA bağlıyken tarama, yerel ağda keşif/yeniden
  eşleştirme ve REST/WebSocket/LED kontrolü (betik hazır: `firmware/test_host/wifi_scan_device_test.py COM7 --connect --lan --sta-scan`);
  Windows uygulaması arayüzünden USB tarama/kurulum; v0.3.1 Windows derlemesi ve kurulum paketi; açılışta kayıtlı-ama-ulaşılamayan ağ
  (test sırasında kayıtlı bilgi silinmişti, eşdeğeri `not_found` sonrası tarama ile sınandı). MSVC host testleri bu sürümde çalıştırılmadı
  (değişmeyen `wled_map`/`palette_fx` kodunu kapsar).

### Uyumluluk
- REST/WS/seri protokol sürümü 1 (yalnızca eklemeli). Yeni uygulama eski firmware'in `scan_busy`'sini yeniden dener; eski uygulama yeni
  firmware ile çalışır. NVS anahtarları değişmedi; LED efektleri, paletler, LED sayıları, token/BOOT güvenliği ve WLED katmanına dokunulmadı.

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
