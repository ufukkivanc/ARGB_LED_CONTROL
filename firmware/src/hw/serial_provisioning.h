#pragma once

#include <Arduino.h>
#include "config.h"
#include "types.h"

// USB seri port üzerinden ilk Wi-Fi kurulumu (tools/serial_setup.py).
//
// Güvenlik:
//  - Wi-Fi bilgisi YALNIZCA fiziksel BOOT düğmesiyle açılan kısa süreli kurulum
//    penceresinde (SERIAL_SETUP_WINDOW_MS) kabul edilir; pencere kapalıyken `wifi`
//    komutu reddedilir.
//  - SSID/şifre hiçbir yere loglanmaz, geri yankılanmaz (echo yok).
//  - Başarılı kurulumda pencere kapanır; süre dolunca da kapanır.
//  - Satır uzunluğu sınırlıdır; yalnızca "ARGB:" ön ekli, JSON tabanlı satırlar üretilir.
//
// Protokol (satır tabanlı JSON, '\n' ile biter):
//   istek : {"cmd":"hello"} | {"cmd":"status"} | {"cmd":"scan"} | {"cmd":"wifi","ssid":"...","pass":"..."}
//   (scan ve wifi YALNIZCA kurulum penceresi açıkken kabul edilir)
//   yanıt : ARGB:{"v":1,"type":"hello|status|wifiAccepted|error|event",...}
class SerialProvisioning {
public:
    static SerialProvisioning& instance();

    void begin();
    void update();                                   // loop() içinde, bloklamaz

    void openWindow(uint32_t durationMs = SERIAL_SETUP_WINDOW_MS);
    void closeWindow();
    bool isOpen() const;
    uint32_t remainingMs() const;

private:
    SerialProvisioning() = default;

    void _handleLine(const char* line);
    void _replyError(const char* code);
    void _replyStatus(const char* type);
    void _event();
    void _updateScan();

    char _line[SERIAL_SETUP_MAX_LINE + 1];
    uint16_t _len = 0;
    bool _overflow = false;

    volatile bool _open = false;
    volatile uint32_t _until = 0;

    bool _scanning = false;
    uint32_t _scanStarted = 0;

    bool _watching = false;                           // wifi komutu kabul edildi, sonuç izleniyor
    WiFiConnectionState _lastReported = WiFiConnectionState::Disconnected;
};
