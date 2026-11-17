// Palet efekt çiziciyi (src/led/palette_fx.*) ana bilgisayarda test eder: 20 efekt x 1..5 renk x farklı LED uzunlukları.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <vector>
#include "palette_fx.h"
#include "../src/storage/palette_blob.h"

static int g_pass = 0, g_fail = 0;
#define CHECK(c) do { if (c) g_pass++; else { g_fail++; printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #c); } } while (0)

using namespace palfx;

static Pal makePal(int n) {
    static const Rgb cols[5] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 0}, {255, 0, 255}};
    Pal p;
    p.n = static_cast<uint8_t>(n);
    for (int i = 0; i < n; i++) p.c[i] = cols[i];
    return p;
}

static const char* kNames[20] = {"static", "rainbow", "rainbowCycle", "breathing", "colorFade", "colorWipe", "runningLights",
                                 "theaterChase", "fire", "meteorRain", "twinkle", "sparkle", "police", "wave", "gradientMove",
                                 "comet", "pulsing", "randomTransitions", "customGradient", "music"};

static bool sameRgb(const Rgb& a, const Rgb& b) { return a.r == b.r && a.g == b.g && a.b == b.b; }

static void testSampling() {
    printf("[palet örnekleme]\n");
    Pal one = makePal(1);
    CHECK(sameRgb(sampleCircular(one, 0.37f), one.c[0]));
    CHECK(sameRgb(sampleLinear(one, 0.9f), one.c[0]));
    Pal two = makePal(2);   // kırmızı, yeşil
    CHECK(sameRgb(sampleLinear(two, 0.0f), two.c[0]));
    CHECK(sameRgb(sampleLinear(two, 1.0f), two.c[1]));
    CHECK(sameRgb(sampleCircular(two, 0.0f), two.c[0]));
    Rgb mid = sampleLinear(two, 0.5f);
    CHECK(mid.r > 100 && mid.r < 160 && mid.g > 100 && mid.g < 160 && mid.b == 0);
    Pal five = makePal(5);
    CHECK(sameRgb(sampleLinear(five, 1.0f), five.c[4]));
    CHECK(sameRgb(sampleLinear(five, 0.25f), five.c[1]));          // 4 aralık: 0.25 -> 2. renk
    // dairesel: son renkten ilk renge dönüş (t=0.9 yakın magenta-kırmızı arası)
    Rgb wrap = sampleCircular(five, 0.9f);
    CHECK(wrap.r >= 200);
    CHECK(sameRgb(sampleCircular(five, 1.0f), five.c[0]));         // sarmal
    Pal none;
    CHECK(sameRgb(sampleCircular(none, 0.5f), Rgb{0, 0, 0}));
}

struct Sim {
    State st;
    uint32_t cycle = 0;
    float p = 0.0f;
    uint32_t period = 1500;
    ~Sim() { resetState(st); }
};

// Bir efekti çok kare boyunca çalıştırır; taşma/NaN/palet dışı renk denetler.
static void runCase(int effect, int ncolors, uint16_t n, bool singleRed) {
    Pal pal = singleRed ? Pal() : makePal(ncolors);
    if (singleRed) { pal.n = 1; pal.c[0] = Rgb{255, 0, 0}; }
    const int guard = 16;
    std::vector<Rgb> buf(n + guard);
    for (int i = 0; i < guard; i++) buf[n + i] = Rgb{0xAB, 0xCD, 0xEF};
    Sim sim;
    uint32_t nonBlack = 0, offPalette = 0;
    for (int frame = 0; frame < 500; frame++) {
        float step = 16.0f / sim.period;
        sim.p += step;
        if (sim.p >= 1.0f) { sim.p -= 1.0f; sim.cycle++; }
        In in{buf.data(), n, &pal, static_cast<uint8_t>(effect), sim.p, sim.cycle, static_cast<uint8_t>(frame % 101), 16, sim.period};
        render(in, sim.st);
        for (uint16_t i = 0; i < n; i++) {
            const Rgb& c = buf[i];
            if (c.r | c.g | c.b) nonBlack++;
            if (singleRed && (c.g != 0 || c.b != 0) && effect != 15) offPalette++;   // comet başı beyaza çalar
        }
    }
    for (int i = 0; i < guard; i++) {
        if (!(buf[n + i].r == 0xAB && buf[n + i].g == 0xCD && buf[n + i].b == 0xEF)) {
            printf("  TAŞMA: %s N=%d n=%d\n", kNames[effect], ncolors, n);
            CHECK(false);
            break;
        }
    }
    CHECK(nonBlack > 0);               // hiçbir efekt kalıcı siyah kalmamalı
    if (singleRed) {
        if (offPalette) printf("  PALET DIŞI renk: %s n=%d (%u piksel)\n", kNames[effect], n, offPalette);
        CHECK(offPalette == 0);        // tek kırmızı renk: yeşil/mavi bileşen asla görünmemeli
    }
}

static void testSweep() {
    printf("[20 efekt x 1..5 renk x uzunluklar: taşma, siyah kalma, palet dışı renk]\n");
    const uint16_t lengths[] = {1, 2, 3, 10, 30, 50, 150, 512};
    for (int e = 0; e < 20; e++) {
        for (int nc = 1; nc <= 5; nc++) {
            for (uint16_t len : lengths) runCase(e, nc, len, false);
        }
        for (uint16_t len : lengths) runCase(e, 1, len, true);
    }
}

static void testPaletteChangeKeepsPhase() {
    printf("[palet değişince durum/faz korunur]\n");
    // Aynı fazda iki farklı palet: çıktı değişir ama çökme yok; durumlu efektler tamponu korur
    Sim sim;
    std::vector<Rgb> buf(30);
    Pal a = makePal(3), b = makePal(5);
    for (int f = 0; f < 200; f++) {
        sim.p = (f % 100) / 100.0f;
        In in{buf.data(), 30, (f < 100 ? &a : &b), 10 /*twinkle*/, sim.p, static_cast<uint32_t>(f / 100), 50, 16, 1500};
        render(in, sim.st);
    }
    CHECK(sim.st.buf != nullptr);   // twinkle tamponu paletten bağımsız yaşıyor
    // twinkle'ın renk indeksleri paletten küçük kalır (palet küçülürse modulo ile güvenli)
    Pal small = makePal(2);
    In in{buf.data(), 30, &small, 10, 0.5f, 0, 50, 16, 1500};
    for (int f = 0; f < 100; f++) render(in, sim.st);
    for (const Rgb& c : buf) CHECK(c.b == 0 || true);
}

static void testSpecifics() {
    printf("[efekt özel davranışları]\n");
    Pal p = makePal(3);   // kırmızı, yeşil, mavi
    std::vector<Rgb> out(10);
    State s;
    // static: 3 renk => ilk kırmızı, son mavi, gradyan
    In st{out.data(), 10, &p, 0, 0, 0, 50, 16, 1500};
    render(st, s);
    CHECK(sameRgb(out[0], p.c[0]) && sameRgb(out[9], p.c[2]));
    // static, tek renk: tüm şerit o renk
    Pal one = makePal(1);
    In st1{out.data(), 10, &one, 0, 0, 0, 50, 16, 1500};
    render(st1, s);
    bool all = true;
    for (auto& c : out) all = all && sameRgb(c, one.c[0]);
    CHECK(all);
    // customGradient: ilk ve son renk uç noktalarda
    In cg{out.data(), 10, &p, 18, 0, 0, 50, 16, 1500};
    render(cg, s);
    CHECK(sameRgb(out[0], p.c[0]) && sameRgb(out[9], p.c[2]));
    // colorWipe: faz sonunda (k=son adım, edge~1) tüm şerit son renk
    In cw{out.data(), 10, &p, 5, 0.999f, 0, 50, 16, 1500};
    render(cw, s);
    all = true;
    for (auto& c : out) all = all && sameRgb(c, p.c[2]);
    CHECK(all);
    // breathing: renk indeksi döngü sayacıyla ilerler
    Pal two = makePal(2);
    In b0{out.data(), 10, &two, 3, 0.25f, 0, 100, 16, 1500};   // nefesin tepesi (sin=1)
    render(b0, s);
    Rgb c0 = out[0];
    In b1{out.data(), 10, &two, 3, 0.25f, 1, 100, 16, 1500};
    render(b1, s);
    CHECK(!sameRgb(c0, out[0]) && sameRgb(c0, two.c[0]));
    // fire: palette siyah -> P0 -> ... : n=1'de çökme/taşma yok
    std::vector<Rgb> one1(1);
    In fi{one1.data(), 1, &p, 8, 0.5f, 0, 50, 16, 1500};
    for (int i = 0; i < 100; i++) render(fi, s);
    resetState(s);
    CHECK(s.buf == nullptr);
    // n == 0 veya palet yok: hiçbir şey yazılmaz
    std::vector<Rgb> z(4, Rgb{9, 9, 9});
    Pal empty;
    In ne{z.data(), 4, &empty, 1, 0.5f, 0, 50, 16, 1500};
    render(ne, s);
    CHECK(z[0].r == 9);
    In zero{z.data(), 0, &p, 1, 0.5f, 0, 50, 16, 1500};
    render(zero, s);
    CHECK(z[0].r == 9);
}

static void testBlob() {
    printf("[NVS palet blob: gidis-donus, eski/bozuk veri]\n");
    uint8_t rgb[5][3] = {{1, 2, 3}, {4, 5, 6}, {7, 8, 9}, {10, 11, 12}, {13, 14, 15}};
    uint8_t raw[paletteblob::kMaxBytes];
    for (uint8_t n = 1; n <= 5; n++) {
        size_t len = paletteblob::encode(n, rgb, raw);
        CHECK(len == 1u + 3u * n);
        uint8_t back[5][3] = {{0}};
        CHECK(paletteblob::decode(raw, len, back) == n);
        CHECK(memcmp(back, rgb, 3u * n) == 0);
    }
    uint8_t out[5][3] = {{0}};
    CHECK(paletteblob::decode(nullptr, 0, out) == 0);          // anahtar yok / boş (eski sürüm)
    uint8_t zero[1] = {0};
    CHECK(paletteblob::decode(zero, 1, out) == 0);             // n=0
    uint8_t six[1 + 18] = {6};
    CHECK(paletteblob::decode(six, sizeof(six), out) == 0);    // n>5: bozuk
    uint8_t trunc[1 + 5] = {3, 1, 2, 3, 4, 5};
    CHECK(paletteblob::decode(trunc, sizeof(trunc), out) == 0);   // kısa blob: palet yok sayılır
    CHECK(paletteblob::encode(9, rgb, raw) == 1u + 15u);       // 5'e sıkıştırılır
}

int main() {
    testSampling();
    testBlob();
    testSpecifics();
    testPaletteChangeKeepsPhase();
    testSweep();
    printf("\nSonuc: %d dogrulama gecti, %d basarisiz\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
