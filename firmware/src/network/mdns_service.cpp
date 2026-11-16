#include "mdns_service.h"
#include <WiFi.h>
#include "device_id.h"
#include <mdns.h>
#if ENABLE_WLED_COMPAT
#include "wled/wled_compat.h"
#endif

MdnsService& MdnsService::instance() {
    static MdnsService service;
    return service;
}

bool MdnsService::begin(const String& hostname) {
    if (_initialized) {
        MDNS.end();
        _initialized = false;
    }

    if (!MDNS.begin(hostname.c_str())) {
        Serial.println("[mDNS] Error setting up MDNS responder!");
        return false;
    }

    Serial.printf("[mDNS] Responder started: http://%s.local\n", hostname.c_str());

    // Advertise services
    MDNS.addService("http", "tcp", HTTP_PORT);
    MDNS.addServiceTxt("http", "tcp", "version", FIRMWARE_VERSION);
    MDNS.addServiceTxt("http", "tcp", "model", DEVICE_MODEL);
    MDNS.addServiceTxt("http", "tcp", "id", getDeviceId());
    MDNS.addServiceTxt("http", "tcp", "proto", String(API_PROTO_VERSION));
    MDNS.addServiceTxt("http", "tcp", "paired", _paired ? "1" : "0");

    MDNS.addService("ws", "tcp", HTTP_PORT);
    MDNS.addServiceTxt("ws", "tcp", "endpoint", WS_ENDPOINT);

    _initialized = true;
#if ENABLE_WLED_COMPAT
    // WLED uygulaması _wled._tcp servisini tarar; yalnızca erişim modu KAPALI değilse yayınlanır.
    _wled = false;
    setWledAdvertised(WledCompat::instance().enabled());
#endif
    return true;
}

void MdnsService::setWledAdvertised(bool on) {
#if ENABLE_WLED_COMPAT
    if (!_initialized) { _wled = on; return; }
    if (on == _wled) return;
    _wled = on;
    if (on) {
        String mac = WiFi.macAddress();
        mac.replace(":", "");
        mac.toLowerCase();
        MDNS.addService("wled", "tcp", HTTP_PORT);
        MDNS.addServiceTxt("wled", "tcp", "mac", mac);   // WLED uygulaması cihaz kimliği için kullanır
        Serial.println("[mDNS] _wled._tcp advertised (WLED compatibility ON).");
    } else {
        mdns_service_remove("_wled", "_tcp");
        Serial.println("[mDNS] _wled._tcp removed (WLED compatibility OFF).");
    }
#else
    (void)on;
#endif
}

void MdnsService::setPaired(bool paired) {
    _paired = paired;
    if (_initialized) {
        MDNS.addServiceTxt("http", "tcp", "paired", paired ? "1" : "0");
    }
}

void MdnsService::update() {
    // Under ESP32 Arduino core, mDNS operates asynchronously via lwIP.
}
