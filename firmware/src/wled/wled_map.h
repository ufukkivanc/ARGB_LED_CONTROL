#pragma once

// WLED JSON API <-> ESP32 ARGB Controller eşleme katmanı (SAF C++).
//
// Bu dosya Arduino/ESP-IDF'e BAĞLI DEĞİLDİR (yalnızca ArduinoJson + std); bu sayede
// ana bilgisayarda (MSVC/g++) birim test edilebilir: firmware/test_host/.
//
// Eşleme modeli (docs/WLED_COMPAT.md):
//  - WLED segment id  i  <->  fiziksel kanal  i+1   (yalnızca ETKİN kanallar segment olarak görünür).
//  - Segment start/stop = etkin kanalların LED sayılarının art arda dizilmesiyle oluşan SANAL şerit.
//    start/stop/len/grp/spc/of/mi/pal/... YAZILAMAZ (fiziksel kanallar yeniden dilimlenemez) -> yok sayılır.
//  - Üst düzey on/bri = tüm etkin kanallar; bri orantılı ölçeklenir.
//  - fx id == bu firmware'in EffectType indeksi (0..19); /json/eff 20 efektin adını verir.
//    20 ve üstü fx değerleri DESTEKLENMEZ: değişiklik yapılmaz (statik renge düşürülmez).
#include <stdint.h>
#include <string>
#include <ArduinoJson.h>

namespace wled {

constexpr int kMaxSeg = 4;
constexpr int kEffectCount = 20;
extern const char* const kEffectNames[kEffectCount];

// Bir fiziksel kanalın WLED'e bakan görünümü
struct Ch {
    bool enabled = false;
    uint16_t ledCount = 0;
    bool power = false;
    uint8_t c1[3] = {255, 180, 107};
    uint8_t c2[3] = {0, 0, 0};
    uint8_t fx = 0;          // 0..19
    uint8_t bri = 0;         // 0..255 (kanal parlaklığı)
    uint8_t speed = 50;      // 1..100
    int8_t dir = 1;          // +1 / -1
    uint8_t intensity = 50;  // 0..100
};

struct View {
    Ch ch[kMaxSeg];
};

// Değişen alan maskesi (command.h F_* ile aynı bit düzeni olmak ZORUNDA DEĞİL; glue çevirir)
enum : uint16_t {
    M_POWER = 1 << 0,
    M_C1    = 1 << 1,
    M_C2    = 1 << 2,
    M_FX    = 1 << 3,
    M_BRI   = 1 << 4,
    M_SPEED = 1 << 5,
    M_DIR   = 1 << 6,
    M_INT   = 1 << 7
};

struct ParseResult {
    uint16_t changed[kMaxSeg] = {0, 0, 0, 0};  // kanal başına değişen alanlar
    bool verbose = false;                      // "v":true -> tam durum iste
    int ignored = 0;                           // desteklenmeyip yok sayılan öğe sayısı
    bool any() const {
        for (int i = 0; i < kMaxSeg; i++) if (changed[i]) return true;
        return false;
    }
};

// ── Ölçek dönüşümleri ──────────────────────────────────────────────────────
int sxFromSpeed(int speed);        // 1..100 -> 0..255
int speedFromSx(int sx);           // 0..255 -> 1..100
int ixFromIntensity(int intensity);  // 0..100 -> 0..255
int intensityFromIx(int ix);       // 0..255 -> 0..100

// ── Görünüm yardımcıları ───────────────────────────────────────────────────
bool anyOn(const View& v);
int maxBri(const View& v);
int enabledCount(const View& v);
int totalLeds(const View& v);
int ledOffset(const View& v, int ch);  // kanal ch'nin sanal şeritteki başlangıcı

// Hex renk ("RRGGBB", "RRGGBBWW", baştaki '#' isteğe bağlı) -> rgb
bool parseHexColor(const char* s, uint8_t rgb[3]);

// WLED durum nesnesini (POST /json/state gövdesi / WebSocket komutu) v'ye UYGULAR.
// `rnd`: "fx":"r" (rastgele efekt) için rastgele sayı.
ParseResult parseState(JsonObjectConst obj, View& v, uint32_t rnd = 0);

// ── Üretim ────────────────────────────────────────────────────────────────
struct InfoCtx {
    const char* name = "ESP32 ARGB";
    const char* mac = "000000000000";   // 12 küçük harfli hex, iki nokta yok (WLED biçimi)
    const char* ip = "";
    int rssi = -60;
    uint32_t freeHeap = 0;
    uint32_t uptimeSec = 0;
    int wsClients = 0;
    const char* arch = "esp32";
    const char* brand = "ESP32-ARGB";
    const char* product = "ESP32 Smart ARGB Controller";
    const char* ver = "0.14.0";
    const char* access = "off";   // off | readonly | control: web arayüzü yazma yetkisini buradan öğrenir
};

void writeState(JsonObject o, const View& v);
void writeInfo(JsonObject o, const View& v, const InfoCtx& c);
void writeEffects(JsonArray a);
void writePalettes(JsonArray a);

// ── Tarayıcı kaynaklı saldırılara karşı başlık doğrulama ────────────────────
// Host: IPv4 sabit adresi veya <mdnsHost>[.local] olmalı (DNS rebinding).
bool hostAllowed(const char* hostHeader, const char* mdnsHost);
// Origin varsa "http://<Host>" ile aynı olmalı (başka sitelerden CSRF engeli). Yoksa (yerel uygulama) serbest.
bool originAllowed(const char* originHeader, const char* hostHeader);

}  // namespace wled
