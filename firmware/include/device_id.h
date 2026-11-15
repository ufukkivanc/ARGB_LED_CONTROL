#pragma once

#include <Arduino.h>
#include <esp_mac.h>

// Cihaz kimliği: "esp32-argb-" + MAC'in son 3 baytı (hex, büyük harf)
inline String getDeviceId() {
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    char buf[32];
    snprintf(buf, sizeof(buf), "esp32-argb-%02X%02X%02X", mac[3], mac[4], mac[5]);
    return String(buf);
}
