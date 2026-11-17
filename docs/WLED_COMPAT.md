# WLED Uyumluluk Katmanı

Amaç: WLED'in resmi iPhone/Android uygulamasının ("WLED Native", `Moustachauve/WLED-App`) bu ESP32 denetleyicisini bulması ve
temel kontrolü (aç/kapat, parlaklık, renk, efekt) yapabilmesi. **Mevcut REST/WebSocket API'si, token eşleştirmesi, Flutter uygulaması
ve USB/Web Wi-Fi kurulumu değişmedi.** Katman ayrı bir modüldür (`firmware/src/wled/`) ve derleme zamanında tamamen çıkarılabilir.

> **DURUM: Gerçek iPhone ve gerçek ESP32 ile DOĞRULANMADI.** Aşağıdaki "çalışır" ifadeleri yalnızca (1) uygulamanın açık kaynak
> kodundan çıkarılan beklentilere göre yazılmış kod, (2) ana bilgisayar birim testleri (311 doğrulama) ve (3) firmware derlemesi ile desteklenir.

## 1. Araştırma: uygulama ne bekliyor?

Kaynak: `github.com/Moustachauve/WLED-App` (resmi iOS+Android, Kotlin Multiplatform + SwiftUI). Okunan dosyalar:
`iosApp/wled/Service/DiscoveryService.swift`, `iosApp/wled/Info.plist`, `shared/.../service/api/DeviceApi.kt`,
`.../service/websocket/WebsocketClient.kt`, `.../model/wledapi/{State,Info,Segment,Leds,Wifi,JsonPost}.kt`, `iosApp/wled/View/{WebView,DeviceListItemView}.swift`.

| Konu | Bulgu |
|---|---|
| **Keşif** | Bonjour `_wled._tcp` (`NSBonjourServices`); TXT kaydındaki **`mac`** cihaz kimliği olarak alınır; IP, servise TCP bağlantısı açılarak çözülür. (Elle IP girişi de mümkün.) |
| **HTTP** | `GET /json/info` (zorunlu alanlar: `leds`, `wifi`, `name`), `POST /json/state` gövde `{"on","bri","v":true}` → yanıt `State` olarak çözülür, `POST /update` (OTA). |
| **WebSocket** | `ws://<ip>/ws`; sunucudan `{"state":{…},"info":{…}}` metin çerçeveleri bekler (bağlanınca ve değişimde); komutları da aynı soketten `State` JSON'u olarak gönderir. |
| **Arayüz** | Cihaz listesi kartında yalnızca **aç/kapa** ve **parlaklık**; kartın rengi `seg[0].col[0]`'dan. Ayrıntı ekranı `WKWebView` ile cihazın kendi **`http://<ip>/`** WLED web arayüzünü açar (renk/efekt oradan). |
| **ATS / izinler** | `NSAllowsArbitraryLoads` (düz HTTP/WS serbest), Yerel Ağ izni. |

## 2. Uygulananlar

| Uç nokta | Davranış |
|---|---|
| `GET /json/info`, `/json/state`, `/json/si`, `/json` | WLED biçiminde yanıt (`/json` = state+info+effects+palettes) |
| `GET /json/eff`, `/json/pal`, `/json/nodes` | 20 efekt adı · `["Default"]` · `{"nodes":[]}` |
| `POST /json/state`, `POST /json` | `on`, `bri`, `seg[]` (`id,on,bri,col,fx,sx,ix,rev`), `v` (tam durumlu yanıt). Yanıt: `{"success":true}` veya (`v:true`) uygulanmış durum |
| `WS /ws` (aynı yol) | WLED istemcisi bağlanınca `{"state","info"}` çerçevesi; durum değişince yayın (≥200 ms); `p`→`pong`; `{"v":true}`; komutlar. **Kendi protokolümüz** (`auth` ile başlayan, `type` alanlı mesajlar) aynen çalışır. |
| mDNS | `_wled._tcp` (+TXT `mac`), yalnızca erişim modu KAPALI değilse |
| `GET/POST /api/wled` | Erişim modu yönetimi (**token zorunlu**) |

**Bilerek YOK:** `/update` (OTA), `/settings*`, `/edit`, `cfg` yazma, Wi-Fi/ağ ayarı, preset yazma/silme, reboot (`rb`), `ota`. Bu anahtarlar gelirse yok sayılır.
`info.opt = 0` (OTA kapalı), `info.vid = 0`, `info.brand = "ESP32-ARGB"`: uygulamanın bu cihaza WLED yazılımı güncellemesi önermemesi için
(WLED ikilisini bu firmware'in üzerine yazmak cihazı bozar).

## 3. Eşleme

**Segment ↔ kanal.** WLED tek bir şeridi segmentlere böler; bu cihaz ise birbirinden bağımsız 4 fiziksel kanaldır (kendi GPIO'su, LED sayısı, durumu).
Birebir aynı değiller; kabul edilen model:

- WLED segment `id = i` ↔ fiziksel **kanal i+1**. Yalnızca **etkin** kanallar segment olarak görünür (şu an: kanal 1 → segment 0).
- `start/stop` = etkin kanalların LED sayılarının art arda dizildiği **sanal şerit** (ör. CH1=10, CH2=20 → seg0: 0–10, seg1: 10–30).
- `start/stop/len/grp/spc/of/mi/pal/n/set/frz/cct` ve segment oluşturma/silme **yazılamaz** (fiziksel kanallar yeniden dilimlenemez) → yok sayılır.
- `seg` bir nesne ise `mainseg` (0); dizide `id` yoksa dizideki konum kullanılır (WLED davranışı).

| WLED | Bu cihaz |
|---|---|
| `on` (üst düzey, bool veya `"t"`) | tüm **etkin** kanalların güç durumu; okunan: herhangi biri açıksa `true` |
| `bri` (üst düzey, 0–255) | tüm etkin kanalların parlaklığı **orantılı** ölçeklenir (oranlar korunur); okunan: en büyük kanal parlaklığı |
| `seg.on` / `seg.bri` | o kanalın gücü / parlaklığı (**mutlak**, master ile çarpılmaz) |
| `seg.col[0]` / `col[1]` | birincil / ikincil renk (`[r,g,b(,w)]` veya hex; W yok sayılır; `null` = değişmez) |
| `seg.col[2]` | karşılığı yok → yok sayılır, `[0,0,0]` olarak raporlanır |
| `seg.fx` | efekt = firmware `EffectType` indeksi (0–19). `"~"`, `"~-"`, `"r"` desteklenir |
| `seg.sx` (0–255) | hız 1–100 (`speed = round(sx·100/255)`, ≥1). Büyük = hızlı |
| `seg.ix` (0–255) | yoğunluk 0–100 |
| `seg.rev` | yön (`true` → −1) |
| `seg.pal`, `ps`, `pl`, `nl`, `udpn`, `lor`, `transition`, `ledmap` | raporlanır, **yazılamaz** (palet/preset/gece ışığı yok) |

**Efektler (fx id = indeks):** 0 Solid · 1 Rainbow · 2 Rainbow Cycle · 3 Breathe · 4 Color Fade · 5 Color Wipe · 6 Running Lights · 7 Theater Chase ·
8 Fire · 9 Meteor Rain · 10 Twinkle · 11 Sparkle · 12 Police Lights · 13 Wave · 14 Gradient Move · 15 Comet · 16 Pulse · 17 Random Colors ·
18 Gradient · 19 Music Reactive (ses girişi yok: ritim simülasyonu).
`/json/eff` bu listeyi verir; istemci adları buradan okur. **WLED'in kendi 180+ efekt numaraları farklıdır**: uygulama başka bir fx numarası (≥20) gönderirse
**değişiklik yapılmaz** (statik renge DÜŞÜRÜLMEZ), yalnızca yok sayılır. Mevcut 20 efekt ve kendi API'miz değişmedi.

## 4. Erişim modeli ve güvenlik değerlendirmesi

**Temel gerçek:** WLED API'sinde kimlik doğrulama yoktur ve WLED uygulaması token gönderemez. Bu nedenle bu katman, mevcut token modelinin
**yerine geçmez; ayrı, açıkça seçilen bir istisnadır**. Token koruması hiçbir yerde sessizce kaldırılmadı:

| Mod | Anlamı | Değiştirme yetkisi |
|---|---|---|
| **`off`** (varsayılan, NVS bozuksa da bu) | `/json/*` ve WLED WS reddedilir (403), mDNS `_wled._tcp` yayınlanmaz | – |
| **`readonly`** | Aynı yerel ağdaki herkes **tokensiz okuyabilir** (durum, bilgi, efektler, WS yayını). Yazma 403. | token (`POST /api/wled`) |
| **`control`** | + `on/bri/seg(col,fx,sx,ix,rev)` **tokensiz yazılabilir** | token **ve fiziksel BOOT onayı** (BOOT 3 sn → pencere açıkken) |

Kontroller: mod değişimi yalnızca token ile; `control` ek olarak fiziksel onay ister; aşağı çekmek (`off`/`readonly`) token yeter.
Diğer korumalar: `Host` yalnızca IPv4 sabit adresi veya `esp32-argb(.local)` (DNS rebinding); `Origin` varsa `http://<Host>` olmalı (tarayıcıdan CSRF);
WebSocket yükseltmesinde de aynı Origin/Host denetimi (tarayıcıdan "cross-site WebSocket hijacking"); `POST` için `Content-Type: application/json`;
IP başına 20 istek/sn; gövde ≤ 2 KB; WLED yolundan yalnızca LED durumu (güç, parlaklık, renk, efekt, hız, yoğunluk, yön) değiştirilebilir;
tüm yazmalar mevcut komut kuyruğundan geçer (tek yazar kuralı) ve NVS debounce'u uygulanır; mod NVS'te (`wled_cfg`) kalıcıdır.

**Kalan riskler (kabul edilmiş/belgelenmiş):**
1. `readonly`/`control` iken aynı Wi-Fi ağındaki **her cihaz** (misafirler, ele geçirilmiş IoT cihazları, telefondaki zararlı uygulamalar) WLED API'sini kullanabilir. TLS ve kimlik doğrulama yok. Ev ağı güvenilir değilse `off` bırakın.
2. `control` yalnızca aydınlatma kontrolü verir (Wi-Fi/token/OTA'ya dokunamaz), ama LED şeridini serbestçe değiştirme/sürekli yanıp söndürme (flaşör) mümkündür.
3. WLED uyumluluğu açıkken `GET /json/info` içindeki **MAC adresi** ve mDNS TXT `mac` yerel ağa açıktır (WLED uygulaması bunu kimlik olarak kullanır). `off` iken yayınlanmaz.
4. WLED WS istemcileri eşleştirmesiz çerçeve alır (bağlantı sırasında auth beklemeyen istemci WLED sayılır). Kendi istemcimiz `auth` gönderince bu işaret kalkar; Flutter uygulaması WLED çerçevelerini yok sayar.
5. WebSocket istemci sınırı 4'tür (kendi Flutter + WLED uygulaması + diğerleri paylaşır).
6. Tarayıcı olmayan (native) saldırgan `Origin` göndermez; Origin/Host denetimi **yalnızca tarayıcı kaynaklı** saldırıları engeller.

## 5. Etkinleştirme

Varsayılan: **kapalı**. Seçenekler:

- **Flutter (Windows):** Cihazlar ▸ cihaz ayarları ▸ "WLED uyumluluğu" bölümü: *Kapalı / Salt okunur / Kontrol*.
  *Kontrol* için önce ESP32 BOOT'a 3 sn basın.
- **REST** (token ile):
  ```powershell
  $h = @{ Authorization = "Bearer <TOKEN>"; "Content-Type" = "application/json" }
  Invoke-RestMethod -Uri http://192.168.1.50/api/wled -Headers $h -Method Post -Body '{"mode":"readonly"}'
  # control: önce BOOT'a 3 sn basın, sonra
  Invoke-RestMethod -Uri http://192.168.1.50/api/wled -Headers $h -Method Post -Body '{"mode":"control"}'
  ```
- **Derleme zamanı:** `-D ENABLE_WLED_COMPAT=0` (veya `pio run -e esp32dev_nowled`) → `/json/*`, `_wled._tcp`, WLED WS, tüm modül derlemeden çıkar
  (`GET /api/wled` → `{"compiled":false}`). Varsayılan ortam (`esp32dev`) katmanı içerir (~25 KB Flash).

## 6. Bilinen sınırlamalar

- **Ayrıntı ekranı:** iOS uygulaması karta dokununca `http://<ip>/` adresini WebView'da açar. Bu adres artık WLED'in web arayüzü değil, bu projenin **gömülü
  mobil kontrol arayüzüdür** (§8); Wi-Fi kurulum sayfası `/setup` adresinde durur. WLED'in kendi web arayüzünün tüm özellikleri (palet, preset, segment düzenleme, ayarlar sayfası) yoktur.
- Palet, preset, playlist, gece ışığı, sync (UDP), `/json/live`, `/presets.json`, `/json/palx`, `/json/fxdata` desteklenmez.
- WLED'in standart efekt numaraları (Blink=1, Colorloop=8 …) ile bizimkiler farklı; yalnızca `/json/eff` adlarına güvenen istemciler doğru çalışır.
- Info `ver` = `0.14.0` (uyumluluk taklidi); `brand`/`product` bu firmware'i belirtir.

## 7. Testler

- **Ana bilgisayar (ESP32 gerekmez):** `firmware\test_host\run_host_tests.bat` — 311 doğrulama: ölçek gidiş-dönüşü, on/bri, orantılı parlaklık, segment/renk/fx/sx/ix/rev, `"~"/"~-"/"r"`,
  desteklenmeyen fx, tehlikeli anahtarlar (`rb`, `ota`, `cfg`…), durum yazım/okuma gidiş-dönüşü, resmi uygulamanın zorunlu `info` alanları, Host/Origin denetimi.
- **Flutter:** `flutter test` — erişim modu API'si, firmware sözleşmesi (varsayılan KAPALI, tehlikeli uç nokta yok, token + BOOT şartı, derleme anahtarı).
- **Firmware:** `pio run` (WLED'li) ve `pio run -e esp32dev_nowled`.

### Gerçek cihazda yapılacaklar (YAPILMADI)

1. Yeni firmware'i yükleyin; `GET /api/wled` → `{"mode":"off"}`; iPhone WLED uygulaması cihazı **bulmamalı**.
2. Token ile `readonly` açın → uygulamada cihaz görünmeli (aynı Wi-Fi, Yerel Ağ izni açık). Kart durumu doğru mu (`on`, parlaklık, renk)?
3. Aç/kapa ve parlaklık kaydırıcısı **çalışmamalı** (403/`wled_read_only`).
4. BOOT'a basıp `control` açın → aç/kapa ve parlaklık LED'lere yansımalı; kartın rengi güncellenmeli.
5. `curl http://<ip>/json/info`, `/json/state`, `/json/eff` ve `POST /json/state` (`{"on":true,"bri":128,"v":true}`) ile elle doğrulayın.
6. Flutter uygulamasıyla aynı anda kullanın (WS çerçeveleri karışmamalı, token'lı kontrol sürmeli).
7. Tarayıcıdan başka bir siteden `fetch("http://<ip>/json/state",{method:"POST"…})` → 403 (Origin/Content-Type).
8. `off`'a dönünce uygulama cihazı kaybetmeli (mDNS kaydı kalkar).

## 8. Gömülü LED kontrol arayüzü (`/`)

`http://<ip>/` (iPhone WLED uygulamasının ayrıntı ekranı dahil) → `firmware/src/wled/control_page.h` içindeki tek sayfa (≈ 12 KB HTML+CSS+JS, PROGMEM'den kopyasız sunulur;
CDN/harici betik/yazı tipi YOK). Wi-Fi kurulum sayfası `/setup` adresinde aynen çalışır (arayüzün altında bağlantı vardır).

| Özellik | Gerçekleme |
|---|---|
| Aç/kapat, parlaklık | `{"on":…}`, `{"bri":…}` (tüm seçili kanallar) |
| Renk çarkı + 12 hazır renk | `seg[].col` — iki renk yuvası (1./2. renk) |
| 20 efekt | `/json/eff` adlarıyla; `seg[].fx` |
| Hız, yoğunluk, ters yön | `sx`, `ix`, `rev`; efektin kullanmadığı kontroller soluklaşır (tablo `effect_capabilities.dart` ile aynı, testle doğrulanır) |
| Kanal seçimi | Etkin kanallar çip olarak listelenir (≥2 etkin kanal varsa); renk/efekt/ayarlar yalnızca seçililere gider (`seg:[{id,…}]`) |
| Cihaz durumu | Ad, IP, Wi-Fi sinyali (dBm/%), LED/kanal sayısı, çalışma süresi, boş bellek, bağlantı türü (WebSocket canlı / yoklama) |

**Veri akışı:** açılışta `GET /json/eff` + `GET /json/si`, sonra `ws://<host>/ws` (cihaz durum değişince çerçeve yollar; tüm istemciler senkron kalır).
WS yoksa `POST /json/state` (`v:true`) ve 2,5 sn'lik `GET /json/si` yoklaması devreye girer. Kaydırıcılar en çok 12,5 mesaj/sn gönderir.
**Hata yönetimi:** WS hata çerçeveleri (`wled_read_only`, `busy`, …), HTTP hataları ve ağ kopması kullanıcıya bildirilir; WS 1→8 sn geri çekilmeyle yeniden bağlanır.

**Erişim kuralları (yeni yazma uç noktası YOK; sayfa yalnızca mevcut `/json/state` ve `/ws` yollarını kullanır):**

| Mod | `GET /` | Kontroller |
|---|---|---|
| `off` | Cihaz verisi/kontrol içermeyen sabit bilgi sayfası (+ `/setup` bağlantısı) | – |
| `readonly` | Arayüz sunulur; `info.access=readonly` → kontroller devre dışı, "Salt okunur" bandı; sunucu yazmayı zaten 403'ler | kapalı |
| `control` | Tam arayüz | açık (sunucudaki `control` kuralları geçerli) |

`GET /` için de Host denetimi (DNS rebinding), IP başına hız sınırı ve CSP (`connect-src 'self' ws://<host>`, `frame-ancestors 'none'`) uygulanır.
`/json/info` yanıtına `access` alanı eklendi (WLED uygulaması bilinmeyen alanları yok sayar). `ENABLE_WLED_COMPAT=0` derlemesinde `/` yine kurulum sayfasını sunar.

**Testler:** `python firmware	est_hostrowser_ui_test.py <klasör>` — gerçek sayfa, sahte WLED sunucusuna karşı başsız Chrome'da (iPhone 390×844 görünümü, CDP ile gerçek dokunuş/fare olayları): 42 doğrulama
(render, 20 efekt, güç/parlaklık/renk/efekt/hız/yoğunluk/yön, kanal seçimi, readonly, off, WS hata çerçevesi, WS yokken HTTP yedeği ve yoklama).
Sayfanın gönderdiği komutlar kaydedilir ve `run_host_tests.bat --replay commands.jsonl` ile **firmware'in gerçek eşleme koduyla** yeniden oynatılır (15/15 komut tam kabul).
**iPhone üzerinde (Safari/WLED uygulaması WebView) ve gerçek ESP32'de DOĞRULANMADI.** Özellikle: WKWebView'da `PointerEvent` ile renk çarkı, canvas çizimi, WS CSP davranışı.

## 9. Palet, LED sayısı ve renk çarkı işaretçisi (v0.3 uzantıları)

WLED uygulaması **bilinmeyen alanları yok sayar**; aşağıdakiler bu firmware'e özgü, WLED uyumluluğunu bozmayan eklemelerdir.

| Yer | Alan | Anlam |
|---|---|---|
| `state.seg[]` (okuma/yazma) | `apal` | `[[r,g,b], ...]` 0–5 renk; yazmada tüm paleti değiştirir, `[]` temizler. Geçersiz öğe/6+ renk → istek yok sayılır (`ignored`). |
| `state.seg[]` | `pal` | Palet varsa `1`, yoksa `0`. Yazmada `0` paleti temizler; `1` etkin paleti korur (boşken yok sayılır); diğer değerler yok sayılır. |
| `state.seg[].col` | – | Palet etkinken ilk 3 palet rengini gösterir (efektler yalnızca paleti kullanır). |
| `/json/pal` | – | `["Default","Custom Palette"]`, `info.palcount = 2` |
| `info.argb` | `ch[]`, `maxlen`, `maxtotal`, `warnlen`, `warntotal`, `maxpal`, `reboot` | Kanal başına `{id,en,n[,pen,pn]}`: devre dışı kanallar dahil LED sayıları, bekleyen yapılandırma |
| `POST /json/state`, WS | `{"argb":{"leds":[{"id":0,"n":30},...]}}` | Kanal LED sayısı (0 = kapat). `0–512`, toplam ≤ 1024; aşım yok sayılır. Yalnızca `control` modunda (readonly'de 403 / `wled_read_only`). |
| aynı | `seg[].len` | Etkin kanalın LED sayısı (aynı doğrulama) |
| aynı | `{"argb":{"reboot":true}}` | **Yalnızca bekleyen yapılandırma varsa** yeniden başlatır (WLED'in `rb` anahtarı hâlâ yok sayılır) |
| `info.leds.fps` | – | Ölçülen gerçek kare hızı |

**Güvenlik değerlendirmesi:** Bu yazmalar mevcut `control` modunun (tokensiz, BOOT onaylı açılır) yetki sınıfındadır; yeni bir uç nokta eklenmez.
LED sayısı yazımı kalıcı (NVS) bir yapılandırma değişikliğidir: yanlış/kötü niyetli değer şeridi söndürebilir veya kare hızını düşürebilir ama veri kaybı/yetki yükseltmesi yoktur;
sınırlar sunucuda zorlanır, yazımlar komut kuyruğundaki ortak doğrulamadan geçer ve NVS yazımı debounce'ludur. Bunu istemeyen kullanıcılar modu `readonly`/`off` bırakır.

**Renk çarkı işaretçisi (`#mk`):** Panelde işaretçi artık yüzde konumlandırılır (düzen/boyut bağımsız), parmağı **anlık** izler (sunucu yanıtı beklenmez), başka istemciden gelen
çerçevede ve sayfa açılışında son renge göre yeniden konumlanır. (Önceki sürümde sürükleme sırasında 700 ms boyunca güncellenmiyordu.)
Renk seçimi yalnızca `col` (veya `apal`) gönderir; efekt/animasyon fazı etkilenmez.

**Testler:** `browser_ui_test.py` — palet düzenleme (ekle/sil/sırala/temizle/senkron), işaretçi konumu (açılış, sürükleme, uzaktan değişim), LED sayısı alanları ve sınırları;
`wled_map_test.cpp` — `apal`/`pal`/`len`/`argb` ayrıştırma ve üretim. Gerçek cihaz: `firmware/test_host/palette_device_test.py`.
**iPhone'da ve gerçek ESP32'de bu özellikler henüz DOĞRULANMADI.**
