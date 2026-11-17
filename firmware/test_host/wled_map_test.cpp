// WLED eşleme katmanı birim testleri (ana bilgisayar; ESP32 gerekmez).
// Derleme/çalıştırma: firmware\test_host\run_host_tests.bat
#include <stdio.h>
#include <string.h>
#include <fstream>
#include <string>

#include "wled_map.h"

static int g_fail = 0;
static int g_pass = 0;

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (cond) { g_pass++; }                                                  \
        else { g_fail++; printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
    } while (0)

static wled::View makeView(int enabledChannels, int leds = 10) {
    wled::View v;
    for (int i = 0; i < enabledChannels; i++) {
        v.ch[i].enabled = true;
        v.ch[i].ledCount = leds;
        v.ch[i].power = true;
        v.ch[i].bri = 200;
        v.ch[i].fx = 3;
        v.ch[i].speed = 55;
        v.ch[i].intensity = 50;
    }
    return v;
}

static wled::ParseResult parse(const char* json, wled::View& v, uint32_t rnd = 0) {
    JsonDocument doc;
    DeserializationError e = deserializeJson(doc, json);
    CHECK(!e);
    return wled::parseState(doc.as<JsonObjectConst>(), v, rnd);
}

static void testScales() {
    printf("[scales]\n");
    for (int s = 1; s <= 100; s++) CHECK(wled::speedFromSx(wled::sxFromSpeed(s)) == s);
    for (int i = 0; i <= 100; i++) CHECK(wled::intensityFromIx(wled::ixFromIntensity(i)) == i);
    CHECK(wled::sxFromSpeed(1) < wled::sxFromSpeed(2));
    CHECK(wled::sxFromSpeed(100) == 255);
    CHECK(wled::speedFromSx(0) == 1);       // 0 -> en düşük geçerli hız
    CHECK(wled::speedFromSx(255) == 100);
    // hız yönü: sx büyüdükçe speed büyür (hızlanır)
    CHECK(wled::speedFromSx(200) > wled::speedFromSx(50));
}

static void testPowerAndBrightness() {
    printf("[on/bri]\n");
    wled::View v = makeView(2);
    v.ch[1].bri = 100;
    auto r = parse("{\"on\":false}", v);
    CHECK(!v.ch[0].power && !v.ch[1].power);
    CHECK(r.changed[0] == wled::M_POWER && r.changed[1] == wled::M_POWER);

    r = parse("{\"on\":\"t\"}", v);  // toggle -> açılır
    CHECK(v.ch[0].power && v.ch[1].power);

    // Orantılı parlaklık: 200/100 oranı korunur, max -> 100
    v = makeView(2);
    v.ch[1].bri = 100;
    r = parse("{\"bri\":100}", v);
    CHECK(v.ch[0].bri == 100);
    CHECK(v.ch[1].bri == 50);

    // Hepsi 0 iken doğrudan atanır
    v = makeView(2);
    v.ch[0].bri = 0;
    v.ch[1].bri = 0;
    parse("{\"bri\":128}", v);
    CHECK(v.ch[0].bri == 128 && v.ch[1].bri == 128);

    // Etkin olmayan kanallara dokunulmaz
    v = makeView(1);
    v.ch[2].bri = 77;
    v.ch[2].power = true;
    parse("{\"on\":false,\"bri\":10}", v);
    CHECK(v.ch[2].bri == 77 && v.ch[2].power);

    // Aynı değer: değişiklik bildirilmez
    v = makeView(1);
    r = parse("{\"on\":true,\"bri\":200}", v);
    CHECK(!r.any());
}

static void testSegments() {
    printf("[seg]\n");
    wled::View v = makeView(2);
    auto r = parse("{\"seg\":[{\"id\":0,\"col\":[[255,0,0],[0,0,255]],\"fx\":5,\"sx\":255,\"ix\":0}]}", v);
    CHECK(v.ch[0].c1[0] == 255 && v.ch[0].c1[1] == 0);
    CHECK(v.ch[0].c2[2] == 255);
    CHECK(v.ch[0].fx == 5);
    CHECK(v.ch[0].speed == 100);
    CHECK(v.ch[0].intensity == 0);
    CHECK((r.changed[0] & wled::M_C1) && (r.changed[0] & wled::M_C2) && (r.changed[0] & wled::M_FX));
    CHECK(r.changed[1] == 0);   // 2. kanal etkilenmedi

    // id yoksa dizideki konum
    v = makeView(2);
    parse("{\"seg\":[{},{\"fx\":9}]}", v);
    CHECK(v.ch[1].fx == 9 && v.ch[0].fx == 3);

    // seg tek nesne -> ana segment (0)
    v = makeView(2);
    parse("{\"seg\":{\"fx\":7}}", v);
    CHECK(v.ch[0].fx == 7 && v.ch[1].fx == 3);

    // hex renk
    v = makeView(1);
    parse("{\"seg\":[{\"col\":[\"00FF80\"]}]}", v);
    CHECK(v.ch[0].c1[0] == 0 && v.ch[0].c1[1] == 255 && v.ch[0].c1[2] == 128);
    // RGBW: W yok sayılır
    parse("{\"seg\":[{\"col\":[[1,2,3,255]]}]}", v);
    CHECK(v.ch[0].c1[0] == 1 && v.ch[0].c1[2] == 3);
    // null yuva değişmez
    uint8_t before = v.ch[0].c2[0];
    parse("{\"seg\":[{\"col\":[null,null]}]}", v);
    CHECK(v.ch[0].c2[0] == before);

    // rev -> yön
    v = makeView(1);
    auto r2 = parse("{\"seg\":[{\"rev\":true}]}", v);
    CHECK(v.ch[0].dir == -1 && (r2.changed[0] & wled::M_DIR));

    // seg on/bri
    v = makeView(1);
    parse("{\"seg\":[{\"on\":false,\"bri\":33}]}", v);
    CHECK(!v.ch[0].power && v.ch[0].bri == 33);

    // olmayan segment (etkin olmayan kanal) yok sayılır
    v = makeView(1);
    auto r3 = parse("{\"seg\":[{\"id\":3,\"fx\":5}]}", v);
    CHECK(r3.ignored >= 1 && !r3.any());
    // start/stop/grp ile yeniden dilimleme yapılamaz: değişiklik yok
    v = makeView(1);
    auto r4 = parse("{\"seg\":[{\"id\":0,\"start\":2,\"stop\":4,\"grp\":2}]}", v);
    CHECK(!r4.any());
    CHECK(v.ch[0].ledCount == 10);
}

static void testEffects() {
    printf("[fx]\n");
    wled::View v = makeView(1);
    v.ch[0].fx = 19;
    parse("{\"seg\":[{\"fx\":\"~\"}]}", v);   // 19 -> 0 (sarma)
    CHECK(v.ch[0].fx == 0);
    parse("{\"seg\":[{\"fx\":\"~-\"}]}", v);  // 0 -> 19
    CHECK(v.ch[0].fx == 19);
    parse("{\"seg\":[{\"fx\":\"r\"}]}", v, 45);  // 45 % 20 = 5
    CHECK(v.ch[0].fx == 5);

    // Desteklenmeyen WLED efektleri: değişiklik yok, statik renge DÜŞMEZ
    v = makeView(1);
    v.ch[0].fx = 8;
    auto r = parse("{\"seg\":[{\"fx\":187}]}", v);
    CHECK(v.ch[0].fx == 8 && r.ignored >= 1 && r.changed[0] == 0);
    r = parse("{\"seg\":[{\"fx\":20}]}", v);
    CHECK(v.ch[0].fx == 8 && r.ignored >= 1);
    r = parse("{\"seg\":[{\"fx\":-1}]}", v);
    CHECK(v.ch[0].fx == 8 && r.ignored >= 1);
    r = parse("{\"seg\":[{\"fx\":\"bogus\"}]}", v);
    CHECK(v.ch[0].fx == 8 && r.ignored >= 1);
    // palet desteklenmez
    r = parse("{\"seg\":[{\"pal\":5}]}", v);
    CHECK(r.ignored >= 1 && !r.any());
}

static void testDangerousKeys() {
    printf("[güvenlik anahtarları]\n");
    wled::View v = makeView(1);
    wled::View before = v;
    auto r = parse("{\"rb\":true,\"ota\":true,\"psave\":1,\"pdel\":1,\"ps\":3,\"cfg\":{\"x\":1},\"live\":true}", v);
    CHECK(!r.any());                    // hiçbir durum değişmedi
    CHECK(r.ignored >= 6);              // hepsi bilerek yok sayıldı
    CHECK(memcmp(&before, &v, sizeof(v)) == 0);
}

static void testVerbose() {
    printf("[v]\n");
    wled::View v = makeView(1);
    auto r = parse("{\"v\":true}", v);
    CHECK(r.verbose && !r.any());
    r = parse("{\"on\":true}", v);
    CHECK(!r.verbose);
}

static void testWriteState() {
    printf("[writeState]\n");
    wled::View v = makeView(2, 10);
    v.ch[1].ledCount = 20;
    JsonDocument doc;
    wled::writeState(doc.to<JsonObject>(), v);
    CHECK(doc["on"].as<bool>() == true);
    CHECK(doc["bri"].as<int>() == 200);
    CHECK(doc["seg"].size() == 2);
    CHECK(doc["seg"][0]["id"].as<int>() == 0);
    CHECK(doc["seg"][0]["start"].as<int>() == 0 && doc["seg"][0]["stop"].as<int>() == 10);
    CHECK(doc["seg"][1]["start"].as<int>() == 10 && doc["seg"][1]["stop"].as<int>() == 30);
    CHECK(doc["seg"][1]["len"].as<int>() == 20);
    CHECK(doc["seg"][0]["col"].size() == 3);
    CHECK(doc["seg"][0]["col"][0].size() == 3);
    CHECK(doc["seg"][0]["fx"].as<int>() == 3);
    CHECK(doc["seg"][0]["sx"].as<int>() == wled::sxFromSpeed(55));
    CHECK(doc["mainseg"].as<int>() == 0);

    // Hiç etkin kanal yok: boş seg, on=false
    wled::View none;
    JsonDocument d2;
    wled::writeState(d2.to<JsonObject>(), none);
    CHECK(d2["seg"].size() == 0 && d2["on"].as<bool>() == false);

    // Round trip: yazılan durum tekrar ayrıştırılınca değişiklik üretmez
    std::string s;
    serializeJson(doc, s);
    wled::View v2 = v;
    JsonDocument back;
    deserializeJson(back, s);
    auto r = wled::parseState(back.as<JsonObjectConst>(), v2);
    CHECK(!r.any());
}

static void testWriteInfo() {
    printf("[writeInfo]\n");
    wled::View v = makeView(1, 10);
    wled::InfoCtx c;
    c.name = "Test LED";
    c.mac = "a1b2c3d4e5f6";
    c.ip = "192.168.1.50";
    c.rssi = -55;
    c.access = "readonly";
    JsonDocument doc;
    wled::writeInfo(doc.to<JsonObject>(), v, c);
    // Resmi iOS/Android uygulamasının zorunlu alanları
    CHECK(doc["leds"].is<JsonObject>() && doc["leds"]["count"].as<int>() == 10);
    CHECK(doc["wifi"].is<JsonObject>() && doc["wifi"]["rssi"].as<int>() == -55);
    CHECK(std::string(doc["name"].as<const char*>()) == "Test LED");
    CHECK(std::string(doc["mac"].as<const char*>()) == "a1b2c3d4e5f6");
    CHECK(doc["fxcount"].as<int>() == 20);
    CHECK(doc["opt"].as<int>() == 0);     // OTA kapalı
    CHECK(std::string(doc["access"].as<const char*>()) == "readonly");
    CHECK(doc["vid"].as<int>() == 0);
    CHECK(std::string(doc["brand"].as<const char*>()) != "WLED");
    // Gizli/ağ bilgisi sızmaz
    std::string s;
    serializeJson(doc, s);
    CHECK(s.find("pass") == std::string::npos);
    CHECK(s.find("token") == std::string::npos);

    JsonDocument eff;
    wled::writeEffects(eff.to<JsonArray>());
    CHECK(eff.size() == 20);
    CHECK(std::string(eff[0].as<const char*>()) == "Solid");
}

static void testHeaders() {
    printf("[host/origin]\n");
    CHECK(wled::hostAllowed("192.168.1.50", "esp32-argb"));
    CHECK(wled::hostAllowed("192.168.1.50:80", "esp32-argb"));
    CHECK(wled::hostAllowed("esp32-argb.local", "esp32-argb"));
    CHECK(wled::hostAllowed("ESP32-ARGB.LOCAL:80", "esp32-argb"));
    CHECK(!wled::hostAllowed("evil.example.com", "esp32-argb"));       // DNS rebinding
    CHECK(!wled::hostAllowed("192.168.1.50.evil.com", "esp32-argb"));
    CHECK(!wled::hostAllowed("999.1.1.1", "esp32-argb"));
    CHECK(!wled::hostAllowed("", "esp32-argb"));
    CHECK(!wled::hostAllowed(nullptr, "esp32-argb"));

    CHECK(wled::originAllowed(nullptr, "192.168.1.50"));               // yerel uygulama (Origin yok)
    CHECK(wled::originAllowed("", "192.168.1.50"));
    CHECK(wled::originAllowed("http://192.168.1.50", "192.168.1.50"));
    CHECK(!wled::originAllowed("http://evil.example.com", "192.168.1.50"));   // tarayıcı CSRF
    CHECK(!wled::originAllowed("null", "192.168.1.50"));
}

// Tarayıcı testinin kaydettiği gerçek sayfa komutlarını (JSON satırları) firmware eşleme koduyla yeniden oynatır:
// her komut geçerli JSON olmalı ve HİÇBİR öğesi "desteklenmiyor" diye yok sayılmamalı.
static int replay(const char* path) {
    std::ifstream f(path);
    if (!f) { printf("dosya acilamadi: %s\n", path); return 2; }
    std::string line;
    int n = 0, bad = 0;
    wled::View v = makeView(2, 10);
    while (std::getline(f, line)) {
        if (line.empty()) continue;
        JsonDocument doc;
        if (deserializeJson(doc, line) || !doc.is<JsonObject>()) { printf("  gecersiz JSON: %s\n", line.c_str()); bad++; continue; }
        wled::ParseResult r = wled::parseState(doc.as<JsonObjectConst>(), v, 7);
        n++;
        if (r.ignored != 0) { printf("  YOK SAYILAN oge (%d): %s\n", r.ignored, line.c_str()); bad++; }
    }
    printf("Replay: %d komut, %d sorunlu\n", n, bad);
    return (bad == 0 && n > 0) ? 0 : 1;
}

static void testWsExempt() {
    printf("[ws auth timeout muafiyeti]\n");
    // (politika açık, wled işareti, yabancı kaynak, authed)
    CHECK(wled::wsAuthTimeoutExempt(true, true, false, false));      // güvenilir WLED istemcisi: muaf
    CHECK(!wled::wsAuthTimeoutExempt(false, true, false, false));    // WLED erişimi kapalı (off): muaf DEĞİL
    CHECK(!wled::wsAuthTimeoutExempt(true, false, false, false));    // WLED işareti yok (token bekleyen): muaf DEĞİL
    CHECK(!wled::wsAuthTimeoutExempt(true, true, true, false));      // yabancı kaynaklı tarayıcı: muaf DEĞİL
    CHECK(!wled::wsAuthTimeoutExempt(false, false, false, false));   // Flutter istemcisi, WLED kapalı: zaman aşımı
    CHECK(!wled::wsAuthTimeoutExempt(false, false, true, false));
    CHECK(!wled::wsAuthTimeoutExempt(true, true, false, true));      // authed: muafiyet konusu değil
    // Mod değişimi: aynı istemci politika kapanınca muaf olmaktan çıkar
    bool before = wled::wsAuthTimeoutExempt(true, true, false, false);
    bool after = wled::wsAuthTimeoutExempt(false, true, false, false);
    CHECK(before && !after);
}

static void testPaletteAndLeds() {
    printf("[palet + LED sayısı]\n");
    wled::View v = makeView(2, 10);
    wled::ParseResult r;
    // palet ekle (1..5 renk), hex/dizi/nesne biçimleri
    r = parse("{\"seg\":[{\"id\":0,\"apal\":[[255,0,0],[0,255,0],[0,0,255]]}]}", v);
    CHECK(v.ch[0].palN == 3 && v.ch[0].pal[1][1] == 255 && (r.changed[0] & wled::M_PAL) && !(r.changed[1] & wled::M_PAL));
    CHECK(v.ch[1].palN == 0);                                    // kanal başına bağımsız palet
    // aynı palet tekrar: değişiklik yok
    r = parse("{\"seg\":[{\"id\":0,\"apal\":[[255,0,0],[0,255,0],[0,0,255]]}]}", v);
    CHECK(!r.any());
    // 5 renk, 6 renk (reddedilir), geçersiz renk (tüm istek reddedilir, palet değişmez)
    r = parse("{\"seg\":[{\"id\":1,\"apal\":[\"ff0000\",\"00ff00\",[0,0,255],[255,255,0],[1,2,3]]}]}", v);
    CHECK(v.ch[1].palN == 5 && v.ch[1].pal[0][0] == 255);
    r = parse("{\"seg\":[{\"id\":1,\"apal\":[[1,1,1],[1,1,1],[1,1,1],[1,1,1],[1,1,1],[1,1,1]]}]}", v);
    CHECK(v.ch[1].palN == 5 && r.ignored >= 1 && !r.any());
    r = parse("{\"seg\":[{\"id\":1,\"apal\":[[1,1,1],\"zz\"]}]}", v);
    CHECK(v.ch[1].palN == 5 && r.ignored >= 1 && !r.any());
    // pal:0 temizler, pal:1 etkin paleti korur, boşken pal:1 / pal:5 yok sayılır
    r = parse("{\"seg\":[{\"id\":1,\"pal\":1}]}", v);
    CHECK(v.ch[1].palN == 5 && !r.any() && r.ignored == 0);
    r = parse("{\"seg\":[{\"id\":1,\"pal\":0}]}", v);
    CHECK(v.ch[1].palN == 0 && (r.changed[1] & wled::M_PAL));
    r = parse("{\"seg\":[{\"id\":1,\"pal\":1}]}", v);
    CHECK(r.ignored == 1 && !r.any());
    // [] temizler
    r = parse("{\"seg\":[{\"id\":0,\"apal\":[]}]}", v);
    CHECK(v.ch[0].palN == 0 && (r.changed[0] & wled::M_PAL));
    // palet efekt/renk durumunu değiştirmez (animasyon durmaz)
    int fxBefore = v.ch[0].fx;
    r = parse("{\"seg\":[{\"id\":0,\"apal\":[[9,9,9]]}]}", v);
    CHECK(v.ch[0].fx == fxBefore && r.changed[0] == wled::M_PAL);

    // LED sayısı: seg.len, argb.leds (devre dışı kanal dahil), sınırlar
    v = makeView(1, 10);
    r = parse("{\"seg\":[{\"id\":0,\"len\":30}]}", v);
    CHECK(v.ch[0].ledCount == 30 && (r.changed[0] & wled::M_LEN));
    r = parse("{\"argb\":{\"leds\":[{\"id\":1,\"n\":30},{\"id\":2,\"n\":30},{\"id\":3,\"n\":30}]}}", v);
    CHECK(v.ch[1].enabled && v.ch[1].ledCount == 30 && v.ch[3].ledCount == 30 && r.ignored == 0);
    CHECK(wled::totalLeds(v) == 120);
    r = parse("{\"argb\":{\"leds\":[{\"id\":0,\"n\":513}]}}", v);                   // kanal sınırı
    CHECK(v.ch[0].ledCount == 30 && r.ignored == 1);
    parse("{\"argb\":{\"leds\":[{\"id\":2,\"n\":0},{\"id\":3,\"n\":0}]}}", v);
    r = parse("{\"argb\":{\"leds\":[{\"id\":0,\"n\":512},{\"id\":1,\"n\":512}]}}", v);   // toplam 1024 sınırında
    CHECK(v.ch[0].ledCount == 512 && v.ch[1].ledCount == 512);
    r = parse("{\"argb\":{\"leds\":[{\"id\":2,\"n\":1}]}}", v);                      // 1024'ü aşar
    CHECK(v.ch[2].ledCount == 0 && !v.ch[2].enabled && r.ignored == 1);
    r = parse("{\"argb\":{\"leds\":[{\"id\":0,\"n\":-1}]}}", v);
    CHECK(r.ignored == 1 && v.ch[0].ledCount == 512);
    r = parse("{\"argb\":{\"leds\":[{\"id\":1,\"n\":0}]}}", v);                      // 0 = kanal kapanır
    CHECK(!v.ch[1].enabled && v.ch[1].ledCount == 0 && (r.changed[1] & wled::M_LEN));
    r = parse("{\"argb\":{\"leds\":[{\"id\":7,\"n\":5}]}}", v);                      // olmayan kanal
    CHECK(r.ignored == 1);
    r = parse("{\"argb\":{\"reboot\":true}}", v);
    CHECK(r.reboot && !r.any());
    r = parse("{\"rb\":true}", v);                                                       // WLED'in rb anahtarı hâlâ yok sayılır
    CHECK(!r.reboot && r.ignored >= 1);

    // üretim: seg.pal/apal/col, info.argb
    v = makeView(2, 10);
    parse("{\"seg\":[{\"id\":0,\"apal\":[[255,0,0],[0,255,0]]}]}", v);
    v.ch[1].hasPend = true; v.ch[1].pendEn = true; v.ch[1].pendLen = 30;
    JsonDocument d;
    wled::writeState(d.to<JsonObject>(), v);
    JsonObject s0 = d["seg"][0];
    CHECK(s0["pal"].as<int>() == 1 && s0["apal"].size() == 2 && s0["col"][0][0].as<int>() == 255 && s0["col"][1][1].as<int>() == 255);
    CHECK(d["seg"][1]["pal"].as<int>() == 0 && d["seg"][1]["apal"].size() == 0);
    JsonDocument di;
    wled::InfoCtx ic;
    wled::writeInfo(di.to<JsonObject>(), v, ic);
    CHECK(di["argb"]["ch"].size() == 4 && di["argb"]["ch"][1]["pn"].as<int>() == 30 && di["argb"]["reboot"].as<bool>());
    CHECK(di["argb"]["maxlen"].as<int>() == 512 && di["argb"]["warnlen"].as<int>() == 300);
    CHECK(di["palcount"].as<int>() == 2);
    JsonDocument dp;
    wled::writePalettes(dp.to<JsonArray>());
    CHECK(dp.size() == 2);
}

int main(int argc, char** argv) {
    if (argc >= 3 && strcmp(argv[1], "--replay") == 0) return replay(argv[2]);
    testScales();
    testPowerAndBrightness();
    testSegments();
    testEffects();
    testDangerousKeys();
    testVerbose();
    testWriteState();
    testWriteInfo();
    testHeaders();
    testWsExempt();
    testPaletteAndLeds();
    printf("\nSonuc: %d dogrulama gecti, %d basarisiz\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
