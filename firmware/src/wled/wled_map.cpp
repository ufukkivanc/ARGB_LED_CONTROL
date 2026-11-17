#include "wled_map.h"

#include <ctype.h>
#include <string.h>
#include <stdio.h>

namespace wled {

// types.h EffectType sırasıyla (fx id == indeks)
const char* const kEffectNames[kEffectCount] = {
    "Solid",            // 0  staticColor
    "Rainbow",          // 1  rainbow
    "Rainbow Cycle",    // 2  rainbowCycle
    "Breathe",          // 3  breathing
    "Color Fade",       // 4  colorFade
    "Color Wipe",       // 5  colorWipe
    "Running Lights",   // 6  runningLights
    "Theater Chase",    // 7  theaterChase
    "Fire",             // 8  fire
    "Meteor Rain",      // 9  meteorRain
    "Twinkle",          // 10 twinkle
    "Sparkle",          // 11 sparkle
    "Police Lights",    // 12 policeLights
    "Wave",             // 13 wave
    "Gradient Move",    // 14 gradientMove
    "Comet",            // 15 comet
    "Pulse",            // 16 pulsing
    "Random Colors",    // 17 randomTransitions
    "Gradient",         // 18 customGradient
    "Music Reactive"    // 19 musicReactive (ses girişi yok: simüle)
};

// ── Ölçekler ───────────────────────────────────────────────────────────────

static int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

int sxFromSpeed(int speed) { return clampi((clampi(speed, 1, 100) * 255 + 50) / 100, 0, 255); }
int speedFromSx(int sx) { return clampi((clampi(sx, 0, 255) * 100 + 127) / 255, 1, 100); }
int ixFromIntensity(int i) { return clampi((clampi(i, 0, 100) * 255 + 50) / 100, 0, 255); }
int intensityFromIx(int ix) { return clampi((clampi(ix, 0, 255) * 100 + 127) / 255, 0, 100); }

// ── Görünüm ────────────────────────────────────────────────────────────────

bool anyOn(const View& v) {
    for (int i = 0; i < kMaxSeg; i++) if (v.ch[i].enabled && v.ch[i].power) return true;
    return false;
}

int maxBri(const View& v) {
    int m = 0;
    for (int i = 0; i < kMaxSeg; i++) if (v.ch[i].enabled && v.ch[i].bri > m) m = v.ch[i].bri;
    return m;
}

int enabledCount(const View& v) {
    int n = 0;
    for (int i = 0; i < kMaxSeg; i++) if (v.ch[i].enabled) n++;
    return n;
}

int totalLeds(const View& v) {
    int n = 0;
    for (int i = 0; i < kMaxSeg; i++) if (v.ch[i].enabled) n += v.ch[i].ledCount;
    return n;
}

int ledOffset(const View& v, int ch) {
    int off = 0;
    for (int i = 0; i < ch && i < kMaxSeg; i++) if (v.ch[i].enabled) off += v.ch[i].ledCount;
    return off;
}

// ── Renk ayrıştırma ────────────────────────────────────────────────────────

static int hexVal(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

bool parseHexColor(const char* s, uint8_t rgb[3]) {
    if (s == nullptr) return false;
    if (*s == '#') s++;
    size_t n = strlen(s);
    if (n != 6 && n != 8) return false;
    for (size_t i = 0; i < n; i++) if (hexVal(s[i]) < 0) return false;
    for (int k = 0; k < 3; k++) rgb[k] = static_cast<uint8_t>(hexVal(s[2 * k]) * 16 + hexVal(s[2 * k + 1]));
    return true;  // 8 haneli biçimde son bayt (W) yok sayılır
}

// col[i] öğesini ([r,g,b(,w)] veya hex dizgi) ayrıştırır; geçersiz/null ise false
static bool parseColorElem(JsonVariantConst e, uint8_t rgb[3]) {
    if (e.is<JsonArrayConst>()) {
        JsonArrayConst a = e.as<JsonArrayConst>();
        if (a.size() < 3) return false;
        for (int k = 0; k < 3; k++) {
            if (!a[k].is<int>()) return false;
            rgb[k] = static_cast<uint8_t>(clampi(a[k].as<int>(), 0, 255));
        }
        return true;
    }
    if (e.is<const char*>()) return parseHexColor(e.as<const char*>(), rgb);
    return false;
}

// ── Durum uygulama ─────────────────────────────────────────────────────────

static void setPower(View& v, ParseResult& r, int ch, bool on) {
    if (v.ch[ch].power != on) {
        v.ch[ch].power = on;
        r.changed[ch] |= M_POWER;
    }
}

static void setBri(View& v, ParseResult& r, int ch, int b) {
    uint8_t nb = static_cast<uint8_t>(clampi(b, 0, 255));
    if (v.ch[ch].bri != nb) {
        v.ch[ch].bri = nb;
        r.changed[ch] |= M_BRI;
    }
}

// "on": bool veya "t" (toggle). Geçersizse -1.
static int parseOn(JsonVariantConst on, bool currentOn) {
    if (on.is<bool>()) return on.as<bool>() ? 1 : 0;
    if (on.is<const char*>() && strcmp(on.as<const char*>(), "t") == 0) return currentOn ? 0 : 1;
    return -1;
}

// Kanalın LED sayısını ayarlar (0 = kanal kapalı, >0 = açık). Sınırlar: 0..512/kanal, toplam <= 1024. Aşım: yok sayılır.
static void setLeds(View& v, ParseResult& r, int id, int n) {
    if (id < 0 || id >= kMaxSeg || n < 0 || n > kMaxLedsPerCh) { r.ignored++; return; }
    Ch& c = v.ch[id];
    bool newEn = n > 0;
    if (c.ledCount == n && c.enabled == newEn) return;
    int total = n;
    for (int j = 0; j < kMaxSeg; j++) if (j != id && v.ch[j].enabled) total += v.ch[j].ledCount;
    if (total > kMaxTotalLeds) { r.ignored++; return; }
    c.ledCount = static_cast<uint16_t>(n);
    c.enabled = newEn;
    r.changed[id] |= M_LEN;
}

static void applySegment(JsonObjectConst o, int defaultId, View& v, ParseResult& r, uint32_t rnd) {
    int id = o["id"].is<int>() ? o["id"].as<int>() : defaultId;
    if (id < 0 || id >= kMaxSeg || !v.ch[id].enabled) {
        r.ignored++;  // olmayan/etkin olmayan kanal: segment oluşturulamaz
        return;
    }
    Ch& c = v.ch[id];

    if (!o["on"].isNull()) {
        int on = parseOn(o["on"], c.power);
        if (on >= 0) setPower(v, r, id, on == 1); else r.ignored++;
    }
    if (o["bri"].is<int>()) setBri(v, r, id, o["bri"].as<int>());

    if (o["col"].is<JsonArrayConst>()) {
        JsonArrayConst cols = o["col"].as<JsonArrayConst>();
        for (int slot = 0; slot < 3 && slot < static_cast<int>(cols.size()); slot++) {
            uint8_t rgb[3];
            if (!parseColorElem(cols[slot], rgb)) continue;   // null/geçersiz: bu yuva değişmez
            if (slot == 0) {
                if (memcmp(c.c1, rgb, 3) != 0) { memcpy(c.c1, rgb, 3); r.changed[id] |= M_C1; }
            } else if (slot == 1) {
                if (memcmp(c.c2, rgb, 3) != 0) { memcpy(c.c2, rgb, 3); r.changed[id] |= M_C2; }
            } else {
                r.ignored++;  // 3. renk yuvasının karşılığı yok
            }
        }
    }

    JsonVariantConst fx = o["fx"];
    if (!fx.isNull()) {
        int target = -1;
        if (fx.is<int>()) {
            target = fx.as<int>();
        } else if (fx.is<const char*>()) {
            const char* s = fx.as<const char*>();
            if (strcmp(s, "~") == 0) target = (c.fx + 1) % kEffectCount;
            else if (strcmp(s, "~-") == 0) target = (c.fx + kEffectCount - 1) % kEffectCount;
            else if (strcmp(s, "r") == 0) target = static_cast<int>(rnd % kEffectCount);
        }
        if (target >= 0 && target < kEffectCount) {
            if (c.fx != target) { c.fx = static_cast<uint8_t>(target); r.changed[id] |= M_FX; }
        } else {
            r.ignored++;  // desteklenmeyen WLED efekti: statik renge DÜŞÜRÜLMEZ, değişiklik yapılmaz
        }
    }

    if (o["sx"].is<int>()) {
        uint8_t sp = static_cast<uint8_t>(speedFromSx(o["sx"].as<int>()));
        if (c.speed != sp) { c.speed = sp; r.changed[id] |= M_SPEED; }
    }
    if (o["ix"].is<int>()) {
        uint8_t in = static_cast<uint8_t>(intensityFromIx(o["ix"].as<int>()));
        if (c.intensity != in) { c.intensity = in; r.changed[id] |= M_INT; }
    }
    if (o["rev"].is<bool>()) {
        int8_t d = o["rev"].as<bool>() ? -1 : 1;
        if (c.dir != d) { c.dir = d; r.changed[id] |= M_DIR; }
    }
    // Palet: pal:0 paleti temizler; pal:1 ("Custom Palette") palet doluysa zaten etkindir (boşsa yok sayılır); diğerleri yok sayılır.
    if (o["pal"].is<int>()) {
        int pv = o["pal"].as<int>();
        if (pv == 0) {
            if (c.palN > 0) { c.palN = 0; r.changed[id] |= M_PAL; }
        } else if (pv != 1 || c.palN == 0) {
            r.ignored++;
        }
    }
    // apal: [[r,g,b], ...] (0..5 renk) tüm paleti değiştirir ([] temizler). Geçersiz öğe varsa tüm istek yok sayılır.
    if (o["apal"].is<JsonArrayConst>()) {
        JsonArrayConst pa = o["apal"].as<JsonArrayConst>();
        uint8_t tmp[kPaletteMax][3];
        bool ok = pa.size() <= static_cast<size_t>(kPaletteMax);
        int n = 0;
        for (JsonVariantConst e : pa) {
            if (!ok) break;
            if (!parseColorElem(e, tmp[n])) { ok = false; break; }
            n++;
        }
        if (!ok) {
            r.ignored++;
        } else if (n != c.palN || memcmp(tmp, c.pal, static_cast<size_t>(n) * 3) != 0) {
            c.palN = static_cast<uint8_t>(n);
            memcpy(c.pal, tmp, static_cast<size_t>(n) * 3);
            r.changed[id] |= M_PAL;
        }
    }
    if (o["len"].is<int>()) setLeds(v, r, id, o["len"].as<int>());
}

ParseResult parseState(JsonObjectConst obj, View& v, uint32_t rnd) {
    ParseResult r;
    if (obj["v"].is<bool>()) r.verbose = obj["v"].as<bool>();

    // Üst düzey on / bri: tüm ETKİN kanallar
    if (!obj["on"].isNull()) {
        int on = parseOn(obj["on"], anyOn(v));
        if (on >= 0) {
            for (int i = 0; i < kMaxSeg; i++) if (v.ch[i].enabled) setPower(v, r, i, on == 1);
        } else {
            r.ignored++;
        }
    }
    if (obj["bri"].is<int>()) {
        int b = clampi(obj["bri"].as<int>(), 0, 255);
        int m = maxBri(v);
        for (int i = 0; i < kMaxSeg; i++) {
            if (!v.ch[i].enabled) continue;
            // Orantılı ölçekleme (kanallar arası oranı korur); hepsi 0 ise doğrudan ata
            int nb = (m == 0) ? b : (v.ch[i].bri * b + m / 2) / m;
            setBri(v, r, i, nb);
        }
    }

    // Segmentler: dizi (id yoksa dizideki konum) veya tek nesne (ana segment = 0)
    JsonVariantConst seg = obj["seg"];
    if (seg.is<JsonArrayConst>()) {
        int idx = 0;
        for (JsonVariantConst e : seg.as<JsonArrayConst>()) {
            if (e.is<JsonObjectConst>()) applySegment(e.as<JsonObjectConst>(), idx, v, r, rnd);
            idx++;
        }
    } else if (seg.is<JsonObjectConst>()) {
        applySegment(seg.as<JsonObjectConst>(), 0, v, r, rnd);
    }

    // Bu firmware'e özgü uzantı (WLED uygulaması yok sayar): {"argb":{"leds":[{"id":0,"n":30},...],"reboot":true}}
    // leds: devre dışı kanallar dahil her kanalın LED sayısı (0 = kapat). reboot: bekleyen yapılandırmayı uygulamak için yeniden başlat.
    if (obj["argb"].is<JsonObjectConst>()) {
        JsonObjectConst ar = obj["argb"].as<JsonObjectConst>();
        if (ar["leds"].is<JsonArrayConst>()) {
            for (JsonVariantConst e : ar["leds"].as<JsonArrayConst>()) {
                if (e.is<JsonObjectConst>() && e["id"].is<int>() && e["n"].is<int>()) setLeds(v, r, e["id"].as<int>(), e["n"].as<int>());
                else r.ignored++;
            }
        }
        if (ar["reboot"].is<bool>() && ar["reboot"].as<bool>()) r.reboot = true;
    }

    // Bilerek desteklenmeyen/tehlikeli anahtarlar: yok sayılır (yeniden başlatma, OTA, ön ayar yazma vb.)
    static const char* const kIgnored[] = {"rb", "ota", "psave", "pdel", "ps", "pl", "ledmap", "nl", "udpn", "lor",
                                           "live", "time", "playlist", "cfg", "ccc"};
    for (size_t i = 0; i < sizeof(kIgnored) / sizeof(kIgnored[0]); i++) {
        if (!obj[kIgnored[i]].isNull()) r.ignored++;
    }
    return r;
}

// ── Üretim ─────────────────────────────────────────────────────────────────

void writeState(JsonObject o, const View& v) {
    bool on = anyOn(v);
    o["on"] = on;
    o["bri"] = maxBri(v);
    o["transition"] = 7;
    o["ps"] = -1;
    o["pl"] = -1;
    JsonObject nl = o["nl"].to<JsonObject>();
    nl["on"] = false;
    nl["dur"] = 60;
    nl["mode"] = 1;
    nl["tbri"] = 0;
    nl["rem"] = -1;
    JsonObject udpn = o["udpn"].to<JsonObject>();
    udpn["send"] = false;
    udpn["recv"] = false;
    udpn["sgrp"] = 0;
    udpn["rgrp"] = 0;
    o["lor"] = 0;
    o["mainseg"] = 0;

    JsonArray segs = o["seg"].to<JsonArray>();
    for (int i = 0; i < kMaxSeg; i++) {
        const Ch& c = v.ch[i];
        if (!c.enabled) continue;
        JsonObject s = segs.add<JsonObject>();
        int start = ledOffset(v, i);
        s["id"] = i;
        s["start"] = start;
        s["stop"] = start + c.ledCount;
        s["len"] = c.ledCount;
        s["grp"] = 1;
        s["spc"] = 0;
        s["of"] = 0;
        s["on"] = c.power;
        s["frz"] = false;
        s["bri"] = c.bri;
        s["cct"] = 127;
        s["set"] = 0;
        char nm[12];
        snprintf(nm, sizeof(nm), "CH%d", i + 1);
        s["n"] = nm;
        // Palet doluysa WLED "col" yuvaları paletin ilk 3 rengini gösterir (efektler yalnızca paleti kullanır).
        const uint8_t* c0 = c.palN > 0 ? c.pal[0] : c.c1;
        const uint8_t* c1 = c.palN > 1 ? c.pal[1] : (c.palN == 1 ? c.pal[0] : c.c2);
        static const uint8_t kZero[3] = {0, 0, 0};
        const uint8_t* c2 = c.palN > 2 ? c.pal[2] : kZero;
        JsonArray col = s["col"].to<JsonArray>();
        JsonArray a = col.add<JsonArray>();
        a.add(c0[0]); a.add(c0[1]); a.add(c0[2]);
        JsonArray b = col.add<JsonArray>();
        b.add(c1[0]); b.add(c1[1]); b.add(c1[2]);
        JsonArray d = col.add<JsonArray>();
        d.add(c2[0]); d.add(c2[1]); d.add(c2[2]);
        s["fx"] = c.fx;
        s["sx"] = sxFromSpeed(c.speed);
        s["ix"] = ixFromIntensity(c.intensity);
        s["pal"] = c.palN > 0 ? 1 : 0;
        JsonArray ap = s["apal"].to<JsonArray>();   // firmware uzantısı: özel palet [[r,g,b], ...]
        for (int k = 0; k < c.palN && k < kPaletteMax; k++) {
            JsonArray e = ap.add<JsonArray>();
            e.add(c.pal[k][0]); e.add(c.pal[k][1]); e.add(c.pal[k][2]);
        }
        s["c1"] = 128;
        s["c2"] = 128;
        s["c3"] = 16;
        s["sel"] = (i == 0);
        s["rev"] = (c.dir < 0);
        s["mi"] = false;
        s["o1"] = false;
        s["o2"] = false;
        s["o3"] = false;
        s["si"] = 0;
        s["m12"] = 0;
    }
}

void writeInfo(JsonObject o, const View& v, const InfoCtx& c) {
    o["ver"] = c.ver;
    o["vid"] = 0;   // 0: "güncelleme var" karşılaştırmasını ve WLED yazılımıyla OTA önerisini önler
    JsonObject leds = o["leds"].to<JsonObject>();
    leds["count"] = totalLeds(v);
    leds["pwr"] = 0;
    leds["fps"] = c.fps;
    leds["maxpwr"] = 0;
    leds["maxseg"] = kMaxSeg;
    leds["lc"] = 1;
    JsonArray seglc = leds["seglc"].to<JsonArray>();
    for (int i = 0; i < kMaxSeg; i++) if (v.ch[i].enabled) seglc.add(1);
    o["str"] = false;
    o["name"] = c.name;
    o["udpport"] = 0;
    o["simplifiedui"] = false;
    o["live"] = false;
    o["liveseg"] = -1;
    o["lm"] = "";
    o["lip"] = "";
    o["ws"] = c.wsClients;
    o["fxcount"] = kEffectCount;
    o["palcount"] = 2;
    o["cpalcount"] = 0;
    JsonObject fs = o["fs"].to<JsonObject>();
    fs["u"] = 0;
    fs["t"] = 0;
    fs["pmt"] = 0;
    o["ndc"] = 0;
    o["arch"] = c.arch;
    o["freeheap"] = c.freeHeap;
    o["uptime"] = c.uptimeSec;
    o["time"] = "";
    o["opt"] = 0;   // bit0 = 0: OTA KAPALI (uygulama "yazılım güncelle" sunmasın)
    o["brand"] = c.brand;
    o["access"] = c.access;   // WLED uygulaması bilinmeyen anahtarı yok sayar

    // Firmware uzantısı: kanal başına LED sayıları (devre dışı kanallar dahil), sınırlar, bekleyen yapılandırma
    JsonObject ar = o["argb"].to<JsonObject>();
    ar["maxlen"] = kMaxLedsPerCh;
    ar["maxtotal"] = kMaxTotalLeds;
    ar["warnlen"] = kWarnPerCh;
    ar["warntotal"] = kWarnTotal;
    ar["maxpal"] = kPaletteMax;
    bool rb = false;
    JsonArray chs = ar["ch"].to<JsonArray>();
    for (int i = 0; i < kMaxSeg; i++) {
        JsonObject e = chs.add<JsonObject>();
        e["id"] = i;
        e["en"] = v.ch[i].enabled;
        e["n"] = v.ch[i].ledCount;
        if (v.ch[i].hasPend) {
            e["pen"] = v.ch[i].pendEn;
            e["pn"] = v.ch[i].pendLen;
            rb = true;
        }
    }
    ar["reboot"] = rb;
    o["product"] = c.product;
    o["mac"] = c.mac;
    o["ip"] = c.ip;
    JsonObject w = o["wifi"].to<JsonObject>();
    w["bssid"] = "";
    w["rssi"] = c.rssi;
    w["signal"] = clampi(2 * (c.rssi + 100), 0, 100);
    w["channel"] = 0;
    w["ap"] = false;
}

void writeEffects(JsonArray a) {
    for (int i = 0; i < kEffectCount; i++) a.add(kEffectNames[i]);
}

void writePalettes(JsonArray a) {
    a.add("Default");
    a.add("Custom Palette");   // kanal paleti (apal); pal:0 paleti temizler
}

// ── Başlık doğrulama ───────────────────────────────────────────────────────

static std::string lower(const char* s) {
    std::string r;
    for (; s && *s; s++) r += static_cast<char>(tolower(static_cast<unsigned char>(*s)));
    return r;
}

static bool isIpv4Literal(const std::string& h) {
    int dots = 0, digits = 0, octet = 0;
    for (size_t i = 0; i < h.size(); i++) {
        char ch = h[i];
        if (ch == '.') {
            if (digits == 0) return false;
            dots++;
            digits = 0;
            octet = 0;
        } else if (ch >= '0' && ch <= '9') {
            octet = octet * 10 + (ch - '0');
            digits++;
            if (digits > 3 || octet > 255) return false;
        } else {
            return false;
        }
    }
    return dots == 3 && digits > 0;
}

bool hostAllowed(const char* hostHeader, const char* mdnsHost) {
    if (hostHeader == nullptr || *hostHeader == '\0') return false;
    std::string h = lower(hostHeader);
    size_t colon = h.find(':');
    if (colon != std::string::npos) h = h.substr(0, colon);   // portu at
    if (h.empty()) return false;
    if (isIpv4Literal(h)) return true;
    std::string m = lower(mdnsHost);
    return h == m || h == m + ".local";
}

bool originAllowed(const char* originHeader, const char* hostHeader) {
    if (originHeader == nullptr || *originHeader == '\0') return true;   // yerel/native istemci
    if (hostHeader == nullptr) return false;
    return lower(originHeader) == "http://" + lower(hostHeader);
}

bool wsAuthTimeoutExempt(bool wledPolicyEnabled, bool wledFlag, bool foreignOrigin, bool authed) {
    if (authed) return false;   // token'lı istemci zaten zaman aşımına tabi değil; muafiyet kavramı yetkisizler içindir
    return wledPolicyEnabled && wledFlag && !foreignOrigin;
}

}  // namespace wled
