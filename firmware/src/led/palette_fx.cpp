#include "palette_fx.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

namespace palfx {

static const float kTwoPi = 6.28318530718f;
static const Rgb kBlack = {0, 0, 0};

static inline float frac(float x) { return x - floorf(x); }
static inline float clamp01(float x) { return x < 0.0f ? 0.0f : (x > 1.0f ? 1.0f : x); }
static inline uint8_t toU8(float v) { return v <= 0.0f ? 0 : (v >= 255.0f ? 255 : static_cast<uint8_t>(v)); }

static Rgb blend(const Rgb& a, const Rgb& b, uint8_t amt) {
    Rgb o;
    o.r = static_cast<uint8_t>((a.r * (255 - amt) + b.r * amt) / 255);
    o.g = static_cast<uint8_t>((a.g * (255 - amt) + b.g * amt) / 255);
    o.b = static_cast<uint8_t>((a.b * (255 - amt) + b.b * amt) / 255);
    return o;
}

static Rgb scale(const Rgb& c, float f) {
    f = clamp01(f);
    uint16_t s = static_cast<uint16_t>(f * 255.0f);
    Rgb o;
    o.r = static_cast<uint8_t>((c.r * s) / 255);
    o.g = static_cast<uint8_t>((c.g * s) / 255);
    o.b = static_cast<uint8_t>((c.b * s) / 255);
    return o;
}

static float bump(float t, float center, float width) {
    float d = t - center;
    if (d > 0.5f) d -= 1.0f;
    if (d < -0.5f) d += 1.0f;
    return expf(-(d * d) / (2.0f * width * width));
}

static uint8_t rnd8(State& s) {
    s.rng ^= s.rng << 13;
    s.rng ^= s.rng >> 17;
    s.rng ^= s.rng << 5;
    return static_cast<uint8_t>(s.rng >> 8);
}

static uint8_t rndRange(State& s, uint8_t lo, uint8_t hi) {   // [lo, hi)
    return static_cast<uint8_t>(lo + (rnd8(s) % (hi - lo)));
}

static uint8_t* ensure(State& s, uint16_t bytes) {
    if (s.buf == nullptr || s.bufLen < bytes) {
        free(s.buf);
        s.buf = static_cast<uint8_t*>(calloc(bytes, 1));
        s.bufLen = s.buf ? bytes : 0;
    }
    return s.buf;
}

void resetState(State& s) {
    free(s.buf);
    s.buf = nullptr;
    s.bufLen = 0;
    s.acc = 0;
    s.beat = 0.0f;
    s.beatAmp = 255;
    s.lastP = 0.0f;
    s.primed = false;
    s.from = kBlack;
    s.to = kBlack;
}

Rgb sampleCircular(const Pal& pal, float t) {
    int N = pal.n;
    if (N <= 0) return kBlack;
    if (N == 1) return pal.c[0];
    t = frac(t);
    float pos = t * N;
    int i = static_cast<int>(pos);
    if (i >= N) i = N - 1;
    float f = pos - i;
    return blend(pal.c[i], pal.c[(i + 1) % N], toU8(f * 255.0f));
}

Rgb sampleLinear(const Pal& pal, float t) {
    int N = pal.n;
    if (N <= 0) return kBlack;
    if (N == 1) return pal.c[0];
    t = clamp01(t);
    float pos = t * (N - 1);
    int i = static_cast<int>(pos);
    if (i >= N - 1) i = N - 2;
    float f = pos - i;
    return blend(pal.c[i], pal.c[i + 1], toU8(f * 255.0f));
}

// Gradyan tabanlı efektler için etkin palet: tek renkte (P0, %35 koyu P0) çifti (görsel hareket korunur).
static Pal effective(const Pal& p) {
    if (p.n != 1) return p;
    Pal e;
    e.n = 2;
    e.c[0] = p.c[0];
    e.c[1] = scale(p.c[0], 0.35f);
    return e;
}

static void fill(Rgb* out, uint16_t n, const Rgb& c) {
    for (uint16_t i = 0; i < n; i++) out[i] = c;
}

// ── Isı simülasyonu (Fire2012 uyarlaması; animation_engine._renderFire ile aynı) ────────────────
static uint8_t qsub(uint8_t a, uint8_t b) { return a > b ? a - b : 0; }
static uint8_t qadd(uint8_t a, uint8_t b) { return (a + b) > 255 ? 255 : a + b; }

static void renderFire(const In& in, State& s, const Pal& P) {
    uint16_t n = in.n;
    uint8_t* heat = ensure(s, n);
    if (heat == nullptr) { fill(in.out, n, P.c[0]); return; }

    uint32_t interval = in.periodMs / 40;
    if (interval < 16) interval = 16;
    if (interval > 125) interval = 125;
    s.acc += in.dt;
    uint8_t steps = 0;
    float cooling = 100.0f - 0.6f * in.intensity;
    uint16_t coolMax = static_cast<uint16_t>((cooling * 10.0f) / n) + 2;
    if (coolMax > 255) coolMax = 255;
    uint8_t sparking = toU8(60.0f + 1.2f * in.intensity);

    while (s.acc >= interval && steps < 4) {
        s.acc -= interval;
        steps++;
        for (uint16_t i = 0; i < n; i++) heat[i] = qsub(heat[i], rndRange(s, 0, coolMax >= 255 ? 255 : static_cast<uint8_t>(coolMax + 1)));
        for (int k = n - 1; k >= 2; k--) heat[k] = static_cast<uint8_t>((heat[k - 1] + heat[k - 2] + heat[k - 2]) / 3);
        if (rnd8(s) < sparking) {
            uint8_t zone = n < 7 ? static_cast<uint8_t>(n) : 7;
            uint8_t y = static_cast<uint8_t>(rnd8(s) % zone);
            heat[y] = qadd(heat[y], rndRange(s, 160, 255));
        }
    }
    if (steps == 4) s.acc = 0;

    int N = P.n;
    for (uint16_t i = 0; i < n; i++) {
        float t = (heat[i] / 255.0f) * N;               // duraklar: siyah, P0, P1, ... P(N-1)
        int seg = static_cast<int>(t);
        if (seg >= N) seg = N - 1;
        float f = t - seg;
        const Rgb& from = seg == 0 ? kBlack : P.c[seg - 1];
        in.out[i] = blend(from, P.c[seg], toU8(f * 255.0f));
    }
}

static void renderTwinkle(const In& in, State& s, const Pal& P, bool sparkle) {
    uint16_t n = in.n;
    uint8_t* buf = ensure(s, static_cast<uint16_t>(n * 3));
    if (buf == nullptr) { fill(in.out, n, P.c[0]); return; }
    uint8_t* lvl = buf;
    uint8_t* rising = buf + n;
    uint8_t* col = buf + 2 * n;

    float sf = 5000.0f / in.periodMs;
    uint8_t fade = static_cast<uint8_t>(fminf(40.0f, fmaxf(2.0f, 25000.0f / in.periodMs)));
    uint8_t rise = static_cast<uint8_t>(fminf(80.0f, fade * 2.0f));
    uint8_t fall = sparkle ? static_cast<uint8_t>(fminf(120.0f, fade * 3.0f)) : fade;
    float spawnF = (1.0f + 0.30f * in.intensity) * (0.5f + 0.25f * fminf(sf, 4.0f));
    uint8_t spawn = toU8(spawnF);

    Rgb bg = scale(P.c[0], 40.0f / 255.0f);
    for (uint16_t i = 0; i < n; i++) {
        if (rising[i]) {
            lvl[i] = qadd(lvl[i], rise);
            if (lvl[i] == 255) rising[i] = 0;
        } else if (lvl[i] > 0) {
            lvl[i] = qsub(lvl[i], fall);
        } else if (rnd8(s) < spawn) {
            col[i] = static_cast<uint8_t>(rnd8(s) % P.n);
            if (sparkle) lvl[i] = 255;
            else { rising[i] = 1; lvl[i] = 1; }
        }
        in.out[i] = blend(bg, P.c[col[i] % P.n], lvl[i]);
    }
}

void render(const In& in, State& s) {
    if (in.out == nullptr || in.pal == nullptr || in.n == 0 || in.pal->n == 0) return;
    const Pal& P = *in.pal;
    const Pal E = effective(P);
    const int N = P.n;
    const uint16_t n = in.n;
    Rgb* out = in.out;
    const float p = in.p;
    const float inten = in.intensity > 100 ? 1.0f : in.intensity / 100.0f;

    switch (in.effect) {
        case 0: {   // staticColor: N=1 düz renk; N>=2 şerit boyunca gradyan
            for (uint16_t i = 0; i < n; i++) out[i] = sampleLinear(P, n > 1 ? static_cast<float>(i) / (n - 1) : 0.0f);
            break;
        }
        case 1: {   // rainbow: paletin dairesel gradyanı şeritte kayar (yoğunluk = renk turu sayısı)
            float spread = 0.25f + 0.015f * in.intensity;
            for (uint16_t i = 0; i < n; i++) {
                float pos = n > 1 ? static_cast<float>(i) / n : 0.0f;
                out[i] = sampleCircular(E, pos * spread + p);
            }
            break;
        }
        case 2: fill(out, n, sampleCircular(E, p)); break;   // rainbowCycle: tüm şerit paletten dönen renk
        case 3: {   // breathing: aynı nefes eğrisi; renk her nefesin en karanlık noktasında bir sonrakine geçer
            float breathe = (sinf(p * kTwoPi) + 1.0f) * 0.5f;
            float depth = 0.30f + 0.70f * inten;
            int idx = static_cast<int>((in.cycle + (p >= 0.75f ? 1u : 0u)) % N);
            fill(out, n, scale(P.c[idx], 1.0f - depth * (1.0f - breathe)));
            break;
        }
        case 4: fill(out, n, sampleCircular(E, p)); break;   // colorFade: tüm palet renkleri arasında sırayla geçiş
        case 5: {   // colorWipe: her adımda sıradaki renk bir öncekinin üstüne silinir
            float phase = p * N;
            int k = static_cast<int>(phase);
            if (k >= N) k = N - 1;
            float edge = phase - k;
            Rgb prev = N > 1 ? P.c[(k + N - 1) % N] : kBlack;
            for (uint16_t i = 0; i < n; i++) {
                float pos = (i + 0.5f) / n;
                out[i] = pos < edge ? P.c[k] : prev;
            }
            break;
        }
        case 6: {   // runningLights: dalga maskesi aynı, renk şerit konumundan paletten
            float wl = 3.0f + 0.37f * in.intensity;
            for (uint16_t i = 0; i < n; i++) {
                float v = (sinf(kTwoPi * (i / wl - p)) + 1.0f) * 0.5f;
                Rgb c = sampleLinear(P, n > 1 ? static_cast<float>(i) / (n - 1) : 0.0f);
                out[i] = scale(c, v);
            }
            break;
        }
        case 7: {   // theaterChase: yanan noktalar palet renklerini sırayla alır; boşluk soluk 2. renk
            int spacing = 2 + static_cast<int>(in.intensity / 25);
            int step = static_cast<int>(p * spacing) % spacing;
            Rgb gap = N > 1 ? scale(P.c[1], 40.0f / 255.0f) : kBlack;
            for (uint16_t i = 0; i < n; i++) {
                int v = i + step;
                out[i] = (v % spacing == 0) ? P.c[(v / spacing) % N] : gap;
            }
            break;
        }
        case 8: renderFire(in, s, P); break;   // fire: ısı haritası siyah -> P0 -> ... -> P(N-1)
        case 9: {   // meteorRain: her geçişte sıradaki renk; kuyruk söner
            Rgb col = P.c[in.cycle % N];
            if (n < 3) { float v = 1.0f - p; fill(out, n, scale(col, v * v)); break; }
            float tail = 2.0f + inten * 0.4f * n;
            float head = p * (n + tail);
            for (uint16_t i = 0; i < n; i++) {
                float d = head - i;
                if (d < 0.0f || d > tail) { out[i] = kBlack; continue; }
                float lvl = 1.0f - d / tail;
                lvl *= lvl;
                if (d >= 1.0f) lvl *= rndRange(s, 170, 255) / 255.0f;
                out[i] = scale(col, lvl);
            }
            break;
        }
        case 10: renderTwinkle(in, s, P, false); break;   // twinkle: her yıldız rastgele bir palet rengi
        case 11: renderTwinkle(in, s, P, true); break;    // sparkle
        case 12: {   // policeLights: sol/sağ yarılar paletten dönüşümlü (N=2: klasik iki renk)
            int slot = static_cast<int>(p * 8.0f) % 8;
            bool on = (slot % 2) == 0;
            int side = slot < 4 ? 0 : 1;
            Rgb lc = P.c[(2 * in.cycle) % N];
            Rgb rc = P.c[(2 * in.cycle + 1) % N];
            if (n == 1) { out[0] = on ? (side == 0 ? lc : rc) : kBlack; break; }
            uint16_t half = n / 2;
            for (uint16_t i = 0; i < n; i++) {
                bool left = i < half;
                if (!on) { out[i] = kBlack; continue; }
                if (side == 0) out[i] = left ? lc : kBlack;
                else out[i] = left ? kBlack : rc;
            }
            break;
        }
        case 13: {   // wave: sinüs dalgası tüm palet boyunca (düşük -> P0, yüksek -> P(N-1))
            float wl = 6.0f + 0.5f * in.intensity;
            for (uint16_t i = 0; i < n; i++) {
                float v = (sinf(kTwoPi * (i / wl - p)) + 1.0f) * 0.5f;
                out[i] = sampleLinear(E, v);
            }
            break;
        }
        case 14: {   // gradientMove: dairesel palet gradyanı şerit boyunca kayar
            for (uint16_t i = 0; i < n; i++) out[i] = sampleCircular(E, static_cast<float>(i) / n + p);
            break;
        }
        case 15: {   // comet: her geçişte sıradaki renk; baş beyaza çalar
            float tri = p < 0.5f ? p * 2.0f : (2.0f - p * 2.0f);
            Rgb col = P.c[(2 * in.cycle + (p >= 0.5f ? 1u : 0u)) % N];
            if (n < 3) { fill(out, n, scale(col, tri)); break; }
            bool forward = p < 0.5f;
            float head = tri * (n - 1);
            float tail = 2.0f + inten * 0.3f * n;
            for (uint16_t i = 0; i < n; i++) {
                float d = forward ? (head - i) : (i - head);
                if (d < 0.0f || d > tail) { out[i] = kBlack; continue; }
                float lvl = 1.0f - d / tail;
                lvl *= lvl;
                Rgb c = scale(col, lvl);
                if (d < 1.0f) c = blend(c, Rgb{255, 255, 255}, 110);
                out[i] = c;
            }
            break;
        }
        case 16: {   // pulsing: kalp atışı eğrisi; renk sessiz aralıkta bir sonrakine geçer
            float v = fmaxf(bump(p, 0.10f, 0.045f), 0.65f * bump(p, 0.28f, 0.045f));
            float depth = 0.40f + 0.60f * inten;
            int idx = static_cast<int>((in.cycle + (p >= 0.6f ? 1u : 0u)) % N);
            fill(out, n, scale(P.c[idx], (1.0f - depth) + depth * v));
            break;
        }
        case 17: {   // randomTransitions: rastgele hedef yalnızca paletten
            if (!s.primed) { s.from = P.c[0]; s.to = P.c[0]; s.primed = true; s.lastP = p; }
            if (fabsf(p - s.lastP) > 0.5f) {
                s.from = s.to;
                if (N > 1) {
                    for (int tries = 0; tries < 4; tries++) {
                        Rgb cand = P.c[rnd8(s) % N];
                        s.to = cand;
                        if (cand.r != s.from.r || cand.g != s.from.g || cand.b != s.from.b) break;
                    }
                } else {
                    s.to = sampleCircular(E, rnd8(s) / 255.0f);
                }
            }
            s.lastP = p;
            float e = p < 0.5f ? 2.0f * p * p : 1.0f - 2.0f * (1.0f - p) * (1.0f - p);
            fill(out, n, blend(s.from, s.to, toU8(e * 255.0f)));
            break;
        }
        case 18: {   // customGradient: statik palet gradyanı; yoğunluk orta nokta ağırlığını kaydırır
            if (n == 1) { out[0] = P.c[0]; break; }
            float m = clamp01(inten);
            if (m < 0.05f) m = 0.05f;
            if (m > 0.95f) m = 0.95f;
            for (uint16_t i = 0; i < n; i++) {
                float x = static_cast<float>(i) / (n - 1);
                float u = x <= m ? 0.5f * (x / m) : 0.5f + 0.5f * ((x - m) / (1.0f - m));
                out[i] = sampleLinear(P, u);
            }
            break;
        }
        case 19: {   // musicReactive (ses girişi YOK; BPM simülasyonu): VU çubuğu paletle alttan üste boyanır
            float bpm = 40.0f + 100.0f * (5000.0f - in.periodMs) / 4500.0f;
            float beatMs = 60000.0f / bpm;
            s.beat += in.dt / beatMs;
            if (s.beat >= 1.0f) {
                s.beat -= floorf(s.beat);
                s.beatAmp = rndRange(s, 150, 255);
            }
            float strength = 0.4f + 0.6f * inten;
            float level = clamp01(powf(1.0f - s.beat, 2.5f) * (s.beatAmp / 255.0f) * strength);
            if (n < 3) { fill(out, n, scale(sampleLinear(P, 0.5f), 0.1f + 0.9f * level)); break; }
            float lit = level * n;
            uint16_t litN = static_cast<uint16_t>(ceilf(lit));
            for (uint16_t i = 0; i < n; i++) {
                out[i] = i < litN ? sampleLinear(P, static_cast<float>(i) / (n - 1)) : kBlack;
            }
            break;
        }
        default: fill(out, n, kBlack); break;
    }
}

}  // namespace palfx
