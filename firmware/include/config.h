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
