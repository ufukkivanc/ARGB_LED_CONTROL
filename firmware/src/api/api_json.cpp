#include "api_json.h"
#include "device_id.h"
#include <WiFi.h>

namespace ApiJson {

// Stage 6: 20 efektin tamamı render edilir (types.h sırasıyla).
const char* const SUPPORTED_EFFECTS[] = {
    "staticColor", "rainbow", "rainbowCycle", "breathing", "colorFade", "colorWipe",
    "runningLights", "theaterChase", "fire", "meteorRain", "twinkle", "sparkle",
    "policeLights", "wave", "gradientMove", "comet", "pulsing", "randomTransitions",
    "customGradient", "musicReactive"
};
const size_t SUPPORTED_EFFECTS_COUNT = sizeof(SUPPORTED_EFFECTS) / sizeof(SUPPORTED_EFFECTS[0]);

bool parseEffectName(const char* name, EffectType& out) {
    if (name == nullptr) return false;
    for (uint8_t i = 0; i < 20; i++) {
        EffectType t = static_cast<EffectType>(i);
        if (strcmp(effectTypeToString(t), name) == 0) {
            out = t;
            return true;
        }
    }
    return false;
}

static void writeColor(JsonObject o, const char* key, const RgbColor& c) {
    JsonObject co = o[key].to<JsonObject>();
    co["r"] = c.r;
    co["g"] = c.g;
    co["b"] = c.b;
}

void writeChannel(JsonObject o, const ChannelSnapshot& c, uint8_t channelId) {
    o["ch"] = channelId;
    o["enabled"] = c.cfg.enabled;
    o["ledCount"] = c.cfg.ledCount;
    o["power"] = c.st.isOn;
    writeColor(o, "color", c.st.primaryColor);
    writeColor(o, "color2", c.st.secondaryColor);
    o["effect"] = effectTypeToString(c.st.effectType);
    o["brightness"] = c.st.brightness;
    o["speed"] = c.st.speed;
    o["direction"] = c.st.direction;
    o["intensity"] = c.st.intensity;
    JsonArray pal = o["palette"].to<JsonArray>();   // [] = palet yok (efektler varsayılan renkleri kullanır)
    for (uint8_t i = 0; i < c.st.palette.n && i < PALETTE_MAX_COLORS; i++) {
        JsonObject co = pal.add<JsonObject>();
        co["r"] = c.st.palette.c[i].r;
        co["g"] = c.st.palette.c[i].g;
        co["b"] = c.st.palette.c[i].b;
    }
    if (c.hasPending) {
        JsonObject p = o["pendingConfig"].to<JsonObject>();
        p["enabled"] = c.pending.enabled;
        p["ledCount"] = c.pending.ledCount;
        p["colorOrder"] = c.pending.colorOrder;
        p["maxBrightness"] = c.pending.maxBrightness;
        o["rebootRequired"] = true;
    }
}

String buildState(const Snapshot& s, uint8_t channelMask, bool partial) {
    JsonDocument doc;
    doc["v"] = API_PROTO_VERSION;
    doc["type"] = "state";
    doc["rev"] = s.rev;
    if (partial) doc["partial"] = true;
    JsonArray arr = doc["channels"].to<JsonArray>();
    for (uint8_t i = 0; i < MAX_CHANNELS; i++) {
        if (channelMask & (1 << i)) {
            writeChannel(arr.add<JsonObject>(), s.ch[i], i + 1);
        }
    }
    String out;
    serializeJson(doc, out);
    return out;
}

const char* wifiStateString(WiFiConnectionState st) {
    switch (st) {
        case WiFiConnectionState::Disconnected:      return "disconnected";
        case WiFiConnectionState::Connecting:        return "connecting";
        case WiFiConnectionState::Connected:         return "connected";
        case WiFiConnectionState::ConnectionFailed:  return "failed";
        case WiFiConnectionState::AccessPointActive: return "ap";
        default:                                     return "unknown";
    }
}

const char* wifiModeString(const WifiSnapshot& w) {
    bool sta = (w.state == WiFiConnectionState::Connected);
    if (sta && w.apActive) return "ap+sta";
    if (sta) return "sta";
    if (w.apActive) return "ap";
    return "offline";
}

String buildInfo(const Snapshot& s, const char* deviceName) {
    JsonDocument doc;
    doc["v"] = API_PROTO_VERSION;
    doc["type"] = "info";
    doc["deviceId"] = getDeviceId();
    doc["name"] = deviceName;
    doc["model"] = DEVICE_MODEL;
    doc["fw"] = FIRMWARE_VERSION;
    doc["proto"] = API_PROTO_VERSION;
    doc["mac"] = WiFi.macAddress();
    doc["maxChannels"] = MAX_CHANNELS;
    doc["maxLedsPerChannel"] = MAX_LEDS_PER_CHANNEL;
    doc["maxTotalLeds"] = MAX_TOTAL_LEDS;
    doc["warnLedsPerChannel"] = LED_WARN_PER_CHANNEL;   // üstünde kare hızı düşebilir (yalnızca uyarı)
    doc["warnTotalLeds"] = LED_WARN_TOTAL;
    doc["maxPaletteColors"] = PALETTE_MAX_COLORS;
    JsonArray feat = doc["features"].to<JsonArray>();
    feat.add("palette");
#if LIVE_LED_RESIZE
    feat.add("liveLedCount");
#endif

    JsonArray fx = doc["supportedEffects"].to<JsonArray>();
    for (size_t i = 0; i < SUPPORTED_EFFECTS_COUNT; i++) fx.add(SUPPORTED_EFFECTS[i]);

    JsonObject w = doc["wifi"].to<JsonObject>();
    w["mode"] = wifiModeString(s.wifi);
    w["state"] = wifiStateString(s.wifi.state);
    if (s.wifi.state == WiFiConnectionState::Connected) {
        w["ssid"] = s.wifi.ssid;
        w["rssi"] = s.wifi.rssi;
        w["ip"] = s.wifi.ip;
    }

    doc["uptimeMs"] = s.uptimeMs;
    doc["freeHeap"] = s.freeHeap;
    JsonObject perf = doc["perf"].to<JsonObject>();   // kare süresi telemetrisi (salt okunur)
    perf["fps"] = s.fps;
    perf["renderUs"] = s.renderUs;
    perf["showUs"] = s.showUs;

    JsonArray cfgs = doc["channelConfigs"].to<JsonArray>();
    for (uint8_t i = 0; i < MAX_CHANNELS; i++) {
        const ChannelConfig& c = s.ch[i].cfg;
        JsonObject o = cfgs.add<JsonObject>();
        o["ch"] = i + 1;
        o["enabled"] = c.enabled;
        o["ledCount"] = c.ledCount;
        o["ledType"] = c.ledType;
        o["colorOrder"] = c.colorOrder;
        o["maxBrightness"] = c.maxBrightness;
        o["gpio"] = c.gpioPin;
        if (s.ch[i].hasPending) {
            JsonObject p = o["pending"].to<JsonObject>();
            p["enabled"] = s.ch[i].pending.enabled;
            p["ledCount"] = s.ch[i].pending.ledCount;
            p["colorOrder"] = s.ch[i].pending.colorOrder;
        }
    }

    String out;
    serializeJson(doc, out);
    return out;
}

String buildAck(const char* reqId, uint32_t rev, bool rebootRequired) {
    JsonDocument doc;
    doc["v"] = API_PROTO_VERSION;
    doc["type"] = "ack";
    if (reqId && reqId[0]) doc["id"] = reqId;
    doc["rev"] = rev;
    if (rebootRequired) doc["rebootRequired"] = true;
    String out;
    serializeJson(doc, out);
    return out;
}

String buildError(const char* reqId, const ErrorInfo& err) {
    JsonDocument doc;
    doc["v"] = API_PROTO_VERSION;
    doc["type"] = "error";
    if (reqId && reqId[0]) doc["id"] = reqId;
    doc["code"] = apiErrorName(err.code);
    if (err.field[0]) doc["field"] = err.field;
    if (err.message[0]) doc["message"] = err.message;
    String out;
    serializeJson(doc, out);
    return out;
}

String buildPong() {
    JsonDocument doc;
    doc["v"] = API_PROTO_VERSION;
    doc["type"] = "pong";
    doc["t"] = millis();
    String out;
    serializeJson(doc, out);
    return out;
}

}  // namespace ApiJson
