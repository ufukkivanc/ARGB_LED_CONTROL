#include "button_manager.h"
#include "auth/auth_manager.h"
#include "api/command_processor.h"
#include "hw/serial_provisioning.h"
#include "network/wifi_manager.h"

ButtonManager& ButtonManager::instance() {
    static ButtonManager b;
    return b;
}

void ButtonManager::begin() {
    pinMode(PAIR_BUTTON_GPIO, INPUT_PULLUP);
    pinMode(STATUS_LED_GPIO, OUTPUT);
    digitalWrite(STATUS_LED_GPIO, LOW);
    _armed = false;
}

void ButtonManager::update() {
    uint32_t now = millis();
    bool pressed = (digitalRead(PAIR_BUTTON_GPIO) == LOW);

    // 30 ms debounce
    if (pressed != _raw) {
        _raw = pressed;
        _rawChange = now;
    }
    if ((now - _rawChange) >= 30) {
        _stable = _raw;
    }

    // Boot sırasında basılı kalmışsa bırakılana kadar silahlandırma
    if (!_armed) {
        if (!_stable) _armed = true;
        _updateLed(now, 0);
        return;
    }

    uint32_t held = 0;
    if (_stable) {
        if (_pressStart == 0) _pressStart = now;
        held = now - _pressStart;
        if (held >= SECURITY_RESET_HOLD_MS && !_resetFired) {
            _resetFired = true;
            CommandProcessor::instance().securityReset();
        }
    } else {
        if (_pressStart != 0) {
            uint32_t heldTotal = now - _pressStart;
            if (heldTotal >= PAIR_BUTTON_HOLD_MS && !_resetFired) {
                AuthManager::instance().openPairingWindow();
                SerialProvisioning::instance().openWindow();   // USB seri kurulum penceresi (fiziksel onay)
            }
        }
        _pressStart = 0;
        _resetFired = false;
    }

    _updateLed(now, held);
}

void ButtonManager::_updateLed(uint32_t now, uint32_t heldMs) {
    bool on = false;
    if (heldMs >= PAIR_BUTTON_HOLD_MS && heldMs < SECURITY_RESET_HOLD_MS) {
        on = true;                                   // "bırakabilirsin" geri bildirimi
    } else if (AuthManager::instance().isPairingOpen()) {
        on = ((now / 150) % 2) == 0;                 // hızlı yanıp sönme
    } else if (WiFiManager::instance().isApActive()) {
        on = ((now / 500) % 2) == 0;                 // yavaş yanıp sönme
    }
    if (on != _ledState) {
        _ledState = on;
        digitalWrite(STATUS_LED_GPIO, on ? HIGH : LOW);
    }
}
