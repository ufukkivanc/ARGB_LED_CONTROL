#pragma once

#include <Arduino.h>
#include <vector>
#include "led_channel.h"
#include "animation_engine.h"
#include "config.h"

class ChannelManager {
public:
    static ChannelManager& instance();

    bool begin();
    void update(); // Called non-blockingly from main loop

    LedChannel* getChannel(uint8_t channelId);
    size_t getChannelCount() const { return MAX_CHANNELS; }
    size_t getActiveChannelCount() const;

private:
    ChannelManager();
    ~ChannelManager();

    std::vector<LedChannel*> _channels;
    uint32_t _lastFrameTime;
    const uint32_t _frameIntervalMs = 16; // ~60 FPS
};
