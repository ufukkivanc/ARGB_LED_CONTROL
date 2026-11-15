#pragma once

#include <Arduino.h>

// ── Wi-Fi Connection States ────────────────────────────────────────────────
enum class WiFiConnectionState : uint8_t {
    Disconnected       = 0,
    Connecting         = 1,
    Connected          = 2,
    ConnectionFailed   = 3,
    AccessPointActive  = 4
};

// ── Wi-Fi Network Scan Result ──────────────────────────────────────────────
struct DiscoveredNetwork {
    String ssid;
    int32_t rssi;
    String security;
    int32_t channel;
};

// ── LED Effect Types (Matches Flutter models/effect.dart 1:1) ─────────────
enum class EffectType : uint8_t {
    staticColor        = 0,
    rainbow            = 1,
    rainbowCycle       = 2,
    breathing          = 3,
    colorFade          = 4,
    colorWipe          = 5,
    runningLights      = 6,
    theaterChase       = 7,
    fire               = 8,
    meteorRain         = 9,
    twinkle            = 10,
    sparkle            = 11,
    policeLights       = 12,
    wave               = 13,
    gradientMove       = 14,
    comet              = 15,
    pulsing            = 16,
    randomTransitions  = 17,
    customGradient     = 18,
    musicReactive      = 19
};

inline const char* effectTypeToString(EffectType type) {
    switch (type) {
        case EffectType::staticColor:        return "staticColor";
        case EffectType::rainbow:            return "rainbow";
        case EffectType::rainbowCycle:       return "rainbowCycle";
        case EffectType::breathing:          return "breathing";
        case EffectType::colorFade:          return "colorFade";
        case EffectType::colorWipe:          return "colorWipe";
        case EffectType::runningLights:      return "runningLights";
        case EffectType::theaterChase:       return "theaterChase";
        case EffectType::fire:               return "fire";
        case EffectType::meteorRain:         return "meteorRain";
        case EffectType::twinkle:            return "twinkle";
        case EffectType::sparkle:            return "sparkle";
        case EffectType::policeLights:       return "policeLights";
        case EffectType::wave:               return "wave";
        case EffectType::gradientMove:       return "gradientMove";
        case EffectType::comet:              return "comet";
        case EffectType::pulsing:            return "pulsing";
        case EffectType::randomTransitions:  return "randomTransitions";
        case EffectType::customGradient:     return "customGradient";
        case EffectType::musicReactive:      return "musicReactive";
        default:                             return "staticColor";
    }
}

inline EffectType effectTypeFromString(const String& name) {
    if (name == "staticColor")        return EffectType::staticColor;
    if (name == "rainbow")            return EffectType::rainbow;
    if (name == "rainbowCycle")       return EffectType::rainbowCycle;
    if (name == "breathing")          return EffectType::breathing;
    if (name == "colorFade")          return EffectType::colorFade;
    if (name == "colorWipe")          return EffectType::colorWipe;
    if (name == "runningLights")      return EffectType::runningLights;
    if (name == "theaterChase")       return EffectType::theaterChase;
    if (name == "fire")               return EffectType::fire;
    if (name == "meteorRain")         return EffectType::meteorRain;
    if (name == "twinkle")            return EffectType::twinkle;
    if (name == "sparkle")            return EffectType::sparkle;
    if (name == "policeLights")       return EffectType::policeLights;
    if (name == "wave")               return EffectType::wave;
    if (name == "gradientMove")       return EffectType::gradientMove;
    if (name == "comet")              return EffectType::comet;
    if (name == "pulsing")            return EffectType::pulsing;
    if (name == "randomTransitions")  return EffectType::randomTransitions;
    if (name == "customGradient")     return EffectType::customGradient;
    if (name == "musicReactive")      return EffectType::musicReactive;
    return EffectType::staticColor;
}

// ── RGB Color Representation ───────────────────────────────────────────────
struct RgbColor {
    uint8_t r;
    uint8_t g;
    uint8_t b;

    constexpr RgbColor() : r(255), g(180), b(107) {} // Warm white default
    constexpr RgbColor(uint8_t red, uint8_t green, uint8_t blue) : r(red), g(green), b(blue) {}

    bool operator==(const RgbColor& o) const {
        return r == o.r && g == o.g && b == o.b;
    }
    bool operator!=(const RgbColor& o) const {
        return !(*this == o);
    }
};

// ── Channel Configuration ──────────────────────────────────────────────────
struct ChannelConfig {
    uint8_t channelId;
    bool enabled;
    uint8_t gpioPin;
    uint16_t ledCount;
    char ledType[16];
    char colorOrder[8];
    uint8_t maxBrightness;

    ChannelConfig()
        : channelId(1),
          enabled(true),
          gpioPin(18),
          ledCount(1),
          maxBrightness(255) {
        strncpy(ledType, "WS2812B", sizeof(ledType) - 1);
        ledType[sizeof(ledType) - 1] = '\0';
        strncpy(colorOrder, "GRB", sizeof(colorOrder) - 1);
        colorOrder[sizeof(colorOrder) - 1] = '\0';
    }
};

// ── Channel Runtime State ──────────────────────────────────────────────────
struct ChannelState {
    bool isOn;
    RgbColor primaryColor;
    RgbColor secondaryColor;
    EffectType effectType;
    uint8_t brightness;
    uint8_t speed;
    int8_t direction;
    uint8_t intensity;

    ChannelState()
        : isOn(true),
          primaryColor(108, 99, 255), // Neon purple default
          secondaryColor(0, 210, 255),
          effectType(EffectType::breathing),
          brightness(220),
          speed(55),
          direction(1),
          intensity(50) {}
};
