#pragma once

#include <Arduino.h>
#include "led_channel.h"

// 20 efektin tamamını render eden, bloklamayan (delay yok) animasyon motoru.
//
// Zamanlama modeli (docs/PROTOCOL.md §3.5):
//   - speed 1..100  ->  periyot = max(200, 5000 - (speed-1)*4500/99) ms   (1: 5000 ms, 100: 500 ms)
//   - Animasyon fazı (progress, 0..1) dt/periyot kadar birikir; hız, renk, parlaklık veya
//     yoğunluk değişince faz SIFIRLANMAZ (sıçrama yok).
//   - direction = -1: faz geriye doğru akar (animasyon ters oynar).
//   - intensity 0..100: efekte göre anlam kazanır (bkz. tablo).
//
// Durum gerektiren efektler (fire, twinkle, sparkle, randomTransitions, musicReactive)
// kanal başına küçük bir tampon kullanır; tampon yalnızca ilgili efekt seçilince ayrılır.
class AnimationEngine {
public:
    static AnimationEngine& instance();

    void updateChannel(LedChannel& channel, uint32_t now);

    // Hız -> periyot (ms). Testlerde ve belgede aynı formül.
    static uint32_t periodMsForSpeed(uint8_t speed);

private:
    AnimationEngine() = default;

    struct FxState {
        uint8_t*   buf = nullptr;
        uint16_t   bufLen = 0;
        EffectType lastEffect = static_cast<EffectType>(255);
        uint32_t   acc = 0;
        float      lastP = 0.0f;
        float      beat = 0.0f;
        uint8_t    beatAmp = 255;
        CRGB       from;
        CRGB       to;
        bool       warned = false;
    };

    struct Params {
        CRGB*    leds;
        uint16_t n;
        CRGB     c1;
        CRGB     c2;
        uint8_t  intensity;
        uint32_t dt;
        uint32_t periodMs;
    };

    FxState _fx[MAX_CHANNELS];

    uint8_t* _buffer(FxState& fx, uint16_t bytes);

    void _renderStatic(const Params& a);
    void _renderBreathing(const Params& a, float p);
    void _renderPulsing(const Params& a, float p);
    void _renderRainbow(const Params& a, float p);
    void _renderRainbowCycle(const Params& a, float p);
    void _renderColorFade(const Params& a, float p);
    void _renderColorWipe(const Params& a, float p);
    void _renderRunningLights(const Params& a, float p);
    void _renderTheaterChase(const Params& a, float p);
    void _renderFire(const Params& a, FxState& fx);
    void _renderMeteor(const Params& a, float p);
    void _renderTwinkle(const Params& a, FxState& fx, bool sparkle);
    void _renderPolice(const Params& a, float p);
    void _renderWave(const Params& a, float p);
    void _renderGradientMove(const Params& a, float p);
    void _renderComet(const Params& a, float p);
    void _renderRandomTransitions(const Params& a, FxState& fx, float p);
    void _renderCustomGradient(const Params& a);
    void _renderMusic(const Params& a, FxState& fx);
};
