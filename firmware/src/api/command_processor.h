#pragma once

#include <Arduino.h>
#include "command.h"
#include "snapshot.h"

// loop() (core 1) tarafı: komut kuyruğunu boşaltır, LED/Wi-Fi/NVS işlemlerini yürütür,
// snapshot üretir ve değişen durumu WebSocket istemcilerine yayınlar.
// "Tek yazar" kuralı: LED durumunu yalnızca bu sınıf (ve main loop) değiştirir.
class CommandProcessor {
public:
    static CommandProcessor& instance();

    void begin();
    bool enqueue(const Command& cmd);   // her çekirdekten çağrılabilir; bloklamaz
    void update();                       // her loop() turunda

    // Düğme/yerel olaylar (core 1)
    void securityReset();                // token'lar + Wi-Fi bilgisi silinir, AP moduna dönülür
    void scheduleReboot(uint32_t delayMs = 600);

    uint32_t droppedCommands() const { return _dropped; }
    uint32_t processedCommands() const { return _processed; }

private:
    CommandProcessor() = default;

    void _apply(Command& cmd);
    void _applySet(const Command& cmd);
    void _applyConfig(const Command& cmd);
    void _applyWifiConnect(Command& cmd);
    void _refreshSnapshot(bool force);
    void _updateScan(uint32_t now);
    void _broadcastChanges(uint32_t now);
    void _sendAck(const Command& cmd, bool rebootRequired);
    void _sendError(const Command& cmd, const ErrorInfo& err);
    void _factoryReset();

    QueueHandle_t _queue = nullptr;

    uint32_t _rev = 0;
    uint8_t  _changedMask = 0;
    uint32_t _lastBroadcast = 0;
    uint32_t _lastSnapshot = 0;
    uint32_t _rebootAt = 0;
    bool     _rebootScheduled = false;
    size_t   _lastTokenCount = 0xFF;

    // Bekleyen (yeniden başlatma gerektiren) yapılandırmalar
    bool          _hasPending[MAX_CHANNELS] = {};
    ChannelConfig _pending[MAX_CHANNELS];

    // Wi-Fi tarama
    bool     _scanRunning = false;
    uint32_t _scanStarted = 0;

    uint32_t _dropped = 0;
    uint32_t _processed = 0;
};
