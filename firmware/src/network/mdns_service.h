#pragma once

#include <Arduino.h>
#include <ESPmDNS.h>
#include "config.h"

class MdnsService {
public:
    static MdnsService& instance();

    bool begin(const String& hostname = MDNS_HOSTNAME);
    void update();
    void setPaired(bool paired);
    void setWledAdvertised(bool on);   // _wled._tcp (WLED uygulaması keşfi); ENABLE_WLED_COMPAT
    bool isRunning() const { return _initialized; }

private:
    MdnsService() = default;
    bool _initialized = false;
    bool _paired = false;
    bool _wled = false;
};
