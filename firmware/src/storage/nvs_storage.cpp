#include "nvs_storage.h"
#include <esp_wifi.h>

NvsStorage& NvsStorage::instance() {
    static NvsStorage storage;
    return storage;
}

bool NvsStorage::begin() {
    return true;
}

bool NvsStorage::hasWiFiCredentials() {
    if (!_prefs.begin(NVS_NS_WIFI, true)) return false;
    String ssid = _prefs.getString(NVS_KEY_WIFI_SSID, "");
    _prefs.end();
    return ssid.length() > 0;
}

bool NvsStorage::loadWiFiCredentials(String& ssid, String& password) {
    if (!_prefs.begin(NVS_NS_WIFI, true)) return false;
    ssid = _prefs.getString(NVS_KEY_WIFI_SSID, "");
    password = _prefs.getString(NVS_KEY_WIFI_PASS, "");
    _prefs.end();
    return ssid.length() > 0;
}

bool NvsStorage::saveWiFiCredentials(const String& ssid, const String& password) {
    if (!_prefs.begin(NVS_NS_WIFI, false)) return false;
    _prefs.putString(NVS_KEY_WIFI_SSID, ssid);
    _prefs.putString(NVS_KEY_WIFI_PASS, password);
    _prefs.end();
    return true;
}

bool NvsStorage::clearWiFiCredentials() {
    if (!_prefs.begin(NVS_NS_WIFI, false)) return false;
    _prefs.remove(NVS_KEY_WIFI_SSID);
    _prefs.remove(NVS_KEY_WIFI_PASS);
    _prefs.end();
    return true;
}

String NvsStorage::getOrGenerateSetupPassword() {
    if (_prefs.begin(NVS_NS_WIFI, true)) {
        String customPass = _prefs.getString(NVS_KEY_SETUP_PASS, "");
        _prefs.end();
        if (customPass.length() >= 8) {
            return customPass;
        }
    }

    // Generate secure deterministic device-specific password based on MAC address
    // Example: "argb" + last 6 MAC hex characters (total 10 chars, > 8 char WPA2 requirement)
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    char defaultPass[16];
    snprintf(defaultPass, sizeof(defaultPass), "argb%02X%02X%02X", mac[3], mac[4], mac[5]);
    return String(defaultPass);
}

bool NvsStorage::saveSetupPassword(const String& password) {
    if (password.length() < 8) return false;
    if (!_prefs.begin(NVS_NS_WIFI, false)) return false;
    _prefs.putString(NVS_KEY_SETUP_PASS, password);
    _prefs.end();
    return true;
}

String NvsStorage::getDeviceName() {
    if (!_prefs.begin(NVS_NS_DEVICE, true)) return DEFAULT_DEVICE_NAME;
    String name = _prefs.getString(NVS_KEY_DEV_NAME, DEFAULT_DEVICE_NAME);
    _prefs.end();
    return name;
}

bool NvsStorage::setDeviceName(const String& name) {
    if (!_prefs.begin(NVS_NS_DEVICE, false)) return false;
    _prefs.putString(NVS_KEY_DEV_NAME, name);
    _prefs.end();
    return true;
}

String NvsStorage::_channelKey(uint8_t channelId, const char* prefix) {
    return String(prefix) + "_" + String(channelId);
}

bool NvsStorage::loadChannelConfig(uint8_t channelId, ChannelConfig& config) {
    if (!_prefs.begin(NVS_NS_CHANNELS, true)) return false;

    String kEn = _channelKey(channelId, "en");
    if (!_prefs.isKey(kEn.c_str())) {
        _prefs.end();
        return false;
    }

    config.channelId = channelId;
    config.enabled = _prefs.getBool(kEn.c_str(), channelId == 1);
    config.gpioPin = _prefs.getUChar(_channelKey(channelId, "pin").c_str(), 18);
    config.ledCount = _prefs.getUShort(_channelKey(channelId, "cnt").c_str(), channelId == 1 ? 1 : 0);
    config.maxBrightness = _prefs.getUChar(_channelKey(channelId, "mbr").c_str(), 255);

    String lType = _prefs.getString(_channelKey(channelId, "typ").c_str(), "WS2812B");
    strncpy(config.ledType, lType.c_str(), sizeof(config.ledType) - 1);
    config.ledType[sizeof(config.ledType) - 1] = '\0';

    String cOrder = _prefs.getString(_channelKey(channelId, "ord").c_str(), "GRB");
    strncpy(config.colorOrder, cOrder.c_str(), sizeof(config.colorOrder) - 1);
    config.colorOrder[sizeof(config.colorOrder) - 1] = '\0';

    _prefs.end();
    return true;
}

bool NvsStorage::saveChannelConfig(uint8_t channelId, const ChannelConfig& config) {
    if (!_prefs.begin(NVS_NS_CHANNELS, false)) return false;

    _prefs.putBool(_channelKey(channelId, "en").c_str(), config.enabled);
    _prefs.putUChar(_channelKey(channelId, "pin").c_str(), config.gpioPin);
    _prefs.putUShort(_channelKey(channelId, "cnt").c_str(), config.ledCount);
    _prefs.putUChar(_channelKey(channelId, "mbr").c_str(), config.maxBrightness);
    _prefs.putString(_channelKey(channelId, "typ").c_str(), config.ledType);
    _prefs.putString(_channelKey(channelId, "ord").c_str(), config.colorOrder);

    _prefs.end();
    return true;
}

bool NvsStorage::loadChannelState(uint8_t channelId, ChannelState& state) {
    if (!_prefs.begin(NVS_NS_CHANNELS, true)) return false;

    String kOn = _channelKey(channelId, "on");
    if (!_prefs.isKey(kOn.c_str())) {
        _prefs.end();
        return false;
    }

    state.isOn = _prefs.getBool(kOn.c_str(), true);
    state.primaryColor.r = _prefs.getUChar(_channelKey(channelId, "pr_r").c_str(), 108);
    state.primaryColor.g = _prefs.getUChar(_channelKey(channelId, "pr_g").c_str(), 99);
    state.primaryColor.b = _prefs.getUChar(_channelKey(channelId, "pr_b").c_str(), 255);

    state.secondaryColor.r = _prefs.getUChar(_channelKey(channelId, "sc_r").c_str(), 0);
    state.secondaryColor.g = _prefs.getUChar(_channelKey(channelId, "sc_g").c_str(), 210);
    state.secondaryColor.b = _prefs.getUChar(_channelKey(channelId, "sc_b").c_str(), 255);

    uint8_t effIdx = _prefs.getUChar(_channelKey(channelId, "eff").c_str(), 3); // Breathing default
    state.effectType = static_cast<EffectType>(effIdx < 20 ? effIdx : 0);

    state.brightness = _prefs.getUChar(_channelKey(channelId, "br").c_str(), 220);
    state.speed = _prefs.getUChar(_channelKey(channelId, "spd").c_str(), 55);
    state.direction = _prefs.getChar(_channelKey(channelId, "dir").c_str(), 1);
    state.intensity = _prefs.getUChar(_channelKey(channelId, "int").c_str(), 50);

    _prefs.end();
    return true;
}

bool NvsStorage::saveChannelState(uint8_t channelId, const ChannelState& state) {
    if (!_prefs.begin(NVS_NS_CHANNELS, false)) return false;

    _prefs.putBool(_channelKey(channelId, "on").c_str(), state.isOn);
    _prefs.putUChar(_channelKey(channelId, "pr_r").c_str(), state.primaryColor.r);
    _prefs.putUChar(_channelKey(channelId, "pr_g").c_str(), state.primaryColor.g);
    _prefs.putUChar(_channelKey(channelId, "pr_b").c_str(), state.primaryColor.b);

    _prefs.putUChar(_channelKey(channelId, "sc_r").c_str(), state.secondaryColor.r);
    _prefs.putUChar(_channelKey(channelId, "sc_g").c_str(), state.secondaryColor.g);
    _prefs.putUChar(_channelKey(channelId, "sc_b").c_str(), state.secondaryColor.b);

    _prefs.putUChar(_channelKey(channelId, "eff").c_str(), static_cast<uint8_t>(state.effectType));
    _prefs.putUChar(_channelKey(channelId, "br").c_str(), state.brightness);
    _prefs.putUChar(_channelKey(channelId, "spd").c_str(), state.speed);
    _prefs.putChar(_channelKey(channelId, "dir").c_str(), state.direction);
    _prefs.putUChar(_channelKey(channelId, "int").c_str(), state.intensity);

    _prefs.end();
    return true;
}

bool NvsStorage::resetAll() {
    bool ok1 = clearWiFiCredentials();

    if (_prefs.begin(NVS_NS_CHANNELS, false)) {
        _prefs.clear();
        _prefs.end();
    }
    if (_prefs.begin(NVS_NS_DEVICE, false)) {
        _prefs.clear();
        _prefs.end();
    }
    return ok1;
}
