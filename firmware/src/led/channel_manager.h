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

    // Kare süresi telemetrisi (salt okunur): render = efekt hesabı, show = LED çıkışının başlatılması (RMT).
    struct Perf {
        uint32_t renderUs = 0;   // son ~8 karenin ortalaması
        uint32_t showUs = 0;
        uint16_t fps = 0;        // saniyede çizilen kare (son tam saniye)
    };
    Perf perf() const { return _perf; }

private:
    ChannelManager();
    ~ChannelManager();

    std::vector<LedChannel*> _channels;
    uint32_t _lastFrameTime;
    const uint32_t _frameIntervalMs = 16; // ~60 FPS
    Perf _perf;
    uint32_t _fpsSince = 0;
    uint16_t _fpsFrames = 0;
};
