#include "wled_compat.h"

#if ENABLE_WLED_COMPAT

#include <Preferences.h>
#include <WiFi.h>
#include <esp_system.h>

#include "wled_map.h"
#include "control_page.h"
#include "api/api_server.h"
#include "api/command.h"
#include "api/command_processor.h"
#include "api/snapshot.h"
#include "network/mdns_service.h"

static const char* kNvsNs = "wled_cfg";
static const char* kNvsKeyMode = "mode";
static const size_t kBodyMax = 2048;

const char* wledModeName(WledMode m) {
    switch (m) {
        case WledMode::ReadOnly: return "readonly";
        case WledMode::Control:  return "control";
        default:                 return "off";
    }
}

bool wledModeFromName(const char* s, WledMode& out) {
    if (s == nullptr) return false;
    if (strcmp(s, "off") == 0)      { out = WledMode::Off; return true; }
    if (strcmp(s, "readonly") == 0) { out = WledMode::ReadOnly; return true; }
    if (strcmp(s, "control") == 0)  { out = WledMode::Control; return true; }
    return false;
}

WledCompat& WledCompat::instance() {
    static WledCompat w;
    return w;
}

// ── Yaşam döngüsü (core 1) ──────────────────────────────────────────────────

void WledCompat::begin() {
    Preferences p;
    uint8_t m = 0;
    if (p.begin(kNvsNs, true)) {
        m = p.getUChar(kNvsKeyMode, 0);
        p.end();
    }
    _mode = (m <= 2) ? m : 0;   // geçersiz/bozuk değer -> KAPALI (güvenli varsayılan)
    _mdnsDirty = true;
    Serial.printf("[WLED] Compatibility layer compiled in. Access mode: %s\n", wledModeName(mode()));
}

bool WledCompat::setMode(WledMode m) {
    Preferences p;
    if (!p.begin(kNvsNs, false)) return false;
    p.putUChar(kNvsKeyMode, static_cast<uint8_t>(m));
    p.end();
    _mode = static_cast<uint8_t>(m);
    _mdnsDirty = true;
    _dirty = true;
    Serial.printf("[WLED] Access mode set to: %s\n", wledModeName(m));
    return true;
}

void WledCompat::notifyStateChanged() { _dirty = true; }

void WledCompat::tick() {
    if (_mdnsDirty) {
        _mdnsDirty = false;
        MdnsService::instance().setWledAdvertised(enabled());
    }
    if (_dirty && enabled()) {
        uint32_t now = millis();
        if (now - _lastPush >= 200 && ApiServer::instance().wledClientCount() > 0) {
            _lastPush = now;
            _dirty = false;
            ApiServer::instance().broadcastWled(buildFrame());
        } else if (ApiServer::instance().wledClientCount() == 0) {
            _dirty = false;
        }
    } else if (_dirty) {
        _dirty = false;
    }
}

// ── Görünüm / JSON üretimi ──────────────────────────────────────────────────

static wled::View viewFromSnapshot(const Snapshot& s) {
    wled::View v;
    for (int i = 0; i < wled::kMaxSeg && i < MAX_CHANNELS; i++) {
        const ChannelConfig& cfg = s.ch[i].cfg;
        const ChannelState& st = s.ch[i].st;
        wled::Ch& c = v.ch[i];
        c.enabled = cfg.enabled && cfg.ledCount > 0;
        c.ledCount = cfg.ledCount;
        c.power = st.isOn;
        c.c1[0] = st.primaryColor.r; c.c1[1] = st.primaryColor.g; c.c1[2] = st.primaryColor.b;
        c.c2[0] = st.secondaryColor.r; c.c2[1] = st.secondaryColor.g; c.c2[2] = st.secondaryColor.b;
        uint8_t fx = static_cast<uint8_t>(st.effectType);
        c.fx = fx < wled::kEffectCount ? fx : 0;
        c.bri = st.brightness;
        c.speed = st.speed < 1 ? 1 : (st.speed > 100 ? 100 : st.speed);
        c.dir = st.direction < 0 ? -1 : 1;
        c.intensity = st.intensity > 100 ? 100 : st.intensity;
        c.palN = st.palette.n > wled::kPaletteMax ? wled::kPaletteMax : st.palette.n;
        for (int k = 0; k < c.palN; k++) {
            c.pal[k][0] = st.palette.c[k].r; c.pal[k][1] = st.palette.c[k].g; c.pal[k][2] = st.palette.c[k].b;
        }
        c.hasPend = s.ch[i].hasPending;
        c.pendEn = s.ch[i].pending.enabled && s.ch[i].pending.ledCount > 0;
        c.pendLen = s.ch[i].pending.ledCount;
    }
    return v;
}

static String macNoColons() {
    String m = WiFi.macAddress();
    m.replace(":", "");
    m.toLowerCase();
    return m;
}

String WledCompat::buildState() {
    Snapshot s;
    SnapshotStore::instance().getState(s);
    wled::View v = viewFromSnapshot(s);
    JsonDocument d;
    wled::writeState(d.to<JsonObject>(), v);
    String out;
    serializeJson(d, out);
    return out;
}

static void fillInfo(JsonObject o, const Snapshot& s, const wled::View& v) {
    wled::InfoCtx c;
    String name = ApiServer::instance().deviceName();
    String mac = macNoColons();
    String ip = s.wifi.state == WiFiConnectionState::Connected ? String(s.wifi.ip) : String("");
    c.name = name.c_str();
    c.mac = mac.c_str();
    c.ip = ip.c_str();
    c.rssi = s.wifi.rssi;
    c.freeHeap = s.freeHeap;
    c.uptimeSec = s.uptimeMs / 1000;
    c.fps = s.fps > 0 ? s.fps : 60;
    c.wsClients = static_cast<int>(ApiServer::instance().wledClientCount());
    c.access = wledModeName(WledCompat::instance().mode());
    wled::writeInfo(o, v, c);
}

String WledCompat::buildInfo() {
    Snapshot s;
    SnapshotStore::instance().getState(s);
    JsonDocument d;
    fillInfo(d.to<JsonObject>(), s, viewFromSnapshot(s));
    String out;
    serializeJson(d, out);
    return out;
}

String WledCompat::buildSi() { return buildFrame(); }

String WledCompat::buildFrame() {
    Snapshot s;
    SnapshotStore::instance().getState(s);
    wled::View v = viewFromSnapshot(s);
    JsonDocument d;
    wled::writeState(d["state"].to<JsonObject>(), v);
    fillInfo(d["info"].to<JsonObject>(), s, v);
    String out;
    serializeJson(d, out);
    return out;
}

String WledCompat::buildFull() {
    Snapshot s;
    SnapshotStore::instance().getState(s);
    wled::View v = viewFromSnapshot(s);
    JsonDocument d;
    wled::writeState(d["state"].to<JsonObject>(), v);
    fillInfo(d["info"].to<JsonObject>(), s, v);
    wled::writeEffects(d["effects"].to<JsonArray>());
    wled::writePalettes(d["palettes"].to<JsonArray>());
    String out;
    serializeJson(d, out);
    return out;
}

// ── Komut kuyruğuna çeviri ──────────────────────────────────────────────────

// Değişen alanları kanal başına bir Set komutu olarak kuyruğa koyar (LED durumuna yalnızca loop() dokunur).
static bool enqueueChanges(const wled::View& after, const wled::ParseResult& r) {
    for (int i = 0; i < wled::kMaxSeg; i++) {
        uint16_t m = r.changed[i];
        if (m == 0) continue;
        const wled::Ch& c = after.ch[i];
        Command cmd{};
        cmd.type = CmdType::Set;
        cmd.clientId = 0;
        cmd.chMask = static_cast<uint8_t>(1u << i);
        if (m & wled::M_POWER) { cmd.fieldMask |= F_POWER; cmd.power = c.power; }
        if (m & wled::M_C1)    { cmd.fieldMask |= F_COLOR; cmd.color = RgbColor(c.c1[0], c.c1[1], c.c1[2]); }
        if (m & wled::M_C2)    { cmd.fieldMask |= F_COLOR2; cmd.color2 = RgbColor(c.c2[0], c.c2[1], c.c2[2]); }
        if (m & wled::M_FX)    { cmd.fieldMask |= F_EFFECT; cmd.effect = static_cast<EffectType>(c.fx); }
        if (m & wled::M_BRI)   { cmd.fieldMask |= F_BRIGHT; cmd.brightness = c.bri; }
        if (m & wled::M_SPEED) { cmd.fieldMask |= F_SPEED; cmd.speed = c.speed; }
        if (m & wled::M_DIR)   { cmd.fieldMask |= F_DIRECTION; cmd.direction = c.dir; }
        if (m & wled::M_INT)   { cmd.fieldMask |= F_INTENSITY; cmd.intensity = c.intensity; }
        if (m & wled::M_PAL) {
            cmd.fieldMask |= F_PALETTE;
            cmd.palette = Palette();
            for (int k = 0; k < c.palN && k < wled::kPaletteMax; k++) {
                cmd.palette.c[k] = RgbColor(c.pal[k][0], c.pal[k][1], c.pal[k][2]);
                cmd.palette.n++;
            }
        }
        if (cmd.fieldMask != 0 && !CommandProcessor::instance().enqueue(cmd)) return false;

        if (m & wled::M_LEN) {   // LED sayısı: setChannelConfig ile aynı doğrulama/uygulama yolu (kuyruk -> loop)
            Command cc{};
            cc.type = CmdType::SetConfig;
            cc.clientId = 0;
            cc.cfgChannel = static_cast<uint8_t>(i + 1);
            cc.cfgMask = CF_LEDCOUNT;
            cc.cfgLedCount = c.ledCount;
            if (!CommandProcessor::instance().enqueue(cc)) return false;
        }
    }
    // Bekleyen yapılandırma varsa ve istemci açıkça istediyse yeniden başlat (başka hiçbir durumda tokensiz yeniden başlatma yok)
    if (r.reboot) {
        Snapshot s;
        SnapshotStore::instance().getState(s);
        bool pending = false;
        for (int i = 0; i < MAX_CHANNELS; i++) pending = pending || s.ch[i].hasPending;
        if (pending) {
            Command rb{};
            rb.type = CmdType::Reboot;
            rb.clientId = 0;
            if (!CommandProcessor::instance().enqueue(rb)) return false;
        }
    }
    return true;
}

// ── HTTP koruma katmanı ─────────────────────────────────────────────────────

bool WledCompat::allowRate(uint32_t ip) {
    uint32_t now = millis();
    RateEntry* slot = nullptr;
    RateEntry* oldest = &_rate[0];
    for (auto& e : _rate) {
        if (e.ip == ip) { slot = &e; break; }
        if (e.last < oldest->last) oldest = &e;
    }
    if (!slot) {
        slot = oldest;
        slot->ip = ip;
        slot->tokens = 20.0f;
        slot->last = now;
    }
    float el = (now - slot->last) / 1000.0f;
    slot->last = now;
    slot->tokens += el * 20.0f;       // sürekli 20 istek/sn
    if (slot->tokens > 20.0f) slot->tokens = 20.0f;   // patlama 20
    if (slot->tokens < 1.0f) return false;
    slot->tokens -= 1.0f;
    return true;
}

void WledCompat::sendJson(AsyncWebServerRequest* r, int code, const String& body) {
    AsyncWebServerResponse* resp = r->beginResponse(code, "application/json", body);
    resp->addHeader("Cache-Control", "no-store");
    r->send(resp);
}

void WledCompat::sendError(AsyncWebServerRequest* r, int code, const char* message) {
    String b = "{\"error\":";
    b += (code == 429 ? 3 : 1);
    b += ",\"message\":\"";
    b += message;
    b += "\"}";
    sendJson(r, code, b);
}

// Tüm WLED uç noktaları için ortak kontrol. false dönerse yanıt zaten gönderilmiştir.
bool WledCompat::guard(AsyncWebServerRequest* r, bool write, bool post) {
    if (!enabled()) {
        sendError(r, 403, "wled_compat_disabled");
        return false;
    }
    // Tarayıcı kaynaklı saldırılar (DNS rebinding / başka siteden CSRF)
    String host = r->hasHeader("Host") ? r->header("Host") : String("");
    if (!wled::hostAllowed(host.c_str(), MDNS_HOSTNAME)) {
        sendError(r, 403, "bad_host");
        return false;
    }
    String origin = r->hasHeader("Origin") ? r->header("Origin") : String("");
    if (!wled::originAllowed(origin.c_str(), host.c_str())) {
        sendError(r, 403, "cross_origin_denied");
        return false;
    }
    if (!allowRate(static_cast<uint32_t>(r->client()->remoteIP()))) {
        sendError(r, 429, "rate_limited");
        return false;
    }
    if (write && mode() != WledMode::Control) {
        sendError(r, 403, "wled_read_only");
        return false;
    }
    if (post && r->contentType().indexOf("json") < 0) {
        sendError(r, 415, "content_type_must_be_json");   // basit <form>/text-plain CSRF'ini engeller
        return false;
    }
    return true;
}

void WledCompat::collectBody(AsyncWebServerRequest* r, uint8_t* data, size_t len, size_t index, size_t total) {
    if (total == 0 || total > kBodyMax) return;   // handlePost 413 döner
    if (index == 0) {
        r->_tempObject = malloc(total + 1);
        if (r->_tempObject) static_cast<char*>(r->_tempObject)[0] = '\0';
    }
    if (!r->_tempObject) return;
    if (index + len <= total) {
        memcpy(static_cast<uint8_t*>(r->_tempObject) + index, data, len);
        if (index + len == total) static_cast<char*>(r->_tempObject)[total] = '\0';
    }
}

void WledCompat::handlePost(AsyncWebServerRequest* r) {
    if (!guard(r, true, true)) return;
    if (r->contentLength() > kBodyMax) { sendError(r, 413, "payload_too_large"); return; }
    if (r->contentLength() == 0 || r->_tempObject == nullptr) { sendError(r, 400, "empty_body"); return; }

    JsonDocument doc;
    if (deserializeJson(doc, static_cast<const char*>(r->_tempObject), r->contentLength()) || !doc.is<JsonObject>()) {
        sendError(r, 400, "bad_json");
        return;
    }
    Snapshot s;
    SnapshotStore::instance().getState(s);
    wled::View v = viewFromSnapshot(s);
    wled::ParseResult res = wled::parseState(doc.as<JsonObjectConst>(), v, esp_random());
    if (!enqueueChanges(v, res)) {
        sendError(r, 503, "busy");
        return;
    }
    if (res.verbose) {
        // Yanıt: uygulanmış durum (kuyruk asenkron işlendiği için eşleme görünümünden üretilir)
        JsonDocument out;
        wled::writeState(out.to<JsonObject>(), v);
        String body;
        serializeJson(out, body);
        sendJson(r, 200, body);
    } else {
        sendJson(r, 200, "{\"success\":true}");
    }
}

// ── Kök sayfa (/) ───────────────────────────────────────────────────────────
// off      : cihaz verisi içermeyen sabit bilgi sayfası (kontrol arayüzü YETKİSİZE sunulmaz)
// readonly : arayüz sunulur, kontroller devre dışı (sayfa info.access'i okur; sunucu yazmayı zaten 403'ler)
// control  : tam arayüz. Yazmalar mevcut /json/state ve /ws yollarından geçer (yeni yazma uç noktası YOK).
void WledCompat::serveRoot(AsyncWebServerRequest* r) {
    String host = r->hasHeader("Host") ? r->header("Host") : String("");
    if (!wled::hostAllowed(host.c_str(), MDNS_HOSTNAME)) {   // DNS rebinding
        r->send(403, "text/plain", "bad host");
        return;
    }
    if (!allowRate(static_cast<uint32_t>(r->client()->remoteIP()))) {
        r->send(429, "text/plain", "rate limited");
        return;
    }
    bool on = enabled();
    const char* page = on ? CONTROL_PAGE_HTML : OFF_PAGE_HTML;
    size_t len = (on ? sizeof(CONTROL_PAGE_HTML) : sizeof(OFF_PAGE_HTML)) - 1;
    AsyncWebServerResponse* resp = r->beginResponse(200, "text/html; charset=utf-8",
                                                    reinterpret_cast<const uint8_t*>(page), len);   // kopyasız (PROGMEM)
    resp->addHeader("Cache-Control", "no-store");
    resp->addHeader("X-Frame-Options", "DENY");
    String csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
                 "form-action 'none'; frame-ancestors 'none'; base-uri 'none'";
    if (on) csp += "; connect-src 'self' ws://" + host;   // host doğrulandı (IPv4 veya esp32-argb.local)
    resp->addHeader("Content-Security-Policy", csp);
    r->send(resp);
}

// ── Rotalar ────────────────────────────────────────────────────────────────

void WledCompat::registerRoutes(AsyncWebServer& server) {
    server.on("/json/state", HTTP_GET, [this](AsyncWebServerRequest* r) {
        if (guard(r, false, false)) sendJson(r, 200, buildState());
    });
    server.on("/json/info", HTTP_GET, [this](AsyncWebServerRequest* r) {
        if (guard(r, false, false)) sendJson(r, 200, buildInfo());
    });
    server.on("/json/si", HTTP_GET, [this](AsyncWebServerRequest* r) {
        if (guard(r, false, false)) sendJson(r, 200, buildSi());
    });
    server.on("/json/eff", HTTP_GET, [this](AsyncWebServerRequest* r) {
        if (!guard(r, false, false)) return;
        JsonDocument d;
        wled::writeEffects(d.to<JsonArray>());
        String b;
        serializeJson(d, b);
        sendJson(r, 200, b);
    });
    server.on("/json/pal", HTTP_GET, [this](AsyncWebServerRequest* r) {
        if (!guard(r, false, false)) return;
        JsonDocument d;
        wled::writePalettes(d.to<JsonArray>());
        String b;
        serializeJson(d, b);
        sendJson(r, 200, b);
    });
    server.on("/json/nodes", HTTP_GET, [this](AsyncWebServerRequest* r) {
        if (guard(r, false, false)) sendJson(r, 200, "{\"nodes\":[]}");
    });
    // SIRA ÖNEMLİDİR: ESPAsyncWebServer "/json" kaydını "/json/..." önekiyle de eşler ve ilk kayıtlı olan kazanır.
    // "/json" bu yüzden diğer tüm /json/* GET rotalarından SONRA kaydedilmelidir; aksi halde /json/eff,
    // /json/pal ve /json/nodes dizi yerine tam /json nesnesini döndürür (iPhone'da "Efekt listesi alınamadı").
    server.on("/json", HTTP_GET, [this](AsyncWebServerRequest* r) {
        if (guard(r, false, false)) sendJson(r, 200, buildFull());
    });

    // Yazma: /json/state ve /json (gövde = WLED durum nesnesi)
    auto onBody = [this](AsyncWebServerRequest* r, uint8_t* data, size_t len, size_t index, size_t total) {
        collectBody(r, data, len, index, total);
    };
    server.on("/json/state", HTTP_POST, [this](AsyncWebServerRequest* r) { handlePost(r); }, nullptr, onBody);
    server.on("/json", HTTP_POST, [this](AsyncWebServerRequest* r) { handlePost(r); }, nullptr, onBody);
}

// ── WebSocket (core 0, async_tcp) ───────────────────────────────────────────

void WledCompat::onWsConnect(AsyncWebSocketClient* client) {
    if (!enabled() || client == nullptr) return;
    if (ApiServer::instance().clientForeignOrigin(client->id())) return;   // tarayıcı kaynaklı: WLED yayını yok
    // WLED istemcileri bağlanınca anında {"state","info"} bekler. Bu istemci kendi protokolümüzle
    // (auth) yanıt verirse işaret kaldırılır.
    ApiServer::instance().setClientWled(client->id(), true);
    client->text(buildFrame());
}

bool WledCompat::handleWsPlain(AsyncWebSocketClient* client, const uint8_t* data, size_t len) {
    if (!enabled() || len != 1 || data[0] != 'p') return false;
    client->text("pong");   // WLED kalp atışı
    return true;
}

bool WledCompat::handleWsMessage(AsyncWebSocketClient* client, JsonObjectConst msg) {
    if (!enabled()) return false;

    if (ApiServer::instance().clientForeignOrigin(client->id())) {
        client->text("{\"error\":1,\"message\":\"cross_origin_denied\"}");   // WS CSRF/hijacking koruması
        return true;
    }
    bool wantsWrite = !msg["on"].isNull() || !msg["bri"].isNull() || !msg["seg"].isNull() || !msg["argb"].isNull();
    if (wantsWrite && mode() != WledMode::Control) {
        client->text("{\"error\":1,\"message\":\"wled_read_only\"}");
        return true;
    }

    Snapshot s;
    SnapshotStore::instance().getState(s);
    wled::View v = viewFromSnapshot(s);
    wled::ParseResult res = wled::parseState(msg, v, esp_random());
    if ((res.any() || res.reboot) && !enqueueChanges(v, res)) {
        client->text("{\"error\":3,\"message\":\"busy\"}");
        return true;
    }
    if (res.verbose) {
        // Yalnızca isteyen istemciye tam durum (WLED davranışı)
        JsonDocument d;
        wled::writeState(d["state"].to<JsonObject>(), v);
        fillInfo(d["info"].to<JsonObject>(), s, v);
        String out;
        serializeJson(d, out);
        client->text(out);
    }
    // Diğer istemcilere ve gönderene değişiklik tick() içinde yayınlanır
    if (res.any()) _dirty = true;
    return true;
}

#endif  // ENABLE_WLED_COMPAT
