#pragma once

#include <Arduino.h>
#include <ESPmDNS.h>
#include "config.h"

class MdnsService {
public:
    static MdnsService& instance();

    bool begin(const String& hostname = MDNS_HOSTNAME);
    void update();

private:
    MdnsService() = default;
    bool _initialized = false;
};
