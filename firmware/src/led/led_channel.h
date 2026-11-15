#pragma once

#include <Arduino.h>
#define FASTLED_INTERNAL // Suppress FastLED pragma messages
#include <FastLED.h>
#include "types.h"
#include "config.h"
#include "storage/nvs_storage.h"

class LedChannel {
public:
    explicit LedChannel(uint8_t channelId);
    ~LedChannel();

    bool begin();
    void show();

    // ── Getters ────────────────────────────────────────────────────────────
    uint8_t getId() const { return _config.channelId; }
    bool isEnabled() const { return _config.enabled; }
    uint8_t getGpioPin() const { return _config.gpioPin; }
    uint16_t getLedCount() const { return _config.ledCount; }
    const char* getLedType() const { return _config.ledType; }
    const char* getColorOrder() const { return _config.colorOrder; }
    uint8_t getMaxBrightness() const { return _config.maxBrightness; }

    const ChannelConfig& getConfig() const { return _config; }
    const ChannelState& getState() const { return _state; }

    bool isOn() const { return _state.isOn; }
    RgbColor getColor() const { return _state.primaryColor; }
    RgbColor getSecondaryColor() const { return _state.secondaryColor; }
    EffectType getEffect() const { return _state.effectType; }
    uint8_t getBrightness() const { return _state.brightness; }
    uint8_t getSpeed() const { return _state.speed; }
    int8_t getDirection() const { return _state.direction; }
    uint8_t getIntensity() const { return _state.intensity; }

    CRGB* getLeds() { return _leds; }

    // ── Non-blocking State Controllers ─────────────────────────────────────
    // CRITICAL: Updating color or brightness never resets the animation progress!
    void setPower(bool on, bool save = true);
    void setColor(const RgbColor& color, bool save = true);
    void setSecondaryColor(const RgbColor& color, bool save = true);
    void setBrightness(uint8_t brightness, bool save = true);
    void setEffect(EffectType effect, bool save = true);
    void setSpeed(uint8_t speed, bool save = true);
    void setDirection(int8_t direction, bool save = true);
    void setIntensity(uint8_t intensity, bool save = true);

    void setConfig(const ChannelConfig& config, bool save = true);
    void setState(const ChannelState& state, bool save = true);

    // ── Animation Engine State Hooks ───────────────────────────────────────
    float getAnimProgress() const { return _animProgress; }
    void setAnimProgress(float progress) { _animProgress = progress; }
    uint32_t getLastTick() const { return _lastTickMs; }
    void setLastTick(uint32_t tick) { _lastTickMs = tick; }

    // Computes effective brightness combining channel brightness & maxBrightness cap
    uint8_t getEffectiveBrightness() const;

private:
    void _allocateLeds();
    void _freeLeds();
    void _initFastLedController();

    ChannelConfig _config;
    ChannelState _state;

    CRGB* _leds;
    CLEDController* _controller;

    float _animProgress;
    uint32_t _lastTickMs;
};
