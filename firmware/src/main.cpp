#include <Arduino.h>
#include "config.h"
#include "types.h"
#include "storage/nvs_storage.h"
#include "network/wifi_manager.h"
#include "network/mdns_service.h"
#include "led/channel_manager.h"
#include "api/snapshot.h"
#include "api/command_processor.h"
#include "api/api_server.h"
#include "auth/auth_manager.h"
#include "hw/button_manager.h"
#include "hw/serial_provisioning.h"
#include "wled/wled_compat.h"
#include "storage/persistence_scheduler.h"

static uint32_t lastHeartbeat = 0;

void setup() {
    Serial.begin(115200);
    delay(500); // Settle delay for serial output

    Serial.println();
    Serial.println("==================================================");
    Serial.printf(" ESP32 Smart ARGB Controller - Firmware %s\n", FIRMWARE_VERSION);
    Serial.println("==================================================");
    Serial.printf("Chip Model:     %s (Rev %d, %d Cores)\n",
                  ESP.getChipModel(), ESP.getChipRevision(), ESP.getChipCores());
    Serial.printf("Flash Size:     %d MB\n", ESP.getFlashChipSize() / (1024 * 1024));
    Serial.printf("Free Heap:      %d KB\n", ESP.getFreeHeap() / 1024);
    Serial.println("==================================================");

    // ── Hardware Safety Pre-Init ───────────────────────────────────────────
    // Pull CH1 GPIO18 LOW immediately upon boot to prevent spurious flashes
    pinMode(CH1_DEFAULT_GPIO, OUTPUT);
    digitalWrite(CH1_DEFAULT_GPIO, LOW);

    // ── Persistent Storage Initialization ──────────────────────────────────
    if (NvsStorage::instance().begin()) {
        Serial.println("[System] NVS storage initialized successfully.");
    } else {
        Serial.println("[System] WARNING: NVS storage initialization failed!");
    }

    // ── FastLED Multi-Channel Engine Initialization ────────────────────────
    ChannelManager::instance().begin();

    // ── Wi-Fi System Initialization ────────────────────────────────────────
    WiFiManager::instance().onStateChange([](WiFiConnectionState state, const String& detail) {
        Serial.printf("[Event] Wi-Fi State changed: %s (%s)\n",
                      WiFiManager::instance().getStateString().c_str(), detail.c_str());

        if (state == WiFiConnectionState::Connected) {
            MdnsService::instance().begin();
        }
    });

    WiFiManager::instance().begin();

    // ── Stage 4B: Kimlik doğrulama + komut kuyruğu + HTTP/WebSocket API ────
    AuthManager::instance().begin();
    CommandProcessor::instance().begin();
    ApiServer::instance().begin(NvsStorage::instance().getDeviceName());
    ButtonManager::instance().begin();
    SerialProvisioning::instance().begin();
#if ENABLE_WLED_COMPAT
    WledCompat::instance().begin();   // erişim modu NVS'ten (varsayılan: KAPALI)
#endif

    Serial.println("[System] All systems initialized. Entering non-blocking loop.");
}

void loop() {
    // ── Non-blocking Wi-Fi State Machine ───────────────────────────────────
    WiFiManager::instance().update();

    // ── API komut kuyruğu (core 0 callback'leri -> core 1 tek yazar) ───────
    CommandProcessor::instance().update();

    // ── Non-blocking 60 FPS LED Animation Scheduler ───────────────────────
    // Runs autonomously regardless of Wi-Fi connection state
    ChannelManager::instance().update();

    // ── Debounce'lu NVS yazımı, düğme/LED, WebSocket bakımı ────────────────
    PersistenceScheduler::instance().tick(millis());
    ButtonManager::instance().update();
    SerialProvisioning::instance().update();
#if ENABLE_WLED_COMPAT
    WledCompat::instance().tick();
#endif
    ApiServer::instance().tick();

    // ── Periodic System Heartbeat (every 5 seconds) ────────────────────────
    uint32_t now = millis();
    if (now - lastHeartbeat >= 5000) {
        lastHeartbeat = now;

        LedChannel* ch1 = ChannelManager::instance().getChannel(1);
        String ch1Info = "Disabled";
        if (ch1 != nullptr && ch1->isEnabled()) {
            RgbColor c = ch1->getColor();
            char buf[64];
            snprintf(buf, sizeof(buf), "Power:%s | %s | RGB(%d,%d,%d) | Bri:%d",
                     ch1->isOn() ? "ON" : "OFF",
                     effectTypeToString(ch1->getEffect()),
                     c.r, c.g, c.b,
                     ch1->getBrightness());
            ch1Info = String(buf);
        }

        if (WiFiManager::instance().isConnected()) {
            Serial.printf("[Heartbeat] Wi-Fi: STA (%s, %d dBm) | CH1: [%s] | Heap: %d KB\n",
                          WiFiManager::instance().getLocalIP().c_str(),
                          WiFiManager::instance().getRSSI(),
                          ch1Info.c_str(),
                          ESP.getFreeHeap() / 1024);
        } else if (WiFiManager::instance().isApActive()) {
            Serial.printf("[Heartbeat] Wi-Fi: AP (%s) | CH1: [%s] | Heap: %d KB\n",
                          WiFiManager::instance().getApSSID().c_str(),
                          ch1Info.c_str(),
                          ESP.getFreeHeap() / 1024);
        } else {
            Serial.printf("[Heartbeat] Wi-Fi: %s | CH1: [%s] | Heap: %d KB\n",
                          WiFiManager::instance().getStateString().c_str(),
                          ch1Info.c_str(),
                          ESP.getFreeHeap() / 1024);
        }
    }

    yield();
}
