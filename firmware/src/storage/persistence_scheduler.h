#pragma once

#include <Arduino.h>
#include "types.h"
#include "config.h"

// NVS yazımlarını dirty-flag + debounce ile toplar.
//  - Yalnızca loop() (core 1) bağlamında kullanılır; kilit gerektirmez.
//  - Durum: son değişiklikten PERSIST_DEBOUNCE_MS sonra veya ilk kirlenmeden
//    PERSIST_MAX_WAIT_MS sonra (hangisi önce) yazılır.
//  - Yapılandırma: nadir değiştiği için kısa debounce (anında sayılır).
//  - Değişmemiş değer (son kaydedilenle aynı) yazılmaz.
//  - Bir tick'te en çok bir yazma yapılır (loop gecikmesini dağıtmak için).
class PersistenceScheduler {
public:
    static PersistenceScheduler& instance();

    void markStateDirty(uint8_t channelId);
    void markConfigDirty(uint8_t channelId, const ChannelConfig& cfg);

    void tick(uint32_t now);
    void flushAll();
    void discardAll();   // fabrika sıfırlama: bekleyen yazımları at

    bool hasPending() const;
    uint32_t writeCount() const { return _writeCount; }
    uint32_t skippedCount() const { return _skippedCount; }

private:
    PersistenceScheduler() = default;

    struct Slot {
        bool          stateDirty = false;
        uint32_t      lastChange = 0;
        uint32_t      firstDirty = 0;
        bool          haveSaved = false;
        ChannelState  lastSaved;

        bool          cfgDirty = false;
        uint32_t      cfgChange = 0;
        ChannelConfig cfgToSave;
    };

    bool _flushState(uint8_t idx);
    bool _flushConfig(uint8_t idx);

    Slot _slots[MAX_CHANNELS];
    uint32_t _writeCount = 0;
    uint32_t _skippedCount = 0;
};
