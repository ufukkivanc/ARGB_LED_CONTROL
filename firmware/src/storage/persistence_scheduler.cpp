#include "persistence_scheduler.h"
#include "storage/nvs_storage.h"
#include "led/channel_manager.h"

static bool sameState(const ChannelState& a, const ChannelState& b) {
    return a.isOn == b.isOn &&
           a.primaryColor == b.primaryColor &&
           a.secondaryColor == b.secondaryColor &&
           a.effectType == b.effectType &&
           a.brightness == b.brightness &&
           a.speed == b.speed &&
           a.direction == b.direction &&
           a.intensity == b.intensity &&
           a.palette == b.palette;
}

PersistenceScheduler& PersistenceScheduler::instance() {
    static PersistenceScheduler s;
    return s;
}

void PersistenceScheduler::markStateDirty(uint8_t channelId) {
    if (channelId < 1 || channelId > MAX_CHANNELS) return;
    Slot& s = _slots[channelId - 1];
    uint32_t now = millis();
    if (!s.stateDirty) {
        s.stateDirty = true;
        s.firstDirty = now;
    }
    s.lastChange = now;
}

void PersistenceScheduler::markConfigDirty(uint8_t channelId, const ChannelConfig& cfg) {
    if (channelId < 1 || channelId > MAX_CHANNELS) return;
    Slot& s = _slots[channelId - 1];
    s.cfgToSave = cfg;
    s.cfgToSave.channelId = channelId;
    s.cfgDirty = true;
    s.cfgChange = millis();
}

bool PersistenceScheduler::hasPending() const {
    for (const auto& s : _slots) {
        if (s.stateDirty || s.cfgDirty) return true;
    }
    return false;
}

bool PersistenceScheduler::_flushState(uint8_t idx) {
    Slot& s = _slots[idx];
    s.stateDirty = false;

    LedChannel* ch = ChannelManager::instance().getChannel(idx + 1);
    if (ch == nullptr) return false;

    ChannelState cur = ch->getState();
    if (s.haveSaved && sameState(cur, s.lastSaved)) {
        _skippedCount++;
        return false;   // Değişmemiş: flash'a yazma
    }
    if (NvsStorage::instance().saveChannelState(idx + 1, cur)) {
        s.lastSaved = cur;
        s.haveSaved = true;
        _writeCount++;
        return true;
    }
    return false;
}

bool PersistenceScheduler::_flushConfig(uint8_t idx) {
    Slot& s = _slots[idx];
    s.cfgDirty = false;
    if (NvsStorage::instance().saveChannelConfig(idx + 1, s.cfgToSave)) {
        _writeCount++;
        return true;
    }
    return false;
}

void PersistenceScheduler::tick(uint32_t now) {
    for (uint8_t i = 0; i < MAX_CHANNELS; i++) {
        Slot& s = _slots[i];

        if (s.cfgDirty && now - s.cfgChange >= 100) {
            _flushConfig(i);
            return;   // tick başına tek yazma
        }

        if (s.stateDirty) {
            bool quiet = (now - s.lastChange) >= PERSIST_DEBOUNCE_MS;
            bool stale = (now - s.firstDirty) >= PERSIST_MAX_WAIT_MS;
            if (quiet || stale) {
                _flushState(i);
                return;
            }
        }
    }
}

void PersistenceScheduler::discardAll() {
    for (auto& s : _slots) {
        s.stateDirty = false;
        s.cfgDirty = false;
    }
}

void PersistenceScheduler::flushAll() {
    for (uint8_t i = 0; i < MAX_CHANNELS; i++) {
        if (_slots[i].cfgDirty) _flushConfig(i);
        if (_slots[i].stateDirty) _flushState(i);
    }
}
