#pragma once

#include <Arduino.h>
#include "led_channel.h"

class AnimationEngine {
public:
    static AnimationEngine& instance();

    void updateChannel(LedChannel& channel, uint32_t now);

private:
    AnimationEngine() = default;

    void _renderStaticColor(LedChannel& channel);
    void _renderBreathing(LedChannel& channel, float progress);
    void _renderRainbow(LedChannel& channel, float progress);
    void _renderColorFade(LedChannel& channel, float progress);
};
