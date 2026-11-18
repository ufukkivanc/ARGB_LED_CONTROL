#pragma once

#include <Arduino.h>
#include "types.h"
#include "config.h"

// Core 1 (loop) tarafından üretilen, core 0 (async) tarafından okunan salt-okunur
// durum görüntüsü. LED/Wi-Fi nesnelerine core 0'dan doğrudan erişilmez.

struct ChannelSnapshot {
    ChannelConfig cfg;          // canlı yapılandırma
    ChannelState  st;           // canlı durum
    bool          hasPending;   // yeniden başlatma bekleyen yapılandırma var mı
    ChannelConfig pending;
};

struct WifiSnapshot {
    WiFiConnectionState state;
    bool   apActive;
    char   ssid[33];
    char   ip[16];
    int16_t rssi;
    char   error[16];           // "", auth_failed, not_found, timeout
};

struct Snapshot {
    uint32_t        rev;
    ChannelSnapshot ch[MAX_CHANNELS];
    WifiSnapshot    wifi;
    uint32_t        uptimeMs;
    uint32_t        freeHeap;
    uint16_t        fps;          // ölçülen LED kare hızı
    uint32_t        renderUs;     // ortalama efekt hesabı süresi / kare
    uint32_t        showUs;       // ortalama LED çıkış süresi / kare
};

struct ScanNetwork {
    char    ssid[33];
    int8_t  rssi;
    uint8_t channel;
    char    security[16];
};

enum class ScanStatus : uint8_t { Idle, Running, Done };

struct ScanSnapshot {
    ScanStatus  status;
    bool        failed;     // Done + tüm denemeler başarısız (count = 0)
    uint8_t     count;
    ScanNetwork nets[SCAN_MAX_RESULTS];
};

class SnapshotStore {
public:
    static SnapshotStore& instance();
    void begin();

    void setState(const Snapshot& s);
    void getState(Snapshot& out);

    void setScan(const ScanSnapshot& s);
    void getScan(ScanSnapshot& out);
    ScanStatus getScanStatus();

private:
    SnapshotStore() = default;
    SemaphoreHandle_t _mutex = nullptr;
    Snapshot _state{};
    ScanSnapshot _scan{};
};
