#pragma once

// Kanal paletinin NVS blob biçimi (saf C++; ana bilgisayarda test edilir): [n, r0,g0,b0, r1,g1,b1, ...]
// Eski sürümlerde anahtar hiç yoktur -> çağıran palet boş (n=0) kabul eder. Bozuk/kısa blob da n=0 verir.
#include <stddef.h>
#include <stdint.h>

namespace paletteblob {

constexpr size_t kMaxColors = 5;
constexpr size_t kMaxBytes = 1 + 3 * kMaxColors;

// rgb[n][3] -> out (en az kMaxBytes). Dönen: yazılan bayt sayısı.
inline size_t encode(uint8_t n, const uint8_t (*rgb)[3], uint8_t* out) {
    if (n > kMaxColors) n = kMaxColors;
    out[0] = n;
    for (uint8_t i = 0; i < n; i++) {
        out[1 + 3 * i] = rgb[i][0];
        out[2 + 3 * i] = rgb[i][1];
        out[3 + 3 * i] = rgb[i][2];
    }
    return 1 + 3 * static_cast<size_t>(n);
}

// raw (got bayt) -> rgb. Dönen: renk sayısı; geçersiz/bozuk ise 0.
inline uint8_t decode(const uint8_t* raw, size_t got, uint8_t (*rgb)[3]) {
    if (raw == nullptr || got < 1) return 0;
    uint8_t n = raw[0];
    if (n == 0 || n > kMaxColors || got < 1 + 3 * static_cast<size_t>(n)) return 0;
    for (uint8_t i = 0; i < n; i++) {
        rgb[i][0] = raw[1 + 3 * i];
        rgb[i][1] = raw[2 + 3 * i];
        rgb[i][2] = raw[3 + 3 * i];
    }
    return n;
}

}  // namespace paletteblob
