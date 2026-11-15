#pragma once

#include <Arduino.h>
#include "config.h"

// BOOT düğmesi (GPIO0) + durum LED'i (GPIO2).
//  - Düğme yalnızca boot SONRASINDA okunur; boot sırasında basılıysa bırakılana kadar yok sayılır
//    (ESP32 indirme modu davranışı bozulmaz; GPIO0 sadece INPUT_PULLUP'tır).
//  - 3 sn basılı tutup bırak  -> eşleştirme penceresi (120 sn)
//  - 10 sn basılı tut         -> güvenlik sıfırlaması (token + Wi-Fi bilgisi silinir, AP moduna dönülür)
//  - LED: eşleştirme açık = hızlı yanıp söner; kurulum AP'si aktif = yavaş yanıp söner;
//         3 sn eşiği aşıldı (bırak) = sabit yanar.
class ButtonManager {
public:
    static ButtonManager& instance();

    void begin();
    void update();

private:
    ButtonManager() = default;
    void _updateLed(uint32_t now, uint32_t heldMs);

    bool     _armed = false;
    bool     _raw = false;
    bool     _stable = false;
    uint32_t _rawChange = 0;
    uint32_t _pressStart = 0;
    bool     _resetFired = false;
    bool     _ledState = false;
};
