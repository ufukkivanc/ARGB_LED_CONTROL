#include "mdns_service.h"
#include <WiFi.h>
#include "device_id.h"

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
    return true;
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
