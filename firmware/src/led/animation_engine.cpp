#include "animation_engine.h"
#include <cmath>

AnimationEngine& AnimationEngine::instance() {
    static AnimationEngine engine;
    return engine;
}

void AnimationEngine::updateChannel(LedChannel& channel, uint32_t now) {
    if (!channel.isEnabled() || channel.getLedCount() == 0 || channel.getLeds() == nullptr) {
        return;
    }

    CRGB* leds = channel.getLeds();
    uint16_t count = channel.getLedCount();

    // If power is OFF, immediately render pure black
    if (!channel.isOn()) {
        for (uint16_t i = 0; i < count; i++) {
            leds[i] = CRGB::Black;
        }
        return;
    }

    // ── Non-blocking Animation Progress Calculation ────────────────────────
    uint32_t dt = now - channel.getLastTick();
    channel.setLastTick(now);

    // Speed 1 (slow, 5000ms period) -> Speed 100 (fast, 500ms period)
    uint8_t speed = channel.getSpeed();
    uint32_t durationMs = 5000 - ((speed - 1) * 4500 / 99);
    if (durationMs < 200) durationMs = 200;

    float progress = channel.getAnimProgress();
    if (dt > 0 && dt < 1000) { // Discard giant timing steps
        float step = static_cast<float>(dt) / static_cast<float>(durationMs);
        if (channel.getDirection() < 0) {
            progress -= step;
            if (progress < 0.0f) progress += 1.0f;
        } else {
            progress += step;
            if (progress >= 1.0f) progress -= 1.0f;
        }
        channel.setAnimProgress(progress);
    }

    // ── Render Active Effect ───────────────────────────────────────────────
    switch (channel.getEffect()) {
        case EffectType::staticColor:
            _renderStaticColor(channel);
            break;

        case EffectType::breathing:
        case EffectType::pulsing:
            _renderBreathing(channel, progress);
            break;

        case EffectType::rainbow:
        case EffectType::rainbowCycle:
            _renderRainbow(channel, progress);
            break;

        case EffectType::colorFade:
            _renderColorFade(channel, progress);
            break;

        default:
            // Fallback for effects scheduled for later multi-LED expansion
            _renderStaticColor(channel);
            break;
    }
}

void AnimationEngine::_renderStaticColor(LedChannel& channel) {
    CRGB* leds = channel.getLeds();
    uint16_t count = channel.getLedCount();
    RgbColor c = channel.getColor();

    CRGB target(c.r, c.g, c.b);
    for (uint16_t i = 0; i < count; i++) {
        leds[i] = target;
    }
}

void AnimationEngine::_renderBreathing(LedChannel& channel, float progress) {
    CRGB* leds = channel.getLeds();
    uint16_t count = channel.getLedCount();
    RgbColor c = channel.getColor();

    // Smooth sinusoidal breathing curve: [0.08 .. 1.0]
    float breathe = (sinf(progress * 2.0f * static_cast<float>(PI)) + 1.0f) * 0.5f;
    float minDim = 0.08f;
    float factor = minDim + (1.0f - minDim) * breathe;

    CRGB target(
        static_cast<uint8_t>(c.r * factor),
        static_cast<uint8_t>(c.g * factor),
        static_cast<uint8_t>(c.b * factor)
    );

    for (uint16_t i = 0; i < count; i++) {
        leds[i] = target;
    }
}

void AnimationEngine::_renderRainbow(LedChannel& channel, float progress) {
    CRGB* leds = channel.getLeds();
    uint16_t count = channel.getLedCount();

    uint8_t baseHue = static_cast<uint8_t>(progress * 255.0f);
    uint8_t deltaHue = count > 1 ? (255 / count) : 0;

    for (uint16_t i = 0; i < count; i++) {
        leds[i] = CHSV(baseHue + (i * deltaHue), 255, 255);
    }
}

void AnimationEngine::_renderColorFade(LedChannel& channel, float progress) {
    CRGB* leds = channel.getLeds();
    uint16_t count = channel.getLedCount();
    RgbColor p = channel.getColor();
    RgbColor s = channel.getSecondaryColor();

    CRGB colorA(p.r, p.g, p.b);
    CRGB colorB(s.r, s.g, s.b);

    // Sinusoidal ping-pong blend between primary and secondary colors
    float blendVal = (sinf(progress * 2.0f * static_cast<float>(PI)) + 1.0f) * 0.5f;
    uint8_t amount = static_cast<uint8_t>(blendVal * 255.0f);

    CRGB target = blend(colorA, colorB, amount);
    for (uint16_t i = 0; i < count; i++) {
        leds[i] = target;
    }
}
