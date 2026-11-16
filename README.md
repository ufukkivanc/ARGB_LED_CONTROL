# ESP32 Smart ARGB LED Controller

**EN:** ESP32-based smart addressable-LED (WS2812B) controller with 4 independent channels, 20 effects, a token-secured REST/WebSocket API,
a Flutter control app (Windows desktop / Android / iOS / Web), Wi-Fi provisioning (web page, USB serial, app wizard) and an optional
**WLED-compatibility layer** so the official WLED iPhone/Android app can discover and control it.
Docs are mostly Turkish; code identifiers and commit messages are English.

**TR:** ESP32 tabanlı, 4 bağımsız kanallı, 20 efektli akıllı ARGB LED denetleyici. Token korumalı REST/WebSocket API, Flutter kontrol uygulaması,
üç farklı Wi-Fi kurulum yolu ve resmi WLED mobil uygulamasıyla uyumluluk katmanı içerir.

## Özellikler

| Alan | Durum |
|---|---|
| **LED kontrolü** | 4 bağımsız kanal (GPIO 18/19/21/22), WS2812B; 20 efekt (hız, yoğunluk, 2 renk, yön); kanal başına durum NVS'te (debounce'lu yazım) |
| **API** | HTTP + WebSocket (`/ws`), JSON protokolü, **token tabanlı eşleştirme** (fiziksel BOOT düğmesiyle 120 sn'lik pencere), hız sınırlama, komut kuyruğu (core 0 → core 1 tek yazar) |
| **Wi-Fi kurulumu** | (1) ESP32 SoftAP + telefon tarayıcısında **`/setup`** sayfası, (2) **USB seri** kurulum (Windows Flutter uygulaması), (3) Flutter kurulum sihirbazı (SoftAP → BOOT eşleştirme → ağ seçimi). Hepsi BOOT yetkilendirme penceresine bağlıdır; Wi-Fi şifresi loglanmaz |
| **Flutter uygulaması** | Cihaz keşfi (mDNS + elle IP), eşleştirme, 4 kanal, renk çarkı, efektler, simülasyon modu; Windows masaüstü, Android, iOS, Web (geliştirme) |
| **WLED uyumluluğu** | `/json/*`, WebSocket, mDNS `_wled._tcp`; erişim modu **varsayılan kapalı** (`off` / `readonly` / `control`); derleme anahtarıyla tamamen çıkarılabilir |
| **Telefon kontrol paneli** | `http://<ip>/` adresinde gömülü, harici bağımlılıksız mobil arayüz (güç, parlaklık, renk çarkı, 20 efekt, hız/yoğunluk, kanal seçimi, cihaz durumu); WLED uygulamasının ayrıntı ekranında da açılır |

> **Doğrulama durumu (bakımcı bildirimi):** Windows Flutter uygulamasından LED kontrolü, iPhone WLED uygulamasında cihaz keşfi, kontrol panelinin açılması
> ve panelden LED kontrolü gerçek donanımda çalışıyor. Android/iOS Flutter uygulaması derlenip cihazda **denenmedi**. Ayrıntılar aşağıda.

## Depo yapısı

```
firmware/                 PlatformIO (Arduino, ESP32-WROOM-32)
  src/api/                HTTP+WS sunucusu, JSON, komut kuyruğu, anlık görüntü, /setup sayfası
  src/auth/               token üretimi/doğrulama (SHA-256 özetleri NVS'te), eşleştirme penceresi
  src/led/                FastLED motoru, 20 efekt, kanal yönetimi
  src/network/            Wi-Fi durum makinesi, mDNS
  src/hw/                 BOOT düğmesi + LED, USB seri kurulum
  src/wled/               WLED uyumluluk katmanı + gömülü kontrol paneli (ENABLE_WLED_COMPAT)
  test_host/              ESP32 gerektirmeyen testler (C++ eşleme testleri, tarayıcı arayüz testi)
argb_controller_app/      Flutter uygulaması (lib/, test/, windows/, android/, ios/, web/)
docs/                     PROTOCOL.md (API sözleşmesi), WLED_COMPAT.md, issues/
```

## Derleme ve yükleme

```powershell
# Firmware (PlatformIO)
pio run -d firmware                                         # WLED uyumluluğu DAHİL
pio run -d firmware -e esp32dev_nowled                      # WLED uyumluluğu olmadan
pio run -d firmware -t upload --upload-port COM3            # ESP32'ye yükle (seri monitör kapalı olmalı)

# Flutter uygulaması
cd argb_controller_app
flutter pub get
flutter run -d windows        # veya: -d chrome (geliştirme), Android/iOS cihaz
```

Windows masaüstü derlemesi için Visual Studio "Desktop development with C++" ve Windows'ta Geliştirici Modu (sembolik bağlantı) gerekir.
Proje yolunda ASCII olmayan karakter (ör. `Ç`) bazı araçlarda (shader derleyicisi, ESP linker harita dosyası) hata verebilir.

## İlk kurulum

1. ESP32'yi yükleyin. Kayıtlı Wi-Fi yoksa SoftAP (`ESP32-ARGB-Setup-XXXX`) açılır; **AP şifresi ilk prototipte yalnızca seri porttan** (115200 baud) görünür.
2. Üç yoldan biriyle Wi-Fi'ı tanıtın: telefonda `http://192.168.4.1/setup` · Windows uygulamasında **USB ile Wi-Fi kur** · uygulamadaki kurulum sihirbazı.
   Hepsi için önce kart üzerindeki **BOOT** düğmesine 3 sn basılı tutup bırakın (fiziksel yetkilendirme, 120 sn).
3. Uygulamayla eşleştirmek için yine BOOT'a 3 sn basın; token yalnızca bir kez döner ve cihazda yalnızca SHA-256 özeti saklanır.

## Güvenlik özeti

- Token'sız yalnızca `GET /api/discover`, eşleştirme (BOOT penceresi) ve fiziksel olarak yetkilendirilmiş kurulum uç noktaları vardır. Token ve Wi-Fi şifresi loglanmaz.
- **TLS yok:** trafik yerel ağda düz HTTP/WS'tir; eşleştirme sırasında aynı ağdaki biri token'ı görebilir. Güvenilmeyen ağlarda kullanmayın.
- **WLED uyumluluğu bir istisnadır:** WLED uygulaması token gönderemez. Varsayılan `off`; `readonly`/`control` modlarında aynı yerel ağdaki herkes tokensiz okuyabilir/(control'de) LED'leri değiştirebilir.
  Mod yalnızca token ile değiştirilir, `control` ek olarak fiziksel BOOT onayı ister. OTA/ayar/Wi-Fi uç noktaları WLED yolundan erişilemez.
  Tam model ve riskler: [`docs/WLED_COMPAT.md`](docs/WLED_COMPAT.md).
- Bu depoda parola, token veya anahtar yoktur; `*.jks`, `*.keystore`, `.env`, `*.pem` gibi dosyalar `.gitignore` ile dışarıda tutulur.

## Testler

```powershell
cd argb_controller_app; flutter analyze; flutter test                  # birim/widget/sözleşme testleri (sahte ESP32 ile)
firmware\test_host\run_host_tests.bat                                  # WLED eşleme katmanı C++ testleri (MSVC)
python firmware\test_host\browser_ui_test.py <çıktı_klasörü>           # kontrol panelinin gerçek tarayıcıda (iPhone görünümü) testi
$env:ESP32_COM_PORT="COM3"; flutter test test/hardware/real_esp32_test.dart   # GERÇEK donanım testi (varsayılan atlanır)
```

Gerçek ESP32'de elle doğrulanması gerekenler `docs/WLED_COMPAT.md` §7'de listelenmiştir.

## Bilinen sınırlamalar ve hatalar

- **iPhone kontrol panelinde efekt listesi yüklenmiyor** (bilinen hata, sonraki sürümde düzeltilecek) — bkz. [`docs/issues/effect-list-not-loading.md`](docs/issues/effect-list-not-loading.md).
- WLED'in kendi web arayüzünün özellikleri (palet, preset, segment düzenleme, ayarlar) yok; efekt numaraları WLED'inkinden farklıdır (`/json/eff` adlarına güvenin).
- `musicReactive` efekti ses dinlemez (mikrofon yok): BPM'e bağlı simülasyondur.
- USB seri kurulum yalnızca Windows masaüstünde; kurulum ağına (SoftAP) otomatik bağlanma yok, kullanıcı sistem Wi-Fi ayarlarından bağlanır.
- 512 LED/kanal ve 1024 toplam LED sınırları performans garantisi değildir; yüksek LED sayılarında 60 FPS ölçülmedi.
- Flutter Web: tarayıcıda mDNS ve güvenli kalıcı token saklama yoktur (token varsayılan olarak yalnızca bellekte).
- Android/iOS Flutter uygulaması için platform izinleri yapılandırıldı ancak bu platformlarda derleme/cihaz testi yapılmadı.
- Flutter 3.50 SDK ile `scene.dart` içindeki iki `non_const_argument_for_const_parameter` uyarısı ve `material.dart` kullanımına dair deprecation bilgileri bekliyor.
