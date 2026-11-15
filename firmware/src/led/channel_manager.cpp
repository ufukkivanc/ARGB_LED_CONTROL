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

    // Render and refresh all active channels
    for (auto* ch : _channels) {
        if (ch->isEnabled() && ch->getLedCount() > 0) {
            AnimationEngine::instance().updateChannel(*ch, now);
            ch->show();
        }
    }
}
