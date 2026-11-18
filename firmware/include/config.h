#pragma once

#include <Arduino.h>

// ── Hardware Channel Defaults ──────────────────────────────────────────────
// v0.3.2: SABİT GPIO eşlemesi (kullanıcı tarafından değiştirilemez; NVS'teki eski "pin" değeri yok sayılır):
//   CH1 -> GPIO18, CH2 -> GPIO19, CH3 -> GPIO33, CH4 -> GPIO32
// FastLED pini derleme zamanında ister (led_channel.cpp). Çakışma denetimi bu dosyanın sonunda static_assert ile yapılır.
#define MAX_CHANNELS              4

#define CH1_DEFAULT_GPIO          18
#define CH1_DEFAULT_LED_COUNT     10
#define CH1_DEFAULT_ENABLED       true

#define CH2_DEFAULT_GPIO          19
#define CH2_DEFAULT_LED_COUNT     0
#define CH2_DEFAULT_ENABLED       false

#define CH3_DEFAULT_GPIO          33
#define CH3_DEFAULT_LED_COUNT     0
#define CH3_DEFAULT_ENABLED       false

#define CH4_DEFAULT_GPIO          32
#define CH4_DEFAULT_LED_COUNT     0
#define CH4_DEFAULT_ENABLED       false

// ── Wi-Fi & Provisioning Configuration ─────────────────────────────────────
#define WIFI_CONNECT_TIMEOUT_MS   15000
#define WIFI_MAX_RETRY_ATTEMPTS   3
// Denemeler arası bekleme: radyo bu sürede boştur (tarama ve SoftAP istemcileri için).
// Arduino çekirdeğinin kendi otomatik yeniden bağlanması KAPALIDIR; tüm denemeleri WiFiManager yönetir.
#define WIFI_RETRY_BACKOFF_MS     3000
// AP'ye düşüldükten sonra kayıtlı ağ arka planda bu aralıkla yeniden denenir
// (yalnızca SoftAP'ye bağlı istemci yokken ve kurulum etkinliği yokken).
#define WIFI_BACKGROUND_RETRY_MS  120000
// Kurulum etkinliğinden (tarama, seri pencere) sonra arka plan STA denemesi bu kadar ertelenir.
#define WIFI_STA_HOLD_MS          60000
#define WIFI_SCAN_INTERVAL_MS     10000

#define AP_SSID_PREFIX            "ESP32-ARGB-Setup-"
#define AP_DEFAULT_CHANNEL        1
#define AP_MAX_CONNECTIONS        4
#define AP_IP_ADDRESS             IPAddress(192, 168, 4, 1)
#define AP_NETMASK                IPAddress(255, 255, 255, 0)

// ── Device & Network Discovery ─────────────────────────────────────────────
#define MDNS_HOSTNAME             "esp32-argb"
#define HTTP_PORT                 80
#define WS_ENDPOINT               "/ws"
#define FIRMWARE_VERSION          "0.3.2"
#define DEVICE_MODEL              "ESP32-WROOM-32"

// ── WLED uyumluluk katmanı (docs/WLED_COMPAT.md) ───────────────────────────
// 1: derlemeye dahil (erişim modu NVS'te, varsayılan KAPALI). 0: modül tamamen çıkarılır.
// Kapatmak için platformio.ini: -D ENABLE_WLED_COMPAT=0  (veya env:esp32dev_nowled)
#ifndef ENABLE_WLED_COMPAT
#define ENABLE_WLED_COMPAT          1
#endif

// ── Stage 4B: API / Güvenlik / Kalıcılık (bkz. docs/PROTOCOL.md) ────────────
#define API_PROTO_VERSION           1
#define MAX_LEDS_PER_CHANNEL        512     // Henüz performans garantisi DEĞİLDİR
#define MAX_TOTAL_LEDS              1024    // Sert sınır (bkz. docs/PROTOCOL.md §8.5: RAM ~5 B/LED, çıkış 30 µs/LED)
#define LED_WARN_PER_CHANNEL        300     // üstünde kare hızı düşebilir (tek kanal çıkış süresi > ~9 ms): yalnızca uyarı
#define LED_WARN_TOTAL              600
#define LIVE_LED_RESIZE             1       // 1: LED sayısı/kanal etkinleştirme yeniden başlatmadan uygulanır (FastLED setLeds)

#define WS_MAX_MESSAGE_BYTES        1024
#define WS_MAX_CLIENTS              4
#define WS_AUTH_TIMEOUT_MS          5000
#define HTTP_MAX_BODY_BYTES         1024
#define WS_RATE_PER_SEC             40      // istemci başına sürdürülebilir mesaj hızı (Flutter <= 20/sn)
#define WS_RATE_BURST               30      // kısa süreli patlama kapasitesi

#define AUTH_MAX_TOKENS             4
#define PAIRING_WINDOW_MS           120000
#define PAIRING_ALLOW_AP_FIRST_SETUP 0      // 1 = AP üzerinden, token yokken fiziksel onaysız eşleştirme (ÖNERİLMEZ)
#define AUTH_FAIL_LIMIT             5
#define AUTH_LOCK_BASE_MS           60000
#define AUTH_LOCK_MAX_MS            900000

#define PAIR_BUTTON_GPIO            0       // BOOT düğmesi; yalnızca boot SONRASI okunur
#define PAIR_BUTTON_HOLD_MS         3000
#define SECURITY_RESET_HOLD_MS      10000
#define STATUS_LED_GPIO             2

#define CMD_QUEUE_LENGTH            32
#define CMD_MAX_PER_LOOP            16

#define PERSIST_DEBOUNCE_MS         1500
#define PERSIST_MAX_WAIT_MS         10000
#define STATE_BROADCAST_INTERVAL_MS 100
#define SNAPSHOT_REFRESH_MS         250

#define AP_SHUTDOWN_DELAY_MS        30000   // telefon kurulum sonucunu (IP) okuyabilsin

// USB seri port Wi-Fi kurulumu: yalnızca BOOT düğmesiyle açılan kısa pencerede kabul edilir
#define SERIAL_SETUP_WINDOW_MS      120000
#define SERIAL_SETUP_MAX_LINE       255
// Wi-Fi taraması (WiFiManager tek sahip; HTTP ve seri tüketiciler aynı taramaya katılır)
#define SCAN_MS_PER_CHANNEL         300     // aktif tarama, kanal başına (13 kanal ≈ 4–6 sn)
#define SCAN_ATTEMPT_TIMEOUT_MS     12000   // tek deneme bekçisi: SCAN_DONE gelmezse (çekirdeğin 6 sn sınırı değil)
#define SCAN_MAX_ATTEMPTS           3       // başarısız/zaman aşımlı deneme otomatik tekrarlanır
#define SCAN_RETRY_DELAY_MS         500     // denemeler arası (artan: 500, 1000 ms)
#define SCAN_TIMEOUT_MS             45000   // tüketici güvenlik sınırı (3 x 12 sn + bekleme; normalde WiFiManager önce sonuçlandırır)
#define SCAN_MAX_RESULTS            20

// ── Sabit LED GPIO eşlemesinin derleme zamanı doğrulaması (ESP32-WROOM-32) ──
namespace pincheck {
constexpr bool reserved(int p) {
    return p == PAIR_BUTTON_GPIO || p == STATUS_LED_GPIO ||   // BOOT düğmesi (0), durum LED'i (2)
           p == 1 || p == 3 ||                                // UART0 (USB seri kurulum/log)
           p == 5 || p == 12 || p == 15 ||                    // strapping
           (p >= 6 && p <= 11) ||                             // SPI flash
           (p >= 34 && p <= 39) ||                            // yalnızca giriş
           p == 20 || p == 24 || (p >= 28 && p <= 31) || p > 39;   // ESP32'de yok
}
}  // namespace pincheck
static_assert(!pincheck::reserved(CH1_DEFAULT_GPIO) && !pincheck::reserved(CH2_DEFAULT_GPIO) &&
              !pincheck::reserved(CH3_DEFAULT_GPIO) && !pincheck::reserved(CH4_DEFAULT_GPIO),
              "LED GPIO rezerve/yalnızca-giriş/flash pinine denk geliyor");
static_assert(CH1_DEFAULT_GPIO != CH2_DEFAULT_GPIO && CH1_DEFAULT_GPIO != CH3_DEFAULT_GPIO &&
              CH1_DEFAULT_GPIO != CH4_DEFAULT_GPIO && CH2_DEFAULT_GPIO != CH3_DEFAULT_GPIO &&
              CH2_DEFAULT_GPIO != CH4_DEFAULT_GPIO && CH3_DEFAULT_GPIO != CH4_DEFAULT_GPIO,
              "İki kanal aynı GPIO'yu kullanamaz");
