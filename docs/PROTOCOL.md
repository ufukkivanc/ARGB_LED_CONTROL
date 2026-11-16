# ESP32 Smart ARGB Controller — Protokol ve Mimari Tasarımı

| | |
|---|---|
| Protokol sürümü | `1` (taslak, Stage 4A) |
| Durum | **Tasarım — henüz uygulanmadı.** Stage 4B onayı beklenir. |
| Kapsam | WebSocket + HTTP API, kimlik doğrulama, komut kuyruğu, NVS debounce, Wi-Fi provisioning, Flutter uyumu |

Bu belge, firmware (`firmware/`) ve Flutter uygulaması (`argb_controller_app/`) arasındaki
tek doğruluk kaynağıdır. Kodla çelişirse önce bu belge güncellenir.

---

## 1. Genel Bakış

```
 Flutter (Android/iOS/Web-dev)                ESP32
 ┌──────────────────────────┐   mDNS     ┌─────────────────────────────────┐
 │ DeviceConnectionService  │◄──────────►│ MdnsService  (_http/_ws._tcp)   │
 │  ├ HTTP  /api/*          │───────────►│ AsyncWebServer :80              │
 │  └ WS    /ws             │◄══════════►│  ├ AuthManager (token)          │
 └──────────────────────────┘            │  └ ApiHandlers  (core 0)        │
                                         │        │ xQueueSend (non-block) │
                                         │        ▼                        │
                                         │ CommandQueue ──► loop() (core 1)│
                                         │   ChannelManager / LedChannel   │
                                         │   PersistenceScheduler (NVS)    │
                                         │   StateBroadcaster ──► WS       │
                                         └─────────────────────────────────┘
```

Temel ilkeler:

1. **Tek yazar kuralı:** LED durumunu yalnızca `loop()` (core 1) değiştirir. Ağ callback'leri (core 0) sadece kuyruğa komut koyar.
2. **Sunucu doğruluk kaynağıdır:** İstemci "optimistic" güncelleme yapabilir ama cihazdan gelen `state` mesajı kazanır.
3. **Efektler string ile taşınır** (`"breathing"`), index ile değil.
4. **Kanal bazlı:** Her komut/durum bir kanala (1–4) aittir.
5. **Gizli bilgi asla herkese açık endpoint'ten dönmez.**

---

## 2. Taşıma Katmanı

| Öğe | Değer |
|---|---|
| HTTP | `http://<host>:80` (`HTTP_PORT`) |
| WebSocket | `ws://<host>:80/ws` (`WS_ENDPOINT`) |
| Host | `esp32-argb.local` (mDNS) veya IP; AP modunda `192.168.4.1` |
| Kodlama | UTF-8 JSON, WebSocket **text** frame |
| Maks. mesaj boyutu | 1024 bayt (aşılırsa `error: payload_too_large`) |
| Maks. eşzamanlı WS istemcisi | 4 (5. bağlantı `1013` koduyla kapatılır) |
| TLS | Yok (ESP32 üzerinde maliyetli). Bkz. §4.8 riskler |

mDNS servisleri (mevcut, `mdns_service.cpp`):
`_http._tcp` ve `_ws._tcp` (TXT: `version`, `model`, `mac`, `endpoint`).
Stage 4B: TXT `version`, `model`, `id`, `proto=1`, `paired=0|1`. **`mac` kaldırıldı** (kimliksiz yayında gereksiz ifşa).

---

## 3. Veri Modeli

### 3.1 Kanal durumu (`ChannelState`) — çalışma zamanı, sık değişir

| Alan | Tür | Aralık | Firmware karşılığı |
|---|---|---|---|
| `power` | bool | — | `ChannelState.isOn` |
| `color` | `{r,g,b}` | 0–255 | `primaryColor` |
| `color2` | `{r,g,b}` | 0–255 | `secondaryColor` |
| `effect` | string | §3.3 listesi | `EffectType` |
| `brightness` | int | 0–255 | `brightness` |
| `speed` | int | 1–100 | `speed` |
| `direction` | int | `-1` veya `1` | `direction` |
| `intensity` | int | 0–100 | `intensity` |

### 3.2 Kanal yapılandırması (`ChannelConfig`) — nadir değişir, kalıcı

| Alan | Tür | Aralık | Not |
|---|---|---|---|
| `enabled` | bool | — | |
| `ledCount` | int | 0–`MAX_LEDS_PER_CHANNEL` (öneri: 512) | **Değişim yeniden başlatma gerektirir** |
| `ledType` | string | `"WS2812B"` | şimdilik sabit |
| `colorOrder` | string | `"GRB"`, `"RGB"` | **Yeniden başlatma gerektirir** |
| `maxBrightness` | int | 0–255 | Anında uygulanır (güç/ısı sınırı) |
| `gpio` | int | **salt okunur** | FastLED pin şablonu derleme zamanlı (CH1=18, CH2=19, CH3=21, CH4=22) |

Toplam LED bütçesi: tüm kanallarda `Σ ledCount ≤ MAX_TOTAL_LEDS` (öneri: 1024; her LED 3 bayt RAM + FastLED/RMT tamponları).
Aşılırsa `error: led_budget_exceeded`.

### 3.3 Efekt adları (Dart `EffectType.name` ile birebir aynı — doğrulandı)

`staticColor, rainbow, rainbowCycle, breathing, colorFade, colorWipe, runningLights,
theaterChase, fire, meteorRain, twinkle, sparkle, policeLights, wave, gradientMove,
comet, pulsing, randomTransitions, customGradient, musicReactive`

Kurallar:
- Bilinmeyen efekt adı → `error: invalid_value` (sessizce `staticColor`'a düşürülmez).
- **Stage 6:** 20 efektin **tamamı** firmware'de render edilir; `info.supportedEffects` 20 adın tümünü içerir. Bilinmeyen ad `invalid_value` ile
  reddedilir; NVS'te bozuk bir efekt numarası varsa motor sessizce statik renge DÜŞMEZ, uyarı yazar ve şeridi karartır.

### 3.4 Renk gösterimi

`{"r":108,"g":99,"b":255}`. Ek alan (`brightness` vb.) gönderilirse **yok sayılır** (bkz. §9, Flutter `LedColor.toJson` farkı).

### 3.5 Parametre anlamları (hız, yoğunluk, yön) ve efekt yetenek tablosu

**Hız (`speed`, 1..100)** — *büyük değer = hızlı animasyon*:

| `speed` | Animasyon periyodu (bir tam döngü) |
|---|---|
| 1 | 5000 ms (en yavaş) |
| 50 | 2773 ms |
| 100 | 500 ms (en hızlı) |

Formül (firmware `animation_engine.cpp` ve Flutter `speedToPeriodMs` ile **birebir aynı**, tamsayı bölme):
`period_ms = max(200, 5000 - ((speed - 1) * 4500) / 99)`.
Animasyon fazı sürekli birikir (`faz += dt / period`); hız değişince faz **sıfırlanmaz** ve sıçrama olmaz.
Hızdan etkilenmeyen efektlerde (`staticColor`, `customGradient`) `speed` kabul edilir ama görsel etkisi yoktur;
uygulama bu durumda hız kaydırıcısını gizler.

**Yoğunluk (`intensity`, 0..100)** — efekte göre anlamı değişir (aşağıdaki tablo). **Yön (`direction`)**: `1` ileri, `-1` geri.

| Efekt | speed | intensity anlamı | color | color2 | direction |
|---|---|---|---|---|---|
| staticColor | – | – | ✔ | – | – |
| rainbow | ✔ | dağılım (şeritte kaç renk turu) | – | – | ✔ |
| rainbowCycle | ✔ | doygunluk | – | – | – |
| breathing | ✔ | derinlik | ✔ | – | – |
| colorFade | ✔ | – | ✔ | ✔ | – |
| colorWipe | ✔ | – | ✔ | ✔ (zemin) | ✔ |
| runningLights | ✔ | dalga boyu | ✔ | – | ✔ |
| theaterChase | ✔ | aralık (2..6 piksel) | ✔ | ✔ (soluk boşluk) | ✔ |
| fire | ✔ | alev yüksekliği/kıvılcım | – | – | – |
| meteorRain | ✔ | kuyruk uzunluğu | ✔ | – | ✔ |
| twinkle | ✔ | yıldız yoğunluğu | ✔ | ✔ (soluk zemin) | – |
| sparkle | ✔ | kıvılcım yoğunluğu | ✔ | ✔ (soluk zemin) | – |
| policeLights | ✔ | – | ✔ | ✔ | – |
| wave | ✔ | dalga boyu | ✔ | ✔ | ✔ |
| gradientMove | ✔ | – | ✔ | ✔ | ✔ |
| comet | ✔ | kuyruk uzunluğu | ✔ | – | ✔ |
| pulsing | ✔ | derinlik | ✔ | – | – |
| randomTransitions | ✔ | doygunluk | – | – | – |
| customGradient | – | orta nokta konumu | ✔ | ✔ | – |
| musicReactive | ✔ | darbe şiddeti | ✔ | ✔ | – |

Flutter bu tabloyu `lib/models/effect_capabilities.dart` içinde tutar; firmware ile eşleşmelidir.
Bir kontrol bir efektte etkisizse arayüz o kontrolü gizler/devre dışı bırakır.

### 3.6 Efekt davranışları (Stage 6)

| Efekt | Davranış |
|---|---|
| staticColor | Tüm LED'ler `color`. |
| rainbow | Şerit boyunca uzamsal gökkuşağı kayar; `intensity` = renk turu sayısı (0: 0,25 … 50: 1 … 100: 1,75). |
| rainbowCycle | Tüm şerit aynı renkte, ton döngüsel değişir; `intensity` = doygunluk. |
| breathing | `color` sinüsle nefes alır; `intensity` = derinlik (%30..%100). |
| colorFade | `color` ↔ `color2` sinüsle geçiş. |
| colorWipe | `color` zemin `color2` üzerine soldan silinir, sonra `color2` geri siler. |
| runningLights | `color` sinüs parlaklık dalgası kayar; `intensity` = dalga boyu (3..40 px). |
| theaterChase | Her S pikselde bir yanan nokta kayar; boşluk = soluk `color2`. |
| fire | Fire2012 ısı modeli; `intensity` ↑ = daha çok kıvılcım/daha az soğuma; `hız` = kıpırdama sıklığı. Renk kullanmaz. |
| meteorRain | Tek yönlü meteor + titreşen kuyruk; `intensity` = kuyruk uzunluğu. |
| twinkle | Rastgele yıldızlar yumuşakça parlayıp söner (soluk `color2` zemin). |
| sparkle | Rastgele pikseller ani parlar, hızla söner (soluk `color2` zemin). |
| policeLights | Sol yarı `color`, sağ yarı `color2`, ikişer kısa flaş sırayla (tek LED'de renkler sırayla). |
| wave | `color` ↔ `color2` sinüs dalgası akar; `intensity` = dalga boyu (6..56 px). |
| gradientMove | `color`→`color2`→`color` döngüsel gradyan kayar. |
| comet | Gidip gelen kuyruklu yıldız; baş beyaza çalar; `intensity` = kuyruk uzunluğu. |
| pulsing | Kalp atışı (çift darbe); `intensity` = derinlik. |
| randomTransitions | Her döngüde rastgele yeni renge yumuşak geçiş; `intensity` = doygunluk. |
| customGradient | Statik `color`→`color2` gradyanı; `intensity` = orta nokta konumu (%5..%95). |
| musicReactive | **Ses girişi YOK.** Donanımda mikrofon olmadığından ritmik VU çubuğu BPM ile *simüle edilir* (BPM = 40..140, hıza bağlı); `intensity` = darbe şiddeti. |

`direction = -1` animasyon fazını geriye akıtır (animasyon ters oynar). Tek LED (n=1) ve çok LED durumları için her efektin n<3 dalı tanımlıdır
(ör. meteor/comet/music tek LED'de parlaklık darbesine dönüşür).

---

## 4. Kimlik Doğrulama ve Eşleştirme

### 4.1 Tehdit modeli

Hedef: aynı yerel ağdaki yetkisiz cihazın LED'leri kontrol etmesini veya Wi-Fi şifresini değiştirmesini engellemek.
Kapsam dışı: ağı dinleyen saldırgan (TLS yok), cihaza fiziksel erişim.

### 4.2 Token

| Özellik | Tasarım |
|---|---|
| Üretim | Cihaz üretir: `esp_fill_random()` ile 32 bayt (Wi-Fi açıkken donanım RNG'si) |
| Biçim | 64 karakter hex (`[0-9a-f]{64}`) |
| Cihazda saklama | **Düz token saklanmaz.** NVS namespace `auth_cfg` içinde SHA-256 özeti (mbedtls). Anahtarlar: `t{0..3}h` (32 B özet), `t{0..3}n` (istemci adı, ≤24 karakter), `t{0..3}i` (token id). |
| Slot sayısı | 4 eşleştirilmiş istemci |
| İstemcide saklama | Android Keystore / iOS Keychain (`flutter_secure_storage`, Stage 5). Web geliştirmede `localStorage` (yalnızca geliştirme; belgelenmiş zayıflık) |
| Doğrulama | Sabit zamanlı karşılaştırma (`mbedtls_ct_memcmp` benzeri) |
| Ömür | Süresiz; iptal edilene kadar geçerli (cihazda RTC yok, süre sınırı güvenilmez) |
| `tokenId` | SHA-256(token özeti)'nin ilk 4 baytı = 8 hex karakter; **token değil**, listelemek güvenlidir |

### 4.3 Herkese açık / korumalı uç noktalar

| Uç nokta | Auth | Not |
|---|---|---|
| `GET /api/discover` | Yok | Yalnızca: `deviceId, name, model, fw, proto, paired, pairingOpen, mode`. **Token, SSID, IP, Wi-Fi bilgisi YOK.** |
| `POST /api/pair` | Pencere koşulu (§4.4) | Token'ı **yalnızca bu yanıtta, bir kez** döner |
| Diğer tüm `/api/*` ve WS komutları | **Token zorunlu** | |

### 4.4 Eşleştirme (pairing) — "fiziksel/kanıtlı erişim" şartı

`POST /api/pair` yalnızca şu koşullardan biri sağlanıyorsa kabul edilir:

| # | Koşul | Senaryo |
|---|---|---|
| A | **Eşleştirme penceresi açık** (varsayılan 120 sn) | Normal durum |
| B | İstek **SoftAP arayüzünden** geldi **ve** hiç token yok | **Stage 4B'de varsayılan KAPALI** (`PAIRING_ALLOW_AP_FIRST_SETUP 0`): her eşleştirme fiziksel onay (BOOT) gerektirir |

Pencereyi açma yolları:
1. **BOOT düğmesine (GPIO0) 3 sn basılı tutma** — fiziksel erişim.
2. Eşleştirilmiş bir istemciden `POST /api/pair/open` — ikinci telefon eklemek için.
3. ~~İlk açılışta otomatik (koşul B)~~ — Stage 4B kararıyla devre dışı; ilk kurulumda da BOOT 3 sn gerekir.

Pencere açıkken kart üzerindeki LED (GPIO2) hızlı yanıp söner (LED şeridi etkilenmez).
Pencere ilk başarılı eşleştirmeden sonra veya süre dolunca **kapanır**.

İstek / yanıt:

```http
POST /api/pair
Content-Type: application/json

{ "clientName": "Ufuk'un Pixel 8" }
```
```json
{ "token": "9f2c…(64 hex)", "tokenId": "a1b2c3d4", "deviceId": "esp32-argb-4F2A1C" }
```
Hatalar: `403 pairing_closed`, `409 slots_full`, `429 rate_limited`.

### 4.5 Oturum açma

- **HTTP:** `Authorization: Bearer <token>`
- **WebSocket:** Tarayıcı (Flutter Web) başlık ekleyemediği ve URL'deki token log'lara sızdığı için **ilk mesaj** olarak gönderilir:
  ```json
  { "v":1, "type":"auth", "token":"9f2c…" }
  ```
  - 5 sn içinde `auth` gelmezse bağlantı `4401` ile kapatılır.
  - Auth öncesi yalnızca `auth` ve `ping` kabul edilir; diğerleri `error: unauthorized`.
  - Başarı: `{"v":1,"type":"authOk","deviceId":"…","tokenId":"…"}` ardından tam `state`.
  - Başarısız: `{"type":"error","code":"unauthorized"}` + bağlantı kapanır.

### 4.6 Hız sınırlama / kaba kuvvet koruması

- 5 başarısız auth → o IP için 60 sn kilit (`429 rate_limited`, WS `4429`). Kilit süresi her tekrarda ikiye katlanır (maks. 15 dk).
- `POST /api/pair` penceresi dışında en çok 3 deneme/dk.
- Token 256 bit olduğundan tahmin edilemez; sınırlama esas olarak DoS ve hatalı istemci içindir.

### 4.7 İptal ve sıfırlama

| Eylem | Yetki | Etki |
|---|---|---|
| `GET /api/auth/tokens` | Token | Slotları listeler: `tokenId`, `clientName`, `current` (özet/token **dönmez**) |
| `DELETE /api/auth/tokens/{tokenId}` | Token | O token iptal; açık WS bağlantıları `4403` ile kapanır |
| BOOT **10 sn** | Fiziksel | **Güvenlik sıfırlaması:** tüm token'lar + Wi-Fi bilgisi silinir, AP moduna dönülür |
| `POST /api/factory-reset` `{"confirm":"RESET"}` | Token | `NvsStorage::resetAll()` (token, Wi-Fi, kanallar, ad) + yeniden başlatma |
| Token kaybı (telefon sıfırlandı) | Fiziksel | BOOT 3 sn → pencere → yeniden eşleştirme (eski slot "slots_full" ise önce 10 sn sıfırlama) |

### 4.8 Bilinen riskler (kabul edilen)

1. **TLS yok:** Aynı ağdaki pasif dinleyen saldırgan token'ı görebilir. Azaltma: token yalnızca eşleştirme sırasında bir kez dolaşır; asıl koruma ağın WPA2/3 olmasıdır. Gelecek iş: HTTPS (kendinden imzalı sertifika + sabitleme).
2. ~~MAC türevi AP şifresi~~ **Çözüldü (4B):** ilk AP başlatmada 10 karakterlik rastgele şifre üretilir, NVS'e yazılır ve (prototip aşamasında) yalnızca AP başlarken seri porta basılır. Seri port olmadan şifreyi öğrenmenin yolu henüz yok (etiket/QR Stage 5+).
3. Web geliştirme sürümünde token `localStorage`'da durur.

---

## 5. WebSocket Mesajları

Tüm mesajlar: `{"v":1,"type":"…", …}`. İsteklerde isteğe bağlı `id` (≤12 karakter string) bulunabilir; yanıt aynı `id`'yi taşır.

### 5.1 İstemci → Cihaz

**`set`** — bir veya birden çok kanalı kısmi günceller (yalnızca verilen alanlar değişir; efekt fazı **sıfırlanmaz**).

```json
{ "v":1, "type":"set", "id":"c42",
  "ch": 1,
  "power": true,
  "color":  {"r":108,"g":99,"b":255},
  "color2": {"r":0,"g":210,"b":255},
  "effect": "breathing",
  "brightness": 220, "speed": 55, "direction": 1, "intensity": 50 }
```
- `ch`: `1..4`, `[1,3]` veya `"all"`. Atlanırsa `error: missing_field`.
- Tüm alanlar isteğe bağlı; en az biri gerekir.
- Sahne uygulaması = tek bir `set` (atomik, titreşimsiz).

**`getState`** → `{"v":1,"type":"getState","id":"…"}` : tam `state` döner.
**`getInfo`** → `info` döner.
**`ping`** → `{"type":"pong","t":<millis>}` (istemci 15 sn'de bir gönderir; 40 sn sessizlik = bağlantı kopuk).

**`setChannelConfig`** — yapılandırma (kalıcı):
```json
{ "v":1, "type":"setChannelConfig", "id":"c43", "ch":2,
  "enabled": true, "ledCount": 60, "colorOrder":"GRB", "maxBrightness": 200 }
```
Yanıt `ack` içinde `"rebootRequired": true` (ledCount/colorOrder/enabled değiştiyse).

**`reboot`** → `{"type":"reboot"}`; yanıttan sonra, bekleyen NVS yazımları flush edilip yeniden başlar.

### 5.2 Cihaz → İstemci

**`state`** — tam anlık görüntü (bağlantıda, `getState`'e yanıt olarak ve değişimde yayın):
```json
{ "v":1, "type":"state", "rev":1042,
  "channels":[
    { "ch":1, "enabled":true, "ledCount":60,
      "power":true, "color":{"r":108,"g":99,"b":255}, "color2":{"r":0,"g":210,"b":255},
      "effect":"breathing", "brightness":220, "speed":55, "direction":1, "intensity":50 },
    { "ch":2, "enabled":false, "ledCount":0, "power":true, "…":"…" }
  ] }
```
- `rev`: her durum değişiminde artan sayaç; istemci eski `rev`'i yok sayar.
- Yayın **en çok 10 Hz**, yalnızca değişen kanallar için kısmi olabilir: `"partial":true` ve yalnızca değişen kanallar.
- Komutu gönderen istemciye de gider (uzlaşma).

**`info`**:
```json
{ "v":1, "type":"info", "deviceId":"esp32-argb-4F2A1C", "name":"ESP32 Smart ARGB Controller",
  "model":"ESP32-WROOM-32", "fw":"1.0.0", "proto":1, "mac":"AA:BB:…",
  "maxChannels":4, "maxLedsPerChannel":512, "maxTotalLeds":1024,
  "supportedEffects":["staticColor","breathing","pulsing","rainbow","rainbowCycle","colorFade"],
  "wifi":{"mode":"sta","ssid":"Home","rssi":-58,"ip":"192.168.1.40"},
  "uptimeMs": 123456, "freeHeap": 182000,
  "channelConfigs":[{"ch":1,"enabled":true,"ledCount":60,"ledType":"WS2812B","colorOrder":"GRB","maxBrightness":255,"gpio":18}] }
```

**`ack`**: `{"v":1,"type":"ack","id":"c42","rev":1043}` (+ `rebootRequired` gerekirse).
**`error`**: `{"v":1,"type":"error","id":"c42","code":"invalid_value","field":"brightness","message":"0..255"}`.

### 5.3 Hata kodları

| Kod | Anlam |
|---|---|
| `unauthorized` | Token yok/geçersiz |
| `rate_limited` | Kilit aktif |
| `bad_json` / `bad_version` / `unknown_type` | Biçim hataları |
| `missing_field` / `invalid_value` | Alan eksik / aralık dışı / bilinmeyen efekt |
| `channel_disabled` | Kanal yok veya devre dışı (config komutları hariç) |
| `led_budget_exceeded` | LED bütçesi aşıldı |
| `busy` | Komut kuyruğu dolu — istemci kısa süre sonra yeniden dener |
| `payload_too_large` | >1024 bayt |
| `pairing_closed` / `slots_full` | Eşleştirme hataları |
| `internal` | Beklenmeyen |

Doğrulama kuralı: **hepsi ya da hiçbiri.** Bir `set` içinde tek alan geçersizse hiçbiri uygulanmaz.

### 5.4 İstemci hız ve davranış kuralları (Flutter)

- Slider/renk çarkı sürüklenirken **en çok 20 mesaj/sn** (50 ms throttle), bırakınca son değer kesin gönderilir.
- `busy` alınırsa 100 ms sonra **yalnızca son değeri** yeniden gönder.
- Bağlantı koparsa üstel geri çekilme: 1, 2, 4, 8, 15 sn (üst sınır 15).

---

## 6. HTTP API

Tüm yanıtlar JSON. Hata biçimi §5.2 `error` ile aynıdır, HTTP durum koduyla birlikte.

| Metot / Yol | Auth | Açıklama |
|---|---|---|
| `GET /api/discover` | — | Minimum kimlik bilgisi (§4.3) |
| `POST /api/pair` | pencere | Token üretir (§4.4) |
| `POST /api/pair/open` | ✔ | Pencereyi 120 sn açar |
| `GET /api/info` | ✔ | `info` ile aynı gövde |
| `GET /api/state` | ✔ | `state` ile aynı gövde |
| `POST /api/command` | ✔ | Gövde: §5.1 mesajları (`set`, `setChannelConfig`, `reboot`). WS yokken test/hata ayıklama için |
| `GET /api/auth/tokens` | ✔ | Eşleştirilmiş istemciler |
| `DELETE /api/auth/tokens/{tokenId}` | ✔ | İptal |
| `POST /api/wifi/scan` | ✔ | Taramayı başlatır → `202` |
| `GET /api/wifi/scan` | ✔ | `{"status":"running"\|"done","networks":[{ssid,rssi,security,channel}]}` |
| `POST /api/wifi/connect` | ✔ | `{ssid,password}` → `202` (§7) |
| `GET /api/wifi/status` | ✔ | `{state, ssid, ip, rssi, error?}` |
| `POST /api/wifi/reset` | ✔ | Wi-Fi bilgisini siler, AP moduna döner |
| `POST /api/reboot` | ✔ | Yeniden başlat |
| `POST /api/factory-reset` | ✔ | `{"confirm":"RESET"}` |

`GET /api/wifi/status` yanıtında Wi-Fi **şifresi asla dönmez.**

---

## 7. Wi-Fi Provisioning ve Güvenli Eşleştirme Akışı

```
Kullanıcı      Flutter                       ESP32
   │  cihazı tak   │                           │ NVS'te Wi-Fi yok → AP modu
   │               │                           │ SSID: ESP32-ARGB-Setup-XXXX (WPA2)
   │  AP şifresi ──►  (etiket/QR/seri port)    │ LED(GPIO2) yavaş yanıp söner
   │               │ 1) Telefon AP'ye bağlanır │
   │               │    (Android: WifiNetworkSpecifier,
   │               │     iOS: NEHotspotConfiguration, yedek: elle)
   │               │ 2) GET 192.168.4.1/api/discover ─►  paired:false, mode:"ap"
   │               │ 3) POST /api/pair  ───────────────► koşul B (AP + token yok)
   │               │ ◄────────── token (bir kez) ─────── token özeti NVS'e
   │               │ 4) POST /api/wifi/scan ───────────► async tarama
   │               │    GET  /api/wifi/scan  (poll) ───► ağ listesi
   │  ağ+şifre ───►│ 5) POST /api/wifi/connect ────────► 202; STA denemesi (AP açık kalır)
   │               │ 6) GET /api/wifi/status (poll) ───► connecting → connected + ip
   │               │                                    │ başarı: 10 sn gecikmeyle AP kapanır
   │               │ 7) Telefon ev ağına döner          │
   │               │ 8) mDNS: esp32-argb.local ────────► /api/discover → paired:true
   │               │ 9) WS /ws + auth(token) ──────────► authOk + state
```

Hata durumları:
- Bağlantı başarısız (`WIFI_MAX_RETRY_ATTEMPTS` = 3): `status.state="failed"`, `error` = `auth_failed | not_found | timeout`; AP açık kalır, kullanıcı yeniden dener. Token geçerliliğini korur.
- Uygulama 6. adımda cihaza ulaşamazsa (telefon ağ değiştirdi) 8. adıma geçip eşleştirilmiş token ile cihazı arar; 60 sn bulunamazsa "AP'ye yeniden bağlan" yönergesi gösterir.
- İkinci telefon: ev ağında BOOT 3 sn → `POST /api/pair`.

Firmware'de gereken değişiklik (Stage 4C, mevcut koda dokunur):
`WiFiManager::update()` bağlantı başarılı olunca AP'yi **hemen** kapatıyor. Uygulamanın sonucu okuyabilmesi için 10 sn'lik gecikmeli kapatma gerekir.
Wi-Fi şifresi HTTP gövdesinde AP üzerinden (WPA2 korumalı bağlantı) iletilir; log'a **yazılmaz**.

Platform notları (Stage 5): Android 9+ için `usesCleartextTraffic`, `INTERNET`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`, `NEARBY_WIFI_DEVICES`/konum izni; iOS için `NSLocalNetworkUsageDescription`, `NSBonjourServices` (`_http._tcp`, `_ws._tcp`), ATS `NSAllowsLocalNetworking`, Hotspot Configuration yetkisi.

---

## 8. Mimari Tasarımlar

### 8.1 FreeRTOS komut kuyruğu

**Sorun:** AsyncTCP callback'leri core 0'da (`CONFIG_ASYNC_TCP_RUNNING_CORE=0`), `loop()` core 1'de. `LedChannel` alanları kilitsiz paylaşılırsa yarış oluşur.

**Çözüm:** Çok üreticili / tek tüketicili kuyruk.

```cpp
// include/command.h  (tasarım taslağı — henüz yazılmadı)
enum class CmdType : uint8_t { Set, SetConfig, Reboot, FactoryReset, WifiConnect, WifiScan, WifiReset, PairOpen, RevokeToken };

struct SetPayload {
    uint8_t  chMask;          // bit0..3 = kanal 1..4
    uint16_t fieldMask;       // hangi alanlar geçerli (POWER, COLOR, COLOR2, EFFECT, BRIGHT, SPEED, DIR, INTENS)
    bool     power;
    RgbColor color, color2;
    EffectType effect;
    uint8_t  brightness, speed, intensity;
    int8_t   direction;
};

struct Command {              // sabit boyut, heap yok, String yok
    CmdType  type;
    uint32_t clientId;        // AsyncWebSocketClient::id(), HTTP için 0
    char     reqId[12];
    union { SetPayload set; ConfigPayload cfg; WifiConnectPayload wifi; /* … */ } p;
};
```

- Kuyruk: `xQueueCreate(32, sizeof(Command))` — `WS_MAX_QUEUED_MESSAGES=32` ile uyumlu.
- Üretici (core 0): JSON'u ayrıştırır, **doğrular**, `xQueueSend(q, &cmd, 0)` (bloklamaz). Dolu → `error: busy`.
- Tüketici (`loop()`): her turda `xQueueReceive(q, &cmd, 0)` ile **en çok 16 komut** işler (animasyon 16 ms bütçesini aşmamak için), sonra `ChannelManager::update()`.
- **Birleştirme (coalescing):** Aynı turda aynı kanal için birden çok `Set` gelirse sırayla uygulanır; sonuç tek `state` yayınında toplanır.
- Büyük/ağır işler (Wi-Fi bağlan, tarama, NVS flush, reboot) tüketicide **durum makinesi** olarak çalışır; `loop()` bloklanmaz.
- Cevap yönü: Tüketici `ack/error/state` JSON'unu üretir ve `AsyncWebSocket::text(clientId, …)`/`textAll` ile gönderir. Gönderim hızı `StateBroadcaster` ile sınırlıdır (§8.3).
- Setter'lar `save=false` ile çağrılır; kalıcılığı `PersistenceScheduler` yönetir (§8.2).

### 8.2 NVS dirty flag + debounce (`PersistenceScheduler`)

**Sorun:** Her setter anında `saveChannelState` çağırıyor; slider sürüklemesi flash'ı aşındırır ve yazma sırasında animasyon takılır.

```
markStateDirty(ch)   → dirtyState |= bit(ch); lastChange[ch] = now; if(!firstDirty[ch]) firstDirty[ch] = now
markConfigDirty(ch)  → config için aynısı, ancak debounce 0 (anında flush; nadir)
tick() (her loop):
   for ch in 1..4:
      if dirtyState bit(ch):
          quiet = now - lastChange[ch] >= 1500 ms   // debounce
          stale = now - firstDirty[ch]  >= 10000 ms // sürekli değişimde azami bekleme
          if (quiet || stale):  if (state != lastSavedState[ch]) NVS.save();  clear flags
   tek turda en çok 1 kanal yazılır (gecikmeyi dağıtmak için)
flushAll()  → reboot, factory reset öncesi, Wi-Fi bağlandı geçişi öncesi
```

- `lastSavedState[ch]` ile karşılaştırma: değer eski haline döndüyse yazma yapılmaz.
- Yazma yükü tahmini: tipik kullanımda sürükleme başına 1 yazma (≈1.5 sn sonra); sürekli sürüklemede ≥10 sn'de 1 yazma. (Şimdiki durumda saniyede onlarca.)
- `LedChannel` setter'ları `save` parametresini korur (geriye uyumlu); API yolu `false` geçer. Mevcut Stage 1–3 kodu bozulmaz.
- Ek düzeltmeler (4B kapsamı): `setSpeed` önce kısıtlayıp sonra karşılaştırsın; `setDirection`/`setIntensity` değişmediyse yazmasın.
- Güç kesintisi riski: son ≤1.5 sn'lik değişiklik kaybolabilir — kabul edilebilir.

### 8.3 Durum yayını (`StateBroadcaster`)

- Her kanal için `rev` ve `changedMask`. Tüketici durum değiştirince işaretler.
- En çok 10 Hz: `now - lastBroadcast >= 100 ms` ve `changedMask != 0` ise değişen kanalları `partial` mesajla tüm yetkili istemcilere yollar.
- Yeni bağlanan (auth olan) istemciye tam `state` hemen gönderilir.
- Yavaş istemci: `client->queueIsFull()` ise o istemciye atla (gecikmiş mesaj biriktirme).

### 8.4 Dört bağımsız kanal ve değişken LED sayısı

Mevcut durum: 4 `LedChannel`, her biri kendi `CRGB*` tamponu; FastLED pin şablonları derleme zamanlı.

Plan:
- **Kanal başına bağımsız durum** zaten var; API tüm alanlara `ch` ekler. Kanallar arası ortak olan yalnızca zamanlayıcıdır (60 FPS).
- **LED sayısı çalışma zamanında değişebilir mi?** FastLED'de eklenen denetleyici kaldırılamaz → `ledCount`/`enabled`/`colorOrder` değişikliği **NVS'e kaydedilir, `rebootRequired:true` döner**, yeniden başlatmada uygulanır. (Güvenli, basit, bellek parçalanması yok.) Alternatif — sıcak yeniden yapılandırma — Stage 6+ sonrası değerlendirilecek.
- `setConfig()` bugün bellek ayırmayı/denetleyiciyi yeniden kurmuyor; bu yüzden API yalnızca kaydeder, canlı uygulamaz (`maxBrightness` hariç).
- Doğrulama: `ledCount ≤ 512`, toplam ≤ 1024, `enabled` ise `ledCount ≥ 1`.
- **Varsayılan `CH1_DEFAULT_LED_COUNT = 1`** test değeridir; Stage 4B'de uygulama üzerinden ayarlanır (varsayılan değiştirme önerisi: 30) — karar kullanıcıda.
- Güç güvenliği: toplam LED sayısı yüksekse `maxBrightness` varsayılanını düşürme önerisi (5 V besleme sınırı), uygulamada uyarı.

---

## 9. Flutter ↔ Firmware Veri Modeli Uyumsuzlukları ve Çözümler

| # | Uyumsuzluk | Flutter (şimdi) | Firmware | Çözüm |
|---|---|---|---|---|
| 1 | Kanal kavramı | Tek `DeviceState` | 4 kanal | `DeviceSnapshot { Map<int, ChannelState> channels, int rev }`; seçili kanal UI state'i |
| 2 | İkincil renk | Yok | `secondaryColor` | `ChannelState.color2` ekle (`colorFade` gerektirir) |
| 3 | Efekt kodlaması | `effectType.index` | string adı | `effectType.name` gönder; `EffectType.values.byName` + bilinmeyende hata/yedek. Adlar birebir aynı (doğrulandı) |
| 4 | Güvensiz parse | `EffectType.values[index]` (aralık dışı → çökme) | — | `byName` + `try/catch` |
| 5 | Renk JSON'u | `LedColor.toJson` `{r,g,b,brightness}` | `{r,g,b}` | Protokol için ayrı `toWire()`; fazladan alan gönderme (cihaz yok sayar ama gereksiz) |
| 6 | `power` adı | `isOn` | `isOn` / protokol: `power` | Wire alan adı `power`; modelde `isOn` kalabilir, serileştirme katmanı çevirir |
| 7 | Yapılandırma | `DeviceConfig` (60 LED, GPIO 2, ad, fw tek yapı) | Kanal başına `ChannelConfig`; ad/fw cihaz düzeyinde | `DeviceInfo` (ad, fw, id) + `ChannelConfig` (ledCount, ledType, colorOrder, maxBrightness, gpio salt okunur) olarak böl |
| 8 | Varsayılanlar | LED 60, GPIO 2, intensity 60 / 50 | LED 1, GPIO 18, intensity 50 | UI'da sabit varsayılan tutma; bağlanana kadar `loading` durumu, ilk `state` ile doldur |
| 9 | Başlangıç durumu | Sahte yerel state (`breathing`, mor) | NVS'ten gelir | Sahte state kaldırılır; çevrimdışıyken kontroller devre dışı |
| 10 | `direction` | int | `±1` | `-1/1`'e sıkıştır (0 gönderme) |
| 11 | Sahne (`Scene`) | Alan alan ayrı çağrılar | — | Tek atomik `set` mesajı |
| 12 | Hız semantiği | `Effect.speed` efekt başına öntanım | Kanal başına tek `speed` | Efekt değişince öntanım hızı `set` içinde birlikte gönderilebilir (isteğe bağlı) |
| 13 | Bağlantı / kimlik | `ConnectionStatus` var, servis yok | Token + WS | `DeviceConnectionService`, `AuthRepository` (secure storage), `DeviceDiscovery` (mDNS + elle IP) |
| 14 | İyimser güncelleme | UI hemen değişir | Sunucu `rev` yayınlar | Yerel değişiklik uygula → sürükleme bitince/`state` gelince uzlaştır; eski `rev` yoksay |
| 15 | Desteklenmeyen efektler | Hepsi seçilebilir | 6 efekt gerçek | `info.supportedEffects` ile gri/“yakında” rozet (Stage 6'ya kadar) |

---

## 10. Sürümleme ve Uyumluluk

- Her mesajda `v`. Cihaz bilinmeyen `v` için `error: bad_version` döner; `info.proto` istemcinin uyumluluk kontrolü içindir.
- Geriye uyumlu eklemeler (yeni alan, yeni `type`) sürümü artırmaz; alıcılar bilinmeyen alanları yok sayar.

## 11. Uygulama Aşamaları

| Aşama | İçerik | Durum |
|---|---|---|
| **4A** | Bu belge, git, .gitignore | ✔ tamamlandı |
| 4B | `AsyncWebServer` + `/ws`, `AuthManager`, komut kuyruğu, `PersistenceScheduler`, `StateBroadcaster`, `/api/discover|pair|info|state` | Onay bekliyor |
| 4C | Wi-Fi provisioning uç noktaları, AP gecikmeli kapanış, BOOT düğmesi, AP şifre güçlendirme | Onay bekliyor |
| 5 | Flutter: bağımlılıklar, modeller, servis, ekranlar, platform izinleri | — |
| 6 | Kalan 16 efekt | — |

## 12. Stage 4B Uygulama Notları (belgeden sapmalar ve netleştirmeler)

- Kod yerleşimi: `src/api/` (api_server, api_json, command, command_processor, snapshot), `src/auth/auth_manager`, `src/storage/persistence_scheduler`, `src/hw/button_manager`.
- Core 0 → core 1 köprüsü: komutlar `xQueueCreate(32, sizeof(Command))` kuyruğuna; salt-okunur GET'ler `SnapshotStore` (mutex'li kopya) üzerinden. LED/Wi-Fi nesnelerine yalnızca `loop()` dokunur.
- `ack`, komut `loop()`'ta uygulandıktan sonra gönderilir (`rev` ile). HTTP `POST /api/command` yalnızca `202 queued` döner.
- `set` içinde `ch` **zorunlu**; `"all"` yalnızca etkin kanallara uygulanır. Etkin olmayan kanal açıkça seçilirse `channel_disabled`.
- `setChannelConfig`: `maxBrightness` canlı uygulanır; `enabled/ledCount/colorOrder` NVS'e yazılır ve `rebootRequired` döner. Bekleyen değerler `state.channels[].pendingConfig` ile görünür. (Canlı `setConfig()` kullanılmaz: LED tamponu taşabilir.)
- Wi-Fi kimlik bilgisi artık **yalnızca bağlantı başarılı olunca** NVS'e yazılır (hatalı şifre kalıcı olmaz). Başarıdan sonra AP 10 sn gecikmeyle kapanır. Not: ESP32'de AP kanalı STA kanalına uyduğundan, bağlanma sırasında telefon AP bağlantısını geçici kaybedebilir; uygulama `GET /api/wifi/status` yerine mDNS/IP ile yeniden bulmaya hazır olmalı.
- Düğme: BOOT (GPIO0) boot sırasında basılıysa bırakılana kadar yok sayılır. 3 sn basılı tutup **bırakınca** eşleştirme penceresi açılır; 10 sn tutunca güvenlik sıfırlaması.
- CORS: `Access-Control-Allow-Origin: *` (Flutter Web geliştirme). Kimlik çerezle değil başlıkla taşındığı için kabul edildi.
- mDNS `paired` TXT'si token sayısı değişince güncellenir.

## 13. Açık Kararlar

1. AP şifresi: MAC türevi (mevcut) yerine rastgele üretilip NVS'e yazılsın mı? (öneri: evet)
2. `CH1_DEFAULT_LED_COUNT` 1 → 30 yapılsın mı?
3. `MAX_LEDS_PER_CHANNEL=512`, `MAX_TOTAL_LEDS=1024` sınırları uygun mu?
4. Eşleştirme penceresi 120 sn ve 4 token slotu yeterli mi?
5. BOOT düğmesi (GPIO0) fiziksel tetikleyici olarak kullanılabilir mi (kartınızda erişilebilir mi)?

## 14. Flutter İstemci Davranışı (Stage 5)

- **Keşif:** Android/iOS/macOS/Windows'ta mDNS (`_http._tcp`, TXT `proto`) + doğrudan yoklama (`esp32-argb.local`, `192.168.4.1`, kayıtlı adresler);
  Flutter Web'de tarayıcı mDNS yapamaz → yalnızca doğrudan yoklama ve elle IP girişi. Aday her zaman `GET /api/discover` ile doğrulanır
  (`proto == 1`).
- **Token saklama:** Android Keystore / iOS Keychain (`flutter_secure_storage`). **Web'de varsayılan: yalnızca bellek** (sekme kapanınca yeniden
  eşleştirme). Kullanıcı açıkça "Tarayıcıda hatırla (güvenli değil)" seçerse tarayıcı depolamasına yazılır. Token log'a/URL'ye yazılmaz;
  yalnızca `Authorization: Bearer` başlığı ve ilk WS `auth` mesajında taşınır.
- **WS oturumu:** bağlan → `auth` → `authOk` + `state`. Komutlar en çok 20 mesaj/sn (50 ms throttle, bırakınca son değer), aynı değer tekrar
  gönderilmez, `busy` yanıtında yalnızca son değer yeniden gönderilir. Yakın zamanda gönderilen alanlar 600 ms boyunca eski yayınlarla ezilmez.
  Eski `rev`'li kısmi `state` yok sayılır. Ping 15 sn, 40 sn sessizlikte yeniden bağlanma; geri çekilme 1, 2, 4, 8, 15 sn;
  3 başarısız denemeden sonra cihaz kimliğiyle yeniden aranır (IP değişmiş olabilir).
- **Kapanış kodları:** `4401` (auth zaman aşımı/geçersiz), `4403` (token iptal) → yerel token silinir ve yeniden eşleştirme istenir;
  `4429` → en az 60 sn bekle.
- **Kurulum sihirbazı:** SoftAP'ye bağlan (kullanıcı sistem Wi-Fi ayarından; Web'de bilgisayarın Wi-Fi'ı elle) → `192.168.4.1` yoklama →
  BOOT ile eşleştirme (pencere otomatik algılanır) → `POST/GET /api/wifi/scan` → SSID/şifre → `POST /api/wifi/connect` → `GET /api/wifi/status`
  yoklaması → AP kapanırken bağlantı kaybı beklenir (3 ardışık ağ hatasından sonra yerel ağda yeniden keşfe geçilir) → `deviceId` ile yeniden bul.
  Wi-Fi şifresi yalnızca istek gövdesinde gider, uygulama state'inde/loglarda/kalıcı depoda tutulmaz.
- **Bilinen sınır:** Kurulum ağına OTOMATİK bağlanma (Android `WifiNetworkSpecifier`, iOS `NEHotspotConfiguration`) bu sürümde yok;
  kullanıcı sistem Wi-Fi ayarlarına yönlendirilir. AP şifresi prototipte yalnızca seri porttan görülür.

## 15. Performans ve Güvenilirlik (Stage 6)

- **Bloklamayan render:** Animasyonlar `loop()` (core 1) içinde 60 FPS zamanlayıcıyla çalışır, `delay()` kullanılmaz; Wi-Fi/AsyncTCP core 0'dadır,
  bu yüzden animasyon ağ trafiğini engellemez. Faz `dt/periyot` ile birikir; kare atlama/ağ gecikmesi sıçrama üretmez (dt ≥ 1 sn yutulur).
- **Bellek:** Durumlu efektler (fire, twinkle, sparkle) kanal başına yalnızca ilgili efekt seçilince `n` veya `2n` bayt ayırır; efekt değişince tampon temizlenir.
  LED tamponları 3 bayt/LED. Sınırlar (kanal başına 512, toplam 1024 LED) **performans garantisi değildir**: WS2812 için ≈30 µs/LED,
  512 LED ≈ 15 ms/kare → 60 FPS sınırda; RMT kanallarının paralel çalışması FastLED sürümüne bağlıdır ve **donanımda ölçülmemiştir**.
- **Mesaj hızı sınırı:** WebSocket istemcisi başına token bucket (40 mesaj/sn sürekli, 30 patlama). Aşan mesajlar ayrıştırılmadan atılır;
  `rate_limited` hatası saniyede en çok 1 kez döner. Flutter 20 mesaj/sn ile sınırlıdır.
- **Komut kuyruğu:** 32 yuva; dolunca `busy` döner ve istemci yalnızca son değeri yeniden gönderir.
- **NVS:** Durum yazımları 1,5 sn debounce / 10 sn azami bekleme ile birleştirilir; değişmemiş durum yazılmaz.
- **Güvenlik:** Token + Wi-Fi şifresi loglanmaz; kaba kuvvet kilidi; eşleştirme için fiziksel onay; gövde/mesaj ≤ 1 KB; TLS yok (bkz. §4.8).

## 16. USB Seri Port Wi-Fi Kurulumu (Windows masaüstü)

Flutter Windows uygulaması ("Cihazlar" ▸ "USB ile Wi-Fi kur") ESP32'yi COM portundan (115200 baud) yapılandırır.
Web/mobilde bu özellik gösterilmez (`SerialBackend.supported == false`).

**Fiziksel yetkilendirme:** BOOT düğmesine 3 sn basılıp bırakılınca 120 sn'lik *seri kurulum penceresi* açılır
(eşleştirme penceresiyle aynı jestle). `scan` ve `wifi` komutları pencere kapalıyken `window_closed` ile reddedilir.
Başarılı kurulumda veya süre dolunca pencere kapanır. `hello`/`status` pencereden bağımsızdır (kimlik/durum, gizli bilgi yok).

**Çerçeveleme:** satır tabanlı (`\n`). İstek: tek satır JSON `{"cmd":"hello|status|scan|wifi",...}` (≤ 255 bayt).
Cihaz yanıtları `ARGB:` önekiyle başlar ve tek `Serial.write` ile gönderilir; önek taşımayan satırlar (boot/log) istemci tarafından yok sayılır,
bozuk satırlar atlanır — seri monitör logları protokolü bozmaz.

| İstek | Yanıt |
|---|---|
| `{"cmd":"hello"}` / `{"cmd":"status"}` | `{"type":"hello\|status","deviceId","fw","window","remainingMs","state","ssid?","ip?","error?"}` |
| `{"cmd":"scan"}` | `scanStarted` → `{"type":"scanResult","networks":[{ssid,rssi,security,channel}]}` (≤ 20) veya `error` |
| `{"cmd":"wifi","ssid":"..","pass":".."}` | `wifiAccepted` → `{"type":"event","state":"connecting\|connected\|failed",...}`; `connected` olayı `ssid` + DHCP `ip` içerir |

Hata kodları: `window_closed`, `scan_busy`, `scan_timeout`, `invalid_ssid`, `invalid_password`, `bad_json`, `missing_cmd`, `unknown_cmd`, `line_too_long`.

**Güvenlik/NVS:** SSID/şifre loglanmaz ve yankılanmaz; satır tamponu işlendikten sonra sıfırlanır. Kimlik bilgisi (mevcut `WiFiManager` yoluyla)
yalnızca bağlantı **başarılı** olunca NVS'e yazılır; sonraki açılışlarda `WiFiManager::begin()` otomatik bağlanır.
Port DTR/RTS yükseltilmeden açılır (otomatik reset'i önlemek için); yine de kart resetlenirse istemci `hello`'yu boot süresince yeniden dener.
Kurulum sonrası uygulama cihazı yerel ağ IP'siyle açar; kontrol için eşleştirme (token) gerekir ve BOOT'tan açılan eşleştirme penceresi (120 sn) hâlâ açıksa otomatik tamamlanır.
