#include "channel_manager.h"

ChannelManager& ChannelManager::instance() {
    static ChannelManager manager;
    return manager;
}

ChannelManager::ChannelManager()
    : _lastFrameTime(0) {
    _channels.reserve(MAX_CHANNELS);
    for (uint8_t i = 1; i <= MAX_CHANNELS; i++) {
        _channels.push_back(new LedChannel(i));
    }
}

ChannelManager::~ChannelManager() {
    for (auto* ch : _channels) {
        delete ch;
    }
    _channels.clear();
}

bool ChannelManager::begin() {
    Serial.println("[ChannelManager] Initializing multi-channel LED architecture...");

    bool anyOk = false;
    for (auto* ch : _channels) {
        if (ch->begin()) {
            anyOk = true;
        }
    }

    _lastFrameTime = millis();
    Serial.printf("[ChannelManager] %d active channel(s) ready.\n", getActiveChannelCount());
    return anyOk;
}

LedChannel* ChannelManager::getChannel(uint8_t channelId) {
    if (channelId >= 1 && channelId <= _channels.size()) {
        return _channels[channelId - 1];
    }
    return nullptr;
}

size_t ChannelManager::getActiveChannelCount() const {
    size_t count = 0;
    for (const auto* ch : _channels) {
        if (ch->isEnabled() && ch->getLedCount() > 0) {
            count++;
        }
    }
    return count;
}

void ChannelManager::update() {
    uint32_t now = millis();

    // ── Non-blocking 60 FPS Frame Scheduler ────────────────────────────────
    if (now - _lastFrameTime < _frameIntervalMs) {
        return; // Not yet time for next frame
    }
    _lastFrameTime = now;

    // Render and refresh all active channels (süreler ölçülür: ortalama kare bütçesi ~16.6 ms)
    uint32_t renderUs = 0, showUs = 0;
    for (auto* ch : _channels) {
        if (ch->isEnabled() && ch->getLedCount() > 0) {
            uint32_t t0 = micros();
            AnimationEngine::instance().updateChannel(*ch, now);
            uint32_t t1 = micros();
            ch->show();
            uint32_t t2 = micros();
            renderUs += t1 - t0;
            showUs += t2 - t1;
        }
    }
    _perf.renderUs = (_perf.renderUs * 7 + renderUs) / 8;
    _perf.showUs = (_perf.showUs * 7 + showUs) / 8;
    _fpsFrames++;
    if (now - _fpsSince >= 1000) {
        _perf.fps = static_cast<uint16_t>((static_cast<uint32_t>(_fpsFrames) * 1000u) / (now - _fpsSince));
        _fpsFrames = 0;
        _fpsSince = now;
    }
}
