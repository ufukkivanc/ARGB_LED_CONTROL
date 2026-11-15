#pragma once

#include <Arduino.h>

// ── Hardware Channel Defaults ──────────────────────────────────────────────
#define MAX_CHANNELS              4

#define CH1_DEFAULT_GPIO          18
#define CH1_DEFAULT_LED_COUNT     1
#define CH1_DEFAULT_ENABLED       true

#define CH2_DEFAULT_GPIO          19
#define CH2_DEFAULT_LED_COUNT     0
#define CH2_DEFAULT_ENABLED       false

#define CH3_DEFAULT_GPIO          21
#define CH3_DEFAULT_LED_COUNT     0
#define CH3_DEFAULT_ENABLED       false

#define CH4_DEFAULT_GPIO          22
#define CH4_DEFAULT_LED_COUNT     0
#define CH4_DEFAULT_ENABLED       false

// ── Wi-Fi & Provisioning Configuration ─────────────────────────────────────
#define WIFI_CONNECT_TIMEOUT_MS   15000
#define WIFI_MAX_RETRY_ATTEMPTS   3
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
#define FIRMWARE_VERSION          "1.0.0"
#define DEVICE_MODEL              "ESP32-WROOM-32"

// ── Stage 4B: API / Güvenlik / Kalıcılık (bkz. docs/PROTOCOL.md) ────────────
#define API_PROTO_VERSION           1
#define MAX_LEDS_PER_CHANNEL        512     // Henüz performans garantisi DEĞİLDİR
#define MAX_TOTAL_LEDS              1024    // Henüz performans garantisi DEĞİLDİR

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

#define AP_SHUTDOWN_DELAY_MS        10000
#define SCAN_TIMEOUT_MS             20000
#define SCAN_MAX_RESULTS            20
