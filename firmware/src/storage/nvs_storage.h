#pragma once

#include <Arduino.h>
#include <Preferences.h>
#include "types.h"
#include "constants.h"

class NvsStorage {
public:
    static NvsStorage& instance();

    bool begin();

    // ── Wi-Fi Credentials ──────────────────────────────────────────────────
    bool hasWiFiCredentials();
    bool loadWiFiCredentials(String& ssid, String& password);
    bool saveWiFiCredentials(const String& ssid, const String& password);
    bool clearWiFiCredentials();

    // ── Setup Access Point Password ────────────────────────────────────────
    String getOrGenerateSetupPassword();
    bool saveSetupPassword(const String& password);

    // ── Device Information ─────────────────────────────────────────────────
    String getDeviceName();
    bool setDeviceName(const String& name);

    // ── Multi-Channel Storage ──────────────────────────────────────────────
    bool loadChannelConfig(uint8_t channelId, ChannelConfig& config);
    bool saveChannelConfig(uint8_t channelId, const ChannelConfig& config);

    bool loadChannelState(uint8_t channelId, ChannelState& state);
    bool saveChannelState(uint8_t channelId, const ChannelState& state);

    // ── Factory Reset ──────────────────────────────────────────────────────
    bool resetAll();

private:
    NvsStorage() = default;
    Preferences _prefs;

    String _channelKey(uint8_t channelId, const char* prefix);
};
