#pragma once

// Palet (1–5 renk) tabanlı efekt çizici — SAF C++ (Arduino/FastLED'e bağlı değil; ana bilgisayarda test edilir).
//
// Palet boşken (n == 0) bu modül HİÇ çağrılmaz: mevcut 20 efektin orijinal çizimi (animation_engine.cpp) aynen çalışır.
// Palet doluyken efektler yalnızca palet renklerini kullanır (hangi efektin paleti nasıl kullandığı: docs/PROTOCOL.md §3.6).
//
// Zamanlama modeli animation_engine ile aynıdır: `p` (0..1) faz, `cycle` faz her sarıldığında artan sayaç.
// Palet değişince faz/sayaç SIFIRLANMAZ; animasyon kesilmez.
#include <stdint.h>

namespace palfx {

constexpr int kMaxColors = 5;

struct Rgb {
    uint8_t r, g, b;   // (C++11 uyumlu toplu ilkleme için varsayılan üye değeri YOK)
};

struct Pal {
    uint8_t n = 0;        // 0..5
    Rgb c[kMaxColors];
};

// Efekt başına durum (twinkle/sparkle/fire tamponları, rastgele geçiş hedefleri...)
struct State {
    uint8_t* buf = nullptr;
    uint16_t bufLen = 0;
    uint32_t acc = 0;
    float beat = 0.0f;
    uint8_t beatAmp = 255;
    Rgb from, to;
    float lastP = 0.0f;
    uint32_t rng = 0x9E3779B9u;
    bool primed = false;
};

struct In {
    Rgb* out;               // n piksel
    uint16_t n;             // LED sayısı (1..)
    const Pal* pal;         // pal->n >= 1
    uint8_t effect;         // EffectType (0..19)
    float p;                // faz 0..1
    uint32_t cycle;         // faz sarma sayacı
    uint8_t intensity;      // 0..100
    uint32_t dt;            // ms (durumlu efektler için)
    uint32_t periodMs;      // hız periyodu
};

void resetState(State& s);                    // tamponu serbest bırakır, durumu sıfırlar
void render(const In& in, State& s);          // out[0..n) yazar. Taşma yok; n==0 ise hiçbir şey yapmaz.

// Test/yardımcı: paleti 0..1 aralığında örnekler.
Rgb sampleCircular(const Pal& pal, float t);  // t sarmal (son renk ilk renge geçer)
Rgb sampleLinear(const Pal& pal, float t);    // t 0..1 (son renk son renktir)

}  // namespace palfx
