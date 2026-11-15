#include "animation_engine.h"
#include <cmath>

static const float kTwoPi = 6.28318530718f;

static inline float frac(float x) { return x - floorf(x); }
static inline float clamp01(float x) { return x < 0.0f ? 0.0f : (x > 1.0f ? 1.0f : x); }
static inline uint8_t toU8(float v) { return v <= 0.0f ? 0 : (v >= 255.0f ? 255 : static_cast<uint8_t>(v)); }

static inline CRGB scaled(CRGB c, float f) {
    f = clamp01(f);
    c.nscale8(static_cast<uint8_t>(f * 255.0f));
    return c;
}

// Soluk zemin rengi (twinkle/sparkle/theaterChase)
static inline CRGB dimBg(CRGB c) {
    c.nscale8(40);
    return c;
}

// Periyodik (0..1 sarmalı) çan eğrisi
static float bump(float t, float center, float width) {
    float d = t - center;
    if (d > 0.5f) d -= 1.0f;
    if (d < -0.5f) d += 1.0f;
    return expf(-(d * d) / (2.0f * width * width));
}

AnimationEngine& AnimationEngine::instance() {
    static AnimationEngine engine;
    return engine;
}

uint32_t AnimationEngine::periodMsForSpeed(uint8_t speed) {
    if (speed < 1) speed = 1;
    if (speed > 100) speed = 100;
    uint32_t ms = 5000 - (static_cast<uint32_t>(speed - 1) * 4500 / 99);
    return ms < 200 ? 200 : ms;
}

uint8_t* AnimationEngine::_buffer(FxState& fx, uint16_t bytes) {
    if (fx.buf == nullptr || fx.bufLen < bytes) {
        free(fx.buf);
        fx.buf = static_cast<uint8_t*>(calloc(bytes, 1));
        fx.bufLen = fx.buf ? bytes : 0;
    }
    return fx.buf;
}

// ════════════════════════════════════════════════════════════════════════════
//  Ana güncelleme
// ════════════════════════════════════════════════════════════════════════════

void AnimationEngine::updateChannel(LedChannel& channel, uint32_t now) {
    if (!channel.isEnabled() || channel.getLedCount() == 0 || channel.getLeds() == nullptr) {
        return;
    }

    CRGB* leds = channel.getLeds();
    uint16_t count = channel.getLedCount();

    // Güç KAPALI: siyah
    if (!channel.isOn()) {
        for (uint16_t i = 0; i < count; i++) leds[i] = CRGB::Black;
        channel.setLastTick(now);   // açılışta büyük dt birikmesin
        return;
    }

    // ── Bloklamayan faz hesabı ─────────────────────────────────────────────
    uint32_t dt = now - channel.getLastTick();
    channel.setLastTick(now);

    uint32_t periodMs = periodMsForSpeed(channel.getSpeed());
    float progress = channel.getAnimProgress();
    if (dt > 0 && dt < 1000) {   // devasa zaman adımlarını yut
        float step = static_cast<float>(dt) / static_cast<float>(periodMs);
        if (channel.getDirection() < 0) {
            progress -= step;
            if (progress < 0.0f) progress += 1.0f;
        } else {
            progress += step;
            if (progress >= 1.0f) progress -= 1.0f;
        }
        channel.setAnimProgress(progress);
    } else if (dt >= 1000) {
        dt = 16;
    }

    RgbColor p = channel.getColor();
    RgbColor s = channel.getSecondaryColor();
    Params a;
    a.leds = leds;
    a.n = count;
    a.c1 = CRGB(p.r, p.g, p.b);
    a.c2 = CRGB(s.r, s.g, s.b);
    a.intensity = channel.getIntensity() > 100 ? 100 : channel.getIntensity();
    a.dt = dt;
    a.periodMs = periodMs;

    uint8_t idx = channel.getId() - 1;
    if (idx >= MAX_CHANNELS) idx = 0;
    FxState& fx = _fx[idx];
    EffectType effect = channel.getEffect();

    // Efekt değişince durumlu efektlerin tamponunu temizle
    if (fx.lastEffect != effect) {
        fx.lastEffect = effect;
        if (fx.buf) memset(fx.buf, 0, fx.bufLen);
        fx.acc = 0;
        fx.beat = 0.0f;
        fx.lastP = progress;
        fx.from = a.c1;
        fx.to = a.c1;
        fx.warned = false;
    }

    switch (effect) {
        case EffectType::staticColor:       _renderStatic(a); break;
        case EffectType::rainbow:           _renderRainbow(a, progress); break;
        case EffectType::rainbowCycle:      _renderRainbowCycle(a, progress); break;
        case EffectType::breathing:         _renderBreathing(a, progress); break;
        case EffectType::colorFade:         _renderColorFade(a, progress); break;
        case EffectType::colorWipe:         _renderColorWipe(a, progress); break;
        case EffectType::runningLights:     _renderRunningLights(a, progress); break;
        case EffectType::theaterChase:      _renderTheaterChase(a, progress); break;
        case EffectType::fire:              _renderFire(a, fx); break;
        case EffectType::meteorRain:        _renderMeteor(a, progress); break;
        case EffectType::twinkle:           _renderTwinkle(a, fx, false); break;
        case EffectType::sparkle:           _renderTwinkle(a, fx, true); break;
        case EffectType::policeLights:      _renderPolice(a, progress); break;
        case EffectType::wave:              _renderWave(a, progress); break;
        case EffectType::gradientMove:      _renderGradientMove(a, progress); break;
        case EffectType::comet:             _renderComet(a, progress); break;
        case EffectType::pulsing:           _renderPulsing(a, progress); break;
        case EffectType::randomTransitions: _renderRandomTransitions(a, fx, progress); break;
        case EffectType::customGradient:    _renderCustomGradient(a); break;
        case EffectType::musicReactive:     _renderMusic(a, fx); break;
        default:
            // Bozuk/bilinmeyen değer (ör. hasarlı NVS): sessizce statik gösterme, uyar ve karart.
            if (!fx.warned) {
                fx.warned = true;
                Serial.printf("[Anim] CH%d: unknown effect id %d, rendering black.\n",
                              channel.getId(), static_cast<int>(effect));
            }
            for (uint16_t i = 0; i < count; i++) leds[i] = CRGB::Black;
            break;
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  Mevcut efekt aileleri
// ════════════════════════════════════════════════════════════════════════════

void AnimationEngine::_renderStatic(const Params& a) {
    for (uint16_t i = 0; i < a.n; i++) a.leds[i] = a.c1;
}

// intensity = derinlik: 0 -> sığ (%30), 100 -> tam (0..1)
void AnimationEngine::_renderBreathing(const Params& a, float p) {
    float breathe = (sinf(p * kTwoPi) + 1.0f) * 0.5f;
    float depth = 0.30f + 0.70f * (a.intensity / 100.0f);
    CRGB c = scaled(a.c1, 1.0f - depth * (1.0f - breathe));
    for (uint16_t i = 0; i < a.n; i++) a.leds[i] = c;
}

// Kalp atışı: çift darbe. intensity = derinlik.
void AnimationEngine::_renderPulsing(const Params& a, float p) {
    float v = fmaxf(bump(p, 0.10f, 0.045f), 0.65f * bump(p, 0.28f, 0.045f));
    float depth = 0.40f + 0.60f * (a.intensity / 100.0f);
    CRGB c = scaled(a.c1, (1.0f - depth) + depth * v);
    for (uint16_t i = 0; i < a.n; i++) a.leds[i] = c;
}

// Uzamsal gökkuşağı. intensity = şeritte kaç renk turu (0: 0.25, 50: 1.0, 100: 1.75)
void AnimationEngine::_renderRainbow(const Params& a, float p) {
    float spread = 0.25f + 0.015f * a.intensity;
    uint8_t baseHue = toU8(p * 255.0f);
    for (uint16_t i = 0; i < a.n; i++) {
        float pos = a.n > 1 ? (static_cast<float>(i) / a.n) : 0.0f;
        a.leds[i] = CHSV(baseHue + toU8(frac(pos * spread) * 255.0f), 255, 255);
    }
}

// Tüm şerit aynı renkte, ton döner. intensity = doygunluk (100..255)
void AnimationEngine::_renderRainbowCycle(const Params& a, float p) {
    uint8_t sat = toU8(100.0f + 1.55f * a.intensity);
    CRGB c = CHSV(toU8(p * 255.0f), sat, 255);
    for (uint16_t i = 0; i < a.n; i++) a.leds[i] = c;
}

void AnimationEngine::_renderColorFade(const Params& a, float p) {
    float blendVal = (sinf(p * kTwoPi) + 1.0f) * 0.5f;
    CRGB target = blend(a.c1, a.c2, toU8(blendVal * 255.0f));
    for (uint16_t i = 0; i < a.n; i++) a.leds[i] = target;
}

// ════════════════════════════════════════════════════════════════════════════
//  Yeni efektler
// ════════════════════════════════════════════════════════════════════════════

// Birinci yarı: color zemin color2 üzerine silinir; ikinci yarı: color2 geri siler.
void AnimationEngine::_renderColorWipe(const Params& a, float p) {
    float phase = p * 2.0f;
    bool second = phase >= 1.0f;
    float edge = second ? phase - 1.0f : phase;
    for (uint16_t i = 0; i < a.n; i++) {
        float pos = (i + 0.5f) / a.n;
        bool wiped = pos < edge;
        if (!second) a.leds[i] = wiped ? a.c1 : a.c2;
        else         a.leds[i] = wiped ? a.c2 : a.c1;
    }
}

// Hareket eden sinüs parlaklık dalgası. intensity = dalga boyu (3..40 piksel)
void AnimationEngine::_renderRunningLights(const Params& a, float p) {
    float wl = 3.0f + 0.37f * a.intensity;
    for (uint16_t i = 0; i < a.n; i++) {
        float v = (sinf(kTwoPi * (i / wl - p)) + 1.0f) * 0.5f;
        a.leds[i] = scaled(a.c1, v);
    }
}

// Her S pikselde bir yanan, kayan nokta. intensity = aralık S (2..6). Boşluk = soluk color2.
void AnimationEngine::_renderTheaterChase(const Params& a, float p) {
    int spacing = 2 + static_cast<int>(a.intensity / 25);   // 2..6
    int step = static_cast<int>(p * spacing) % spacing;
    CRGB gap = dimBg(a.c2);
    for (uint16_t i = 0; i < a.n; i++) {
        a.leds[i] = (((i + step) % spacing) == 0) ? a.c1 : gap;
    }
}

// Fire2012 uyarlaması. intensity = alev (soğuma azalır, kıvılcım artar).
// Hız = kıpırdama sıklığı. Renk yok (ısı paleti).
void AnimationEngine::_renderFire(const Params& a, FxState& fx) {
    uint8_t* heat = _buffer(fx, a.n);
    if (heat == nullptr) { _renderStatic(a); return; }

    uint32_t interval = a.periodMs / 40;
    if (interval < 16) interval = 16;
    if (interval > 125) interval = 125;

    fx.acc += a.dt;
    uint8_t steps = 0;
    float cooling = 100.0f - 0.6f * a.intensity;
    uint16_t coolMax = static_cast<uint16_t>((cooling * 10.0f) / a.n) + 2;
    if (coolMax > 255) coolMax = 255;
    uint8_t sparking = toU8(60.0f + 1.2f * a.intensity);

    while (fx.acc >= interval && steps < 4) {
        fx.acc -= interval;
        steps++;
        for (uint16_t i = 0; i < a.n; i++) {
            heat[i] = qsub8(heat[i], random8(0, coolMax >= 255 ? 255 : static_cast<uint8_t>(coolMax + 1)));
        }
        for (int k = a.n - 1; k >= 2; k--) {
            heat[k] = (heat[k - 1] + heat[k - 2] + heat[k - 2]) / 3;
        }
        if (random8() < sparking) {
            uint8_t zone = a.n < 7 ? a.n : 7;
            uint8_t y = random8(zone);
            heat[y] = qadd8(heat[y], random8(160, 255));
        }
    }
    if (steps == 4) fx.acc = 0;

    for (uint16_t i = 0; i < a.n; i++) a.leds[i] = HeatColor(heat[i]);
}

// Tek yönlü, kuyruklu meteor. intensity = kuyruk uzunluğu.
void AnimationEngine::_renderMeteor(const Params& a, float p) {
    if (a.n < 3) {
        float v = 1.0f - p;
        CRGB c = scaled(a.c1, v * v);
        for (uint16_t i = 0; i < a.n; i++) a.leds[i] = c;
        return;
    }
    float tail = 2.0f + (a.intensity / 100.0f) * 0.4f * a.n;
    float head = p * (a.n + tail);
    for (uint16_t i = 0; i < a.n; i++) {
        float d = head - i;
        if (d < 0.0f || d > tail) { a.leds[i] = CRGB::Black; continue; }
        float lvl = 1.0f - d / tail;
        lvl *= lvl;
        if (d >= 1.0f) lvl *= random8(170, 255) / 255.0f;   // kuyrukta titreşim
        a.leds[i] = scaled(a.c1, lvl);
    }
}

// twinkle: yumuşak yanıp sönen yıldızlar. sparkle: ani parlayıp hızla sönen kıvılcımlar.
// intensity = yoğunluk. Zemin = soluk color2.
void AnimationEngine::_renderTwinkle(const Params& a, FxState& fx, bool sparkle) {
    uint8_t* buf = _buffer(fx, a.n * 2);
    if (buf == nullptr) { _renderStatic(a); return; }
    uint8_t* lvl = buf;
    uint8_t* rising = buf + a.n;

    float sf = 5000.0f / a.periodMs;                 // 1..10
    uint8_t fade = static_cast<uint8_t>(fminf(40.0f, fmaxf(2.0f, 25000.0f / a.periodMs)));
    uint8_t rise = static_cast<uint8_t>(fminf(80.0f, fade * 2.0f));
    uint8_t fall = sparkle ? static_cast<uint8_t>(fminf(120.0f, fade * 3.0f)) : fade;
    float spawnF = (1.0f + 0.30f * a.intensity) * (0.5f + 0.25f * fminf(sf, 4.0f));
    uint8_t spawn = toU8(spawnF);

    CRGB bg = dimBg(a.c2);
    for (uint16_t i = 0; i < a.n; i++) {
        if (rising[i]) {
            lvl[i] = qadd8(lvl[i], rise);
            if (lvl[i] == 255) rising[i] = 0;
        } else if (lvl[i] > 0) {
            lvl[i] = qsub8(lvl[i], fall);
        } else if (random8() < spawn) {
            if (sparkle) lvl[i] = 255;
            else { rising[i] = 1; lvl[i] = 1; }
        }
        a.leds[i] = blend(bg, a.c1, lvl[i]);
    }
}

// İki renkli çakar: sol yarı color, sağ yarı color2; ikişer kısa flaş. (n==1: renkler sırayla)
void AnimationEngine::_renderPolice(const Params& a, float p) {
    int slot = static_cast<int>(p * 8.0f) % 8;
    bool on = (slot % 2) == 0;
    int side = slot < 4 ? 0 : 1;
    if (a.n == 1) {
        a.leds[0] = on ? (side == 0 ? a.c1 : a.c2) : CRGB::Black;
        return;
    }
    uint16_t half = a.n / 2;
    for (uint16_t i = 0; i < a.n; i++) {
        bool left = i < half;
        if (!on) { a.leds[i] = CRGB::Black; continue; }
        if (side == 0) a.leds[i] = left ? a.c1 : CRGB::Black;
        else           a.leds[i] = left ? CRGB::Black : a.c2;
    }
}

// color ile color2 arasında akan sinüs dalgası. intensity = dalga boyu (6..56 piksel)
void AnimationEngine::_renderWave(const Params& a, float p) {
    float wl = 6.0f + 0.5f * a.intensity;
    for (uint16_t i = 0; i < a.n; i++) {
        float v = (sinf(kTwoPi * (i / wl - p)) + 1.0f) * 0.5f;
        a.leds[i] = blend(a.c1, a.c2, toU8(v * 255.0f));
    }
}

// color -> color2 -> color döngüsel gradyan, şerit boyunca kayar.
void AnimationEngine::_renderGradientMove(const Params& a, float p) {
    for (uint16_t i = 0; i < a.n; i++) {
        float t = frac((static_cast<float>(i) / a.n) + p);
        float tri = t < 0.5f ? t * 2.0f : (2.0f - t * 2.0f);
        a.leds[i] = blend(a.c1, a.c2, toU8(tri * 255.0f));
    }
}

// Gidip gelen kuyruklu kuyrukluyıldız; baş beyaza çalar. intensity = kuyruk uzunluğu.
void AnimationEngine::_renderComet(const Params& a, float p) {
    float tri = p < 0.5f ? p * 2.0f : (2.0f - p * 2.0f);
    if (a.n < 3) {
        CRGB c = scaled(a.c1, tri);
        for (uint16_t i = 0; i < a.n; i++) a.leds[i] = c;
        return;
    }
    bool forward = p < 0.5f;
    float head = tri * (a.n - 1);
    float tail = 2.0f + (a.intensity / 100.0f) * 0.3f * a.n;
    for (uint16_t i = 0; i < a.n; i++) {
        float d = forward ? (head - i) : (i - head);
        if (d < 0.0f || d > tail) { a.leds[i] = CRGB::Black; continue; }
        float lvl = 1.0f - d / tail;
        lvl *= lvl;
        CRGB c = scaled(a.c1, lvl);
        if (d < 1.0f) c = blend(c, CRGB::White, 110);
        a.leds[i] = c;
    }
}

// Her döngüde rastgele yeni bir renge yumuşak geçiş. intensity = doygunluk.
void AnimationEngine::_renderRandomTransitions(const Params& a, FxState& fx, float p) {
    if (fabsf(p - fx.lastP) > 0.5f) {   // faz sarıldı: yeni hedef
        fx.from = fx.to;
        uint8_t sat = toU8(128.0f + 1.27f * a.intensity);
        fx.to = CHSV(random8(), sat, 255);
    }
    fx.lastP = p;
    uint8_t amt = ease8InOutQuad(toU8(p * 255.0f));
    CRGB c = blend(fx.from, fx.to, amt);
    for (uint16_t i = 0; i < a.n; i++) a.leds[i] = c;
}

// color -> color2 gradyanı; intensity = orta nokta konumu (%5..%95). Statik.
void AnimationEngine::_renderCustomGradient(const Params& a) {
    if (a.n == 1) { a.leds[0] = a.c1; return; }
    float m = clamp01(a.intensity / 100.0f);
    if (m < 0.05f) m = 0.05f;
    if (m > 0.95f) m = 0.95f;
    for (uint16_t i = 0; i < a.n; i++) {
        float x = static_cast<float>(i) / (a.n - 1);
        float amt = x <= m ? 0.5f * (x / m) : 0.5f + 0.5f * ((x - m) / (1.0f - m));
        a.leds[i] = blend(a.c1, a.c2, toU8(amt * 255.0f));
    }
}

// SES GİRİŞİ YOK: Bu donanımda mikrofon yoktur. Ritmik VU çubuğu BPM ile SİMÜLE EDİLİR
// (BPM hıza bağlı: 40..140). intensity = darbe şiddeti. Çubuk color -> color2 gradyanıdır.
void AnimationEngine::_renderMusic(const Params& a, FxState& fx) {
    float bpm = 40.0f + 100.0f * (5000.0f - a.periodMs) / 4500.0f;
    float beatMs = 60000.0f / bpm;
    fx.beat += a.dt / beatMs;
    if (fx.beat >= 1.0f) {
        fx.beat -= floorf(fx.beat);
        fx.beatAmp = random8(150, 255);
    }
    float strength = 0.4f + 0.6f * (a.intensity / 100.0f);
    float level = powf(1.0f - fx.beat, 2.5f) * (fx.beatAmp / 255.0f) * strength;
    level = clamp01(level);

    if (a.n < 3) {
        CRGB c = scaled(blend(a.c1, a.c2, 128), 0.1f + 0.9f * level);
        for (uint16_t i = 0; i < a.n; i++) a.leds[i] = c;
        return;
    }
    float lit = level * a.n;
    for (uint16_t i = 0; i < a.n; i++) {
        if (i < static_cast<uint16_t>(ceilf(lit))) {
            float x = static_cast<float>(i) / (a.n - 1);
            a.leds[i] = blend(a.c1, a.c2, toU8(x * 255.0f));
        } else {
            a.leds[i] = CRGB::Black;
        }
    }
}
