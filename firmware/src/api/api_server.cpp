#include "api_server.h"
#include "api_json.h"
#include "command_processor.h"
#include "auth/auth_manager.h"
#include "device_id.h"
#include <WiFi.h>

ApiServer& ApiServer::instance() {
    static ApiServer server;
    return server;
}

ApiServer::ApiServer()
    : _server(HTTP_PORT),
      _ws(WS_ENDPOINT) {
    memset(_clients, 0, sizeof(_clients));
}

// ════════════════════════════════════════════════════════════════════════════
//  Başlatma
// ════════════════════════════════════════════════════════════════════════════

void ApiServer::begin(const String& deviceName) {
    if (_started) return;
    _deviceName = deviceName;
    _clientMutex = xSemaphoreCreateMutex();

    // Kimlik iptal edilince o token'a ait WebSocket bağlantılarını kapat
    AuthManager::instance().setRevokeCallback([this](const char* id) {
        closeClientsForToken(id);
    });

    // CORS (Flutter Web geliştirme ortamı için). Kimlik bilgisi çerezle değil
    // Authorization başlığıyla taşındığı için '*' kabul edilebilir.
    DefaultHeaders::Instance().addHeader("Access-Control-Allow-Origin", "*");
    DefaultHeaders::Instance().addHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
    DefaultHeaders::Instance().addHeader("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
    DefaultHeaders::Instance().addHeader("Access-Control-Allow-Private-Network", "true");

    _ws.onEvent([this](AsyncWebSocket* s, AsyncWebSocketClient* c, AwsEventType t,
                       void* arg, uint8_t* data, size_t len) {
        _onWsEvent(s, c, t, arg, data, len);
    });
    _server.addHandler(&_ws);

    _registerRoutes();

    _server.onNotFound([](AsyncWebServerRequest* r) {
        if (r->method() == HTTP_OPTIONS) {
            r->send(204);
        } else {
            r->send(404, "application/json", "{\"v\":1,\"type\":\"error\",\"code\":\"not_found\"}");
        }
    });

    _server.begin();
    _started = true;
    Serial.printf("[API] HTTP :%d and WebSocket %s started.\n", HTTP_PORT, WS_ENDPOINT);
}

void ApiServer::tick() {
    if (!_started) return;
    uint32_t now = millis();

    // Kimlik doğrulaması zamanında yapılmayan WS istemcilerini kapat
    uint32_t expired[WS_MAX_CLIENTS + 4];
    size_t n = 0;
    xSemaphoreTake(_clientMutex, portMAX_DELAY);
    for (auto& c : _clients) {
        if (c.used && !c.authed && (now - c.connectedAt) > WS_AUTH_TIMEOUT_MS && n < (sizeof(expired) / sizeof(expired[0]))) {
            expired[n++] = c.id;
        }
    }
    xSemaphoreGive(_clientMutex);
    for (size_t i = 0; i < n; i++) _ws.close(expired[i], 4401, "auth timeout");

    if (now - _lastCleanup > 2000) {
        _lastCleanup = now;
        _ws.cleanupClients(WS_MAX_CLIENTS);
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  WebSocket istemci tablosu
// ════════════════════════════════════════════════════════════════════════════

void ApiServer::_clientAdd(uint32_t id) {
    xSemaphoreTake(_clientMutex, portMAX_DELAY);
    for (auto& c : _clients) {
        if (!c.used) {
            memset(&c, 0, sizeof(c));
            c.used = true;
            c.id = id;
            c.connectedAt = millis();
            break;
        }
    }
    xSemaphoreGive(_clientMutex);
}

void ApiServer::_clientRemove(uint32_t id) {
    xSemaphoreTake(_clientMutex, portMAX_DELAY);
    for (auto& c : _clients) {
        if (c.used && c.id == id) { memset(&c, 0, sizeof(c)); break; }
    }
    xSemaphoreGive(_clientMutex);
}

size_t ApiServer::authedClientCount() {
    size_t n = 0;
    xSemaphoreTake(_clientMutex, portMAX_DELAY);
    for (auto& c : _clients) if (c.used && c.authed) n++;
    xSemaphoreGive(_clientMutex);
    return n;
}

void ApiServer::sendToClient(uint32_t clientId, const String& msg) {
    if (!_started || clientId == 0) return;
    AsyncWebSocketClient* c = _ws.client(clientId);
    if (c && c->status() == WS_CONNECTED && !c->queueIsFull()) {
        c->text(msg);
    }
}

void ApiServer::broadcastAuthed(const String& msg) {
    if (!_started) return;
    uint32_t ids[WS_MAX_CLIENTS + 4];
    size_t n = 0;
    xSemaphoreTake(_clientMutex, portMAX_DELAY);
    for (auto& c : _clients) {
        if (c.used && c.authed && n < (sizeof(ids) / sizeof(ids[0]))) ids[n++] = c.id;
    }
    xSemaphoreGive(_clientMutex);

    for (size_t i = 0; i < n; i++) {
        AsyncWebSocketClient* c = _ws.client(ids[i]);
        // Yavaş istemciyi atla: gecikmiş mesaj biriktirme
        if (c && c->status() == WS_CONNECTED && !c->queueIsFull()) c->text(msg);
    }
}

void ApiServer::closeClientsForToken(const char* tokenId) {
    if (!_started || tokenId == nullptr) return;
    uint32_t ids[WS_MAX_CLIENTS + 4];
    size_t n = 0;
    xSemaphoreTake(_clientMutex, portMAX_DELAY);
    for (auto& c : _clients) {
        if (c.used && c.authed && strncmp(c.tokenId, tokenId, 8) == 0 && n < (sizeof(ids) / sizeof(ids[0]))) {
            ids[n++] = c.id;
        }
    }
    xSemaphoreGive(_clientMutex);
    for (size_t i = 0; i < n; i++) _ws.close(ids[i], 4403, "token revoked");
}

// ════════════════════════════════════════════════════════════════════════════
//  WebSocket olayları
// ════════════════════════════════════════════════════════════════════════════

void ApiServer::_wsSendError(AsyncWebSocketClient* client, const char* reqId, const ErrorInfo& err) {
    if (client && client->status() == WS_CONNECTED) {
        client->text(ApiJson::buildError(reqId, err));
    }
}

void ApiServer::_onWsEvent(AsyncWebSocket*, AsyncWebSocketClient* client, AwsEventType type,
                           void* arg, uint8_t* data, size_t len) {
    switch (type) {
        case WS_EVT_CONNECT: {
            if (_ws.count() > WS_MAX_CLIENTS) {
                client->close(1013, "too many clients");
                return;
            }
            uint32_t ip = static_cast<uint32_t>(client->remoteIP());
            if (AuthManager::instance().isLocked(ip)) {
                client->close(4429, "rate limited");
                return;
            }
            _clientAdd(client->id());
            Serial.printf("[API] WS client %u connected (awaiting auth).\n", client->id());
            break;
        }
        case WS_EVT_DISCONNECT:
            _clientRemove(client->id());
            Serial.printf("[API] WS client %u disconnected.\n", client->id());
            break;
        case WS_EVT_DATA:
            _onWsData(client, arg, data, len);
            break;
        default:
            break;
    }
}

void ApiServer::_onWsData(AsyncWebSocketClient* client, void* arg, uint8_t* data, size_t len) {
    AwsFrameInfo* info = reinterpret_cast<AwsFrameInfo*>(arg);
    ErrorInfo err;

    if (info->len > WS_MAX_MESSAGE_BYTES || len > WS_MAX_MESSAGE_BYTES) {
        err.set(ApiError::PayloadTooLarge, nullptr, "max 1024 bytes");
        _wsSendError(client, nullptr, err);
        client->close(1009, "too large");
        return;
    }
    if (info->opcode != WS_TEXT || !info->final || info->index != 0 || info->len != len) {
        err.set(ApiError::BadJson, nullptr, "single text frame required");
        _wsSendError(client, nullptr, err);
        return;
    }

    JsonDocument doc;
    DeserializationError de = deserializeJson(doc, reinterpret_cast<const char*>(data), len);
    if (de || !doc.is<JsonObject>()) {
        err.set(ApiError::BadJson);
        _wsSendError(client, nullptr, err);
        return;
    }
    JsonObjectConst msg = doc.as<JsonObjectConst>();

    // İstek kimliği (hata yanıtlarında yansıtılır)
    char reqId[13] = {0};
    if (msg["id"].is<const char*>()) {
        strncpy(reqId, msg["id"].as<const char*>(), 12);
    }

    // Sürüm
    if (msg["v"].isNull()) {
        err.set(ApiError::MissingField, "v");
        _wsSendError(client, reqId, err);
        return;
    }
    if (!msg["v"].is<int>() || msg["v"].as<int>() != API_PROTO_VERSION) {
        err.set(ApiError::BadVersion, "v");
        _wsSendError(client, reqId, err);
        return;
    }

    const char* type = msg["type"].is<const char*>() ? msg["type"].as<const char*>() : nullptr;
    if (type == nullptr) {
        err.set(ApiError::MissingField, "type");
        _wsSendError(client, reqId, err);
        return;
    }

    if (strcmp(type, "ping") == 0) {
        client->text(ApiJson::buildPong());
        return;
    }

    uint32_t ip = static_cast<uint32_t>(client->remoteIP());

    // ── Kimlik doğrulama ───────────────────────────────────────────────────
    if (strcmp(type, "auth") == 0) {
        uint32_t retry = 0;
        if (AuthManager::instance().isLocked(ip, &retry)) {
            err.set(ApiError::RateLimited);
            _wsSendError(client, reqId, err);
            client->close(4429, "rate limited");
            return;
        }
        const char* token = msg["token"].is<const char*>() ? msg["token"].as<const char*>() : nullptr;
        char tokenId[9] = {0};
        if (token && AuthManager::instance().verify(token, tokenId)) {
            AuthManager::instance().recordSuccess(ip);
            xSemaphoreTake(_clientMutex, portMAX_DELAY);
            for (auto& c : _clients) {
                if (c.used && c.id == client->id()) {
                    c.authed = true;
                    strncpy(c.tokenId, tokenId, 8);
                    break;
                }
            }
            xSemaphoreGive(_clientMutex);

            JsonDocument ok;
            ok["v"] = API_PROTO_VERSION;
            ok["type"] = "authOk";
            ok["deviceId"] = getDeviceId();
            ok["tokenId"] = tokenId;
            String out;
            serializeJson(ok, out);
            client->text(out);

            // Ardından tam durum (snapshot'tan)
            Snapshot s;
            SnapshotStore::instance().getState(s);
            client->text(ApiJson::buildState(s, 0x0F, false));
            Serial.printf("[API] WS client %u authenticated.\n", client->id());
        } else {
            AuthManager::instance().recordFailure(ip);
            err.set(ApiError::Unauthorized);
            _wsSendError(client, reqId, err);
            client->close(4401, "unauthorized");
        }
        return;
    }

    // ── Kimlik doğrulaması olmadan hiçbir komut kabul edilmez ───────────────
    bool authed = false;
    xSemaphoreTake(_clientMutex, portMAX_DELAY);
    for (auto& c : _clients) {
        if (c.used && c.id == client->id()) { authed = c.authed; break; }
    }
    xSemaphoreGive(_clientMutex);
    if (!authed) {
        err.set(ApiError::Unauthorized);
        _wsSendError(client, reqId, err);
        return;
    }

    Command cmd{};
    if (!_parseCommand(msg, client->id(), true, cmd, err)) {
        _wsSendError(client, reqId, err);
        return;
    }
    if (!CommandProcessor::instance().enqueue(cmd)) {
        err.set(ApiError::Busy, nullptr, "command queue full");
        _wsSendError(client, reqId, err);
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  Komut ayrıştırma ve doğrulama (hepsi ya da hiçbiri)
// ════════════════════════════════════════════════════════════════════════════

bool ApiServer::_parseChannelMask(JsonVariantConst v, uint8_t& mask, ErrorInfo& err) {
    if (v.isNull()) {
        err.set(ApiError::MissingField, "ch");
        return false;
    }
    mask = 0;
    if (v.is<const char*>()) {
        if (strcmp(v.as<const char*>(), "all") == 0) { mask = 0x0F; return true; }
        err.set(ApiError::InvalidValue, "ch", "1..4, [..] or \"all\"");
        return false;
    }
    if (v.is<int>()) {
        int ch = v.as<int>();
        if (ch < 1 || ch > MAX_CHANNELS) { err.set(ApiError::InvalidValue, "ch", "1..4"); return false; }
        mask = 1 << (ch - 1);
        return true;
    }
    if (v.is<JsonArrayConst>()) {
        JsonArrayConst a = v.as<JsonArrayConst>();
        if (a.size() == 0 || a.size() > MAX_CHANNELS) { err.set(ApiError::InvalidValue, "ch"); return false; }
        for (JsonVariantConst e : a) {
            if (!e.is<int>() || e.as<int>() < 1 || e.as<int>() > MAX_CHANNELS) {
                err.set(ApiError::InvalidValue, "ch", "1..4");
                return false;
            }
            mask |= 1 << (e.as<int>() - 1);
        }
        return true;
    }
    err.set(ApiError::InvalidValue, "ch");
    return false;
}

bool ApiServer::_parseColor(JsonVariantConst v, const char* field, RgbColor& out, ErrorInfo& err) {
    if (!v.is<JsonObjectConst>()) {
        err.set(ApiError::InvalidValue, field, "{r,g,b}");
        return false;
    }
    JsonObjectConst o = v.as<JsonObjectConst>();
    const char* keys[3] = {"r", "g", "b"};
    int vals[3];
    for (int i = 0; i < 3; i++) {
        JsonVariantConst c = o[keys[i]];
        if (!c.is<int>() || c.as<int>() < 0 || c.as<int>() > 255) {
            err.set(ApiError::InvalidValue, field, "r,g,b 0..255");
            return false;
        }
        vals[i] = c.as<int>();
    }
    out = RgbColor(vals[0], vals[1], vals[2]);
    return true;
}

bool ApiServer::_parseCommand(JsonObjectConst msg, uint32_t clientId, bool allowQueries,
                              Command& cmd, ErrorInfo& err) {
    cmd = Command{};
    cmd.clientId = clientId;

    if (!msg["id"].isNull()) {
        if (!msg["id"].is<const char*>() || strlen(msg["id"].as<const char*>()) > 12) {
            err.set(ApiError::InvalidValue, "id", "string <= 12");
            return false;
        }
        strncpy(cmd.reqId, msg["id"].as<const char*>(), 12);
    }

    if (msg["v"].isNull()) { err.set(ApiError::MissingField, "v"); return false; }
    if (!msg["v"].is<int>() || msg["v"].as<int>() != API_PROTO_VERSION) {
        err.set(ApiError::BadVersion, "v");
        return false;
    }
    if (!msg["type"].is<const char*>()) { err.set(ApiError::MissingField, "type"); return false; }
    const char* type = msg["type"].as<const char*>();

    Snapshot snap;
    SnapshotStore::instance().getState(snap);

    // ── set ────────────────────────────────────────────────────────────────
    if (strcmp(type, "set") == 0) {
        cmd.type = CmdType::Set;
        if (!_parseChannelMask(msg["ch"], cmd.chMask, err)) return false;

        uint8_t enabledMask = 0;
        for (uint8_t i = 0; i < MAX_CHANNELS; i++) {
            if (snap.ch[i].cfg.enabled && snap.ch[i].cfg.ledCount > 0) enabledMask |= 1 << i;
        }
        bool isAll = msg["ch"].is<const char*>();
        if (isAll) {
            cmd.chMask &= enabledMask;
        } else if ((cmd.chMask & ~enabledMask) != 0) {
            err.set(ApiError::ChannelDisabled, "ch", "channel not enabled");
            return false;
        }
        if (cmd.chMask == 0) {
            err.set(ApiError::ChannelDisabled, "ch", "no enabled channel");
            return false;
        }

        if (!msg["power"].isNull()) {
            if (!msg["power"].is<bool>()) { err.set(ApiError::InvalidValue, "power", "bool"); return false; }
            cmd.power = msg["power"].as<bool>();
            cmd.fieldMask |= F_POWER;
        }
        if (!msg["color"].isNull()) {
            if (!_parseColor(msg["color"], "color", cmd.color, err)) return false;
            cmd.fieldMask |= F_COLOR;
        }
        if (!msg["color2"].isNull()) {
            if (!_parseColor(msg["color2"], "color2", cmd.color2, err)) return false;
            cmd.fieldMask |= F_COLOR2;
        }
        if (!msg["effect"].isNull()) {
            if (!msg["effect"].is<const char*>() ||
                !ApiJson::parseEffectName(msg["effect"].as<const char*>(), cmd.effect)) {
                err.set(ApiError::InvalidValue, "effect", "unknown effect");
                return false;
            }
            cmd.fieldMask |= F_EFFECT;
        }
        if (!msg["brightness"].isNull()) {
            JsonVariantConst v = msg["brightness"];
            if (!v.is<int>() || v.as<int>() < 0 || v.as<int>() > 255) {
                err.set(ApiError::InvalidValue, "brightness", "0..255");
                return false;
            }
            cmd.brightness = v.as<int>();
            cmd.fieldMask |= F_BRIGHT;
        }
        if (!msg["speed"].isNull()) {
            JsonVariantConst v = msg["speed"];
            if (!v.is<int>() || v.as<int>() < 1 || v.as<int>() > 100) {
                err.set(ApiError::InvalidValue, "speed", "1..100");
                return false;
            }
            cmd.speed = v.as<int>();
            cmd.fieldMask |= F_SPEED;
        }
        if (!msg["direction"].isNull()) {
            JsonVariantConst v = msg["direction"];
            if (!v.is<int>() || (v.as<int>() != 1 && v.as<int>() != -1)) {
                err.set(ApiError::InvalidValue, "direction", "-1 or 1");
                return false;
            }
            cmd.direction = v.as<int>();
            cmd.fieldMask |= F_DIRECTION;
        }
        if (!msg["intensity"].isNull()) {
            JsonVariantConst v = msg["intensity"];
            if (!v.is<int>() || v.as<int>() < 0 || v.as<int>() > 100) {
                err.set(ApiError::InvalidValue, "intensity", "0..100");
                return false;
            }
            cmd.intensity = v.as<int>();
            cmd.fieldMask |= F_INTENSITY;
        }
        if (cmd.fieldMask == 0) {
            err.set(ApiError::MissingField, nullptr, "at least one field required");
            return false;
        }
        return true;
    }

    // ── setChannelConfig ───────────────────────────────────────────────────
    if (strcmp(type, "setChannelConfig") == 0) {
        cmd.type = CmdType::SetConfig;
        uint8_t mask = 0;
        if (!_parseChannelMask(msg["ch"], mask, err)) return false;
        if (msg["ch"].is<const char*>() || msg["ch"].is<JsonArrayConst>() || (mask & (mask - 1)) != 0) {
            err.set(ApiError::InvalidValue, "ch", "single channel 1..4");
            return false;
        }
        uint8_t ch = 1;
        while (!(mask & 1)) { mask >>= 1; ch++; }
        cmd.cfgChannel = ch;

        if (!msg["enabled"].isNull()) {
            if (!msg["enabled"].is<bool>()) { err.set(ApiError::InvalidValue, "enabled", "bool"); return false; }
            cmd.cfgEnabled = msg["enabled"].as<bool>();
            cmd.cfgMask |= CF_ENABLED;
        }
        if (!msg["ledCount"].isNull()) {
            JsonVariantConst v = msg["ledCount"];
            if (!v.is<int>() || v.as<int>() < 0 || v.as<int>() > MAX_LEDS_PER_CHANNEL) {
                err.set(ApiError::InvalidValue, "ledCount", "0..512");
                return false;
            }
            cmd.cfgLedCount = v.as<int>();
            cmd.cfgMask |= CF_LEDCOUNT;
        }
        if (!msg["colorOrder"].isNull()) {
            if (!msg["colorOrder"].is<const char*>()) { err.set(ApiError::InvalidValue, "colorOrder"); return false; }
            const char* co = msg["colorOrder"].as<const char*>();
            if (strcasecmp(co, "GRB") == 0)      strcpy(cmd.cfgColorOrder, "GRB");
            else if (strcasecmp(co, "RGB") == 0) strcpy(cmd.cfgColorOrder, "RGB");
            else { err.set(ApiError::InvalidValue, "colorOrder", "GRB or RGB"); return false; }
            cmd.cfgMask |= CF_ORDER;
        }
        if (!msg["ledType"].isNull()) {
            if (!msg["ledType"].is<const char*>() || strcmp(msg["ledType"].as<const char*>(), "WS2812B") != 0) {
                err.set(ApiError::InvalidValue, "ledType", "only WS2812B");
                return false;
            }
        }
        if (!msg["maxBrightness"].isNull()) {
            JsonVariantConst v = msg["maxBrightness"];
            if (!v.is<int>() || v.as<int>() < 0 || v.as<int>() > 255) {
                err.set(ApiError::InvalidValue, "maxBrightness", "0..255");
                return false;
            }
            cmd.cfgMaxBrightness = v.as<int>();
            cmd.cfgMask |= CF_MAXBRIGHT;
        }
        if (cmd.cfgMask == 0) {
            err.set(ApiError::MissingField, nullptr, "at least one field required");
            return false;
        }
        return true;
    }

    if (allowQueries && strcmp(type, "getState") == 0) { cmd.type = CmdType::GetState; return true; }
    if (allowQueries && strcmp(type, "getInfo") == 0)  { cmd.type = CmdType::GetInfo;  return true; }
    if (strcmp(type, "reboot") == 0)                   { cmd.type = CmdType::Reboot;   return true; }

    err.set(ApiError::UnknownType, "type");
    return false;
}

// ════════════════════════════════════════════════════════════════════════════
//  HTTP yardımcıları
// ════════════════════════════════════════════════════════════════════════════

void ApiServer::_sendJson(AsyncWebServerRequest* r, int code, const String& body) {
    AsyncWebServerResponse* resp = r->beginResponse(code, "application/json", body);
    resp->addHeader("Cache-Control", "no-store");
    r->send(resp);
}

void ApiServer::_sendSimple(AsyncWebServerRequest* r, int code, const char* json) {
    _sendJson(r, code, String(json));
}

void ApiServer::_sendError(AsyncWebServerRequest* r, const ErrorInfo& err) {
    _sendJson(r, apiErrorHttpStatus(err.code), ApiJson::buildError(nullptr, err));
}

bool ApiServer::_enqueueOrError(AsyncWebServerRequest* r, const Command& cmd) {
    if (!CommandProcessor::instance().enqueue(cmd)) {
        ErrorInfo e;
        e.set(ApiError::Busy, nullptr, "command queue full");
        _sendError(r, e);
        return false;
    }
    return true;
}

void ApiServer::_collectBody(AsyncWebServerRequest* r, uint8_t* data, size_t len, size_t index, size_t total) {
    if (total == 0 || total > HTTP_MAX_BODY_BYTES) return;   // işleyici 413 döner
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

bool ApiServer::_parseBody(AsyncWebServerRequest* r, JsonDocument& doc, ErrorInfo& err, bool optional) {
    size_t cl = r->contentLength();
    if (cl > HTTP_MAX_BODY_BYTES) {
        err.set(ApiError::PayloadTooLarge, nullptr, "max 1024 bytes");
        return false;
    }
    if (cl == 0 || r->_tempObject == nullptr) {
        if (optional) { doc.to<JsonObject>(); return true; }
        err.set(ApiError::MissingField, nullptr, "JSON body required");
        return false;
    }
    DeserializationError de = deserializeJson(doc, static_cast<const char*>(r->_tempObject), cl);
    if (de || !doc.is<JsonObject>()) {
        err.set(ApiError::BadJson);
        return false;
    }
    return true;
}

bool ApiServer::_authHttp(AsyncWebServerRequest* r, char* tokenIdOut) {
    AuthManager& auth = AuthManager::instance();
    uint32_t ip = static_cast<uint32_t>(r->client()->remoteIP());
    ErrorInfo err;

    uint32_t retry = 0;
    if (auth.isLocked(ip, &retry)) {
        err.set(ApiError::RateLimited, nullptr, "too many failed attempts");
        AsyncWebServerResponse* resp = r->beginResponse(429, "application/json", ApiJson::buildError(nullptr, err));
        resp->addHeader("Retry-After", String(retry / 1000 + 1));
        r->send(resp);
        return false;
    }

    if (!r->hasHeader("Authorization")) {
        err.set(ApiError::Unauthorized);
        _sendError(r, err);
        return false;
    }

    String h = r->header("Authorization");
    const String prefix = "Bearer ";
    if (!h.startsWith(prefix) || !auth.verify(h.c_str() + prefix.length(), tokenIdOut)) {
        auth.recordFailure(ip);
        err.set(ApiError::Unauthorized);
        _sendError(r, err);
        return false;
    }
    auth.recordSuccess(ip);
    return true;
}

void ApiServer::_get(const char* path, bool needAuth, Handler h) {
    _server.on(path, HTTP_GET, [this, needAuth, h](AsyncWebServerRequest* r) {
        char tid[9] = {0};
        if (needAuth && !_authHttp(r, tid)) return;
        h(r, tid);
    });
}

void ApiServer::_post(const char* path, bool needAuth, Handler h) {
    _server.on(path, HTTP_POST,
        [this, needAuth, h](AsyncWebServerRequest* r) {
            char tid[9] = {0};
            if (needAuth && !_authHttp(r, tid)) return;
            h(r, tid);
        },
        nullptr,
        [this](AsyncWebServerRequest* r, uint8_t* data, size_t len, size_t index, size_t total) {
            _collectBody(r, data, len, index, total);
        });
}

// ════════════════════════════════════════════════════════════════════════════
//  Rotalar
// ════════════════════════════════════════════════════════════════════════════

void ApiServer::_registerRoutes() {

    // Herkese açık (token / SSID / IP içermez)
    _get ("/api/discover",      false, [this](AsyncWebServerRequest* r, const char* t) { _hDiscover(r, t); });
    // Eşleştirme penceresi (fiziksel onay) koşuluna bağlı
    _post("/api/pair",          false, [this](AsyncWebServerRequest* r, const char* t) { _hPair(r, t); });

    // Token zorunlu
    _post("/api/pair/open",     true,  [this](AsyncWebServerRequest* r, const char* t) { _hPairOpen(r, t); });
    _get ("/api/info",          true,  [this](AsyncWebServerRequest* r, const char* t) { _hInfo(r, t); });
    _get ("/api/state",         true,  [this](AsyncWebServerRequest* r, const char* t) { _hState(r, t); });
    _post("/api/command",       true,  [this](AsyncWebServerRequest* r, const char* t) { _hCommand(r, t); });
    _get ("/api/auth/tokens",   true,  [this](AsyncWebServerRequest* r, const char* t) { _hTokensList(r, t); });
    _get ("/api/wifi/scan",     true,  [this](AsyncWebServerRequest* r, const char* t) { _hWifiScanGet(r, t); });
    _post("/api/wifi/scan",     true,  [this](AsyncWebServerRequest* r, const char* t) { _hWifiScanStart(r, t); });
    _post("/api/wifi/connect",  true,  [this](AsyncWebServerRequest* r, const char* t) { _hWifiConnect(r, t); });
    _get ("/api/wifi/status",   true,  [this](AsyncWebServerRequest* r, const char* t) { _hWifiStatus(r, t); });
    _post("/api/wifi/reset",    true,  [this](AsyncWebServerRequest* r, const char* t) { _hWifiReset(r, t); });
    _post("/api/reboot",        true,  [this](AsyncWebServerRequest* r, const char* t) { _hReboot(r, t); });
    _post("/api/factory-reset", true,  [this](AsyncWebServerRequest* r, const char* t) { _hFactoryReset(r, t); });

    _server.on("/api/auth/tokens/*", HTTP_DELETE, [this](AsyncWebServerRequest* r) {
        char tid[9] = {0};
        if (!_authHttp(r, tid)) return;
        _hTokenRevoke(r, tid);
    });
}

// ════════════════════════════════════════════════════════════════════════════
//  Uç nokta gövdeleri
// ════════════════════════════════════════════════════════════════════════════

void ApiServer::_hDiscover(AsyncWebServerRequest* r, const char*) {
    Snapshot s;
    SnapshotStore::instance().getState(s);
    AuthManager& auth = AuthManager::instance();

    JsonDocument d;
    d["v"] = API_PROTO_VERSION;
    d["deviceId"] = getDeviceId();
    d["name"] = _deviceName;
    d["model"] = DEVICE_MODEL;
    d["fw"] = FIRMWARE_VERSION;
    d["proto"] = API_PROTO_VERSION;
    d["paired"] = auth.count() > 0;
    d["pairingOpen"] = auth.isPairingOpen();
    d["mode"] = ApiJson::wifiModeString(s.wifi);
    String out;
    serializeJson(d, out);
    _sendJson(r, 200, out);
}

void ApiServer::_hPair(AsyncWebServerRequest* r, const char*) {
    AuthManager& auth = AuthManager::instance();
    ErrorInfo err;

    bool bypass = false;
#if PAIRING_ALLOW_AP_FIRST_SETUP
    if (auth.count() == 0 && r->client()->localIP() == WiFi.softAPIP()) bypass = true;
#endif

    if (!bypass && !auth.isPairingOpen()) {
        if (!auth.pairAttemptAllowed()) {
            err.set(ApiError::RateLimited, nullptr, "too many attempts");
        } else {
            err.set(ApiError::PairingClosed, nullptr, "press BOOT for 3 s to open pairing");
        }
        _sendError(r, err);
        return;
    }

    JsonDocument body;
    if (!_parseBody(r, body, err, true)) { _sendError(r, err); return; }

    char name[AuthManager::NAME_LEN + 1] = {0};
    if (body["clientName"].is<const char*>()) {
        const char* src = body["clientName"].as<const char*>();
        size_t j = 0;
        for (size_t i = 0; src[i] && j < AuthManager::NAME_LEN; i++) {
            unsigned char c = static_cast<unsigned char>(src[i]);
            name[j++] = (c >= 0x20 && c <= 0x7E) ? static_cast<char>(c) : '_';
        }
    }

    char token[AuthManager::TOKEN_LEN + 1] = {0};
    char id[AuthManager::ID_LEN + 1] = {0};
    AuthManager::PairResult res = auth.pair(name, bypass, token, id);
    switch (res) {
        case AuthManager::PairResult::Ok: {
            JsonDocument d;
            d["token"] = token;      // yalnızca bu yanıtta, bir kez
            d["tokenId"] = id;
            d["deviceId"] = getDeviceId();
            String out;
            serializeJson(d, out);
            _sendJson(r, 200, out);
            break;
        }
        case AuthManager::PairResult::Closed:
            err.set(ApiError::PairingClosed);
            _sendError(r, err);
            break;
        case AuthManager::PairResult::SlotsFull:
            err.set(ApiError::SlotsFull, nullptr, "revoke a client first");
            _sendError(r, err);
            break;
        default:
            err.set(ApiError::Internal);
            _sendError(r, err);
            break;
    }
    memset(token, 0, sizeof(token));
}

void ApiServer::_hPairOpen(AsyncWebServerRequest* r, const char*) {
    AuthManager& auth = AuthManager::instance();
    auth.openPairingWindow();
    JsonDocument d;
    d["pairingOpen"] = true;
    d["remainingMs"] = auth.pairingRemainingMs();
    String out;
    serializeJson(d, out);
    _sendJson(r, 200, out);
}

void ApiServer::_hInfo(AsyncWebServerRequest* r, const char*) {
    Snapshot s;
    SnapshotStore::instance().getState(s);
    _sendJson(r, 200, ApiJson::buildInfo(s, _deviceName.c_str()));
}

void ApiServer::_hState(AsyncWebServerRequest* r, const char*) {
    Snapshot s;
    SnapshotStore::instance().getState(s);
    _sendJson(r, 200, ApiJson::buildState(s, 0x0F, false));
}

void ApiServer::_hCommand(AsyncWebServerRequest* r, const char*) {
    ErrorInfo err;
    JsonDocument body;
    if (!_parseBody(r, body, err, false)) { _sendError(r, err); return; }
    Command cmd{};
    if (!_parseCommand(body.as<JsonObjectConst>(), 0, false, cmd, err)) { _sendError(r, err); return; }
    if (!_enqueueOrError(r, cmd)) return;
    _sendSimple(r, 202, "{\"status\":\"queued\"}");
}

void ApiServer::_hTokensList(AsyncWebServerRequest* r, const char* tid) {
    AuthManager::TokenInfo items[AUTH_MAX_TOKENS];
    size_t n = AuthManager::instance().list(items, AUTH_MAX_TOKENS);
    JsonDocument d;
    JsonArray arr = d["tokens"].to<JsonArray>();
    for (size_t i = 0; i < n; i++) {
        JsonObject o = arr.add<JsonObject>();
        o["tokenId"] = items[i].id;
        o["clientName"] = items[i].name;
        o["current"] = strncmp(items[i].id, tid, 8) == 0;
    }
    String out;
    serializeJson(d, out);
    _sendJson(r, 200, out);
}

void ApiServer::_hTokenRevoke(AsyncWebServerRequest* r, const char*) {
    String url = r->url();
    String id = url.substring(url.lastIndexOf('/') + 1);
    ErrorInfo err;
    bool valid = id.length() == AuthManager::ID_LEN;
    for (size_t i = 0; valid && i < id.length(); i++) {
        char c = id[i];
        valid = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    }
    if (!valid) { err.set(ApiError::InvalidValue, "tokenId"); _sendError(r, err); return; }
    if (AuthManager::instance().revoke(id.c_str())) {
        _sendSimple(r, 200, "{\"revoked\":true}");
    } else {
        err.set(ApiError::NotFound, "tokenId");
        _sendError(r, err);
    }
}

void ApiServer::_hWifiScanStart(AsyncWebServerRequest* r, const char*) {
    Command cmd{};
    cmd.type = CmdType::WifiScan;
    if (!_enqueueOrError(r, cmd)) return;

    // İstemci eski "done" sonucunu görmesin diye hemen "running" işaretle
    ScanSnapshot* s = new (std::nothrow) ScanSnapshot();
    if (s) {
        s->status = ScanStatus::Running;
        s->count = 0;
        SnapshotStore::instance().setScan(*s);
        delete s;
    }
    _sendSimple(r, 202, "{\"status\":\"running\"}");
}

void ApiServer::_hWifiScanGet(AsyncWebServerRequest* r, const char*) {
    ScanSnapshot* s = new (std::nothrow) ScanSnapshot();
    if (!s) { ErrorInfo e; e.set(ApiError::Internal, nullptr, "out of memory"); _sendError(r, e); return; }
    SnapshotStore::instance().getScan(*s);

    JsonDocument d;
    d["status"] = (s->status == ScanStatus::Running) ? "running" : (s->status == ScanStatus::Done ? "done" : "idle");
    JsonArray arr = d["networks"].to<JsonArray>();
    for (uint8_t i = 0; i < s->count; i++) {
        JsonObject o = arr.add<JsonObject>();
        o["ssid"] = s->nets[i].ssid;
        o["rssi"] = s->nets[i].rssi;
        o["security"] = s->nets[i].security;
        o["channel"] = s->nets[i].channel;
    }
    delete s;
    String out;
    serializeJson(d, out);
    _sendJson(r, 200, out);
}

void ApiServer::_hWifiConnect(AsyncWebServerRequest* r, const char*) {
    ErrorInfo err;
    JsonDocument body;
    if (!_parseBody(r, body, err, false)) { _sendError(r, err); return; }

    if (!body["ssid"].is<const char*>()) { err.set(ApiError::MissingField, "ssid"); _sendError(r, err); return; }
    const char* ssid = body["ssid"].as<const char*>();
    size_t sl = strlen(ssid);
    if (sl < 1 || sl > 32) { err.set(ApiError::InvalidValue, "ssid", "1..32 chars"); _sendError(r, err); return; }

    const char* pass = "";
    if (!body["password"].isNull()) {
        if (!body["password"].is<const char*>()) { err.set(ApiError::InvalidValue, "password"); _sendError(r, err); return; }
        pass = body["password"].as<const char*>();
    }
    size_t pl = strlen(pass);
    if (pl > 63 || (pl > 0 && pl < 8)) {
        err.set(ApiError::InvalidValue, "password", "empty (open) or 8..63 chars");
        _sendError(r, err);
        return;
    }

    Command cmd{};
    cmd.type = CmdType::WifiConnect;
    strncpy(cmd.wifiSsid, ssid, sizeof(cmd.wifiSsid) - 1);
    strncpy(cmd.wifiPassword, pass, sizeof(cmd.wifiPassword) - 1);
    bool ok = _enqueueOrError(r, cmd);
    memset(&cmd, 0, sizeof(cmd));   // şifreyi yığında bırakma
    if (!ok) return;
    _sendSimple(r, 202, "{\"status\":\"connecting\"}");
}

void ApiServer::_hWifiStatus(AsyncWebServerRequest* r, const char*) {
    Snapshot s;
    SnapshotStore::instance().getState(s);
    JsonDocument d;
    d["state"] = ApiJson::wifiStateString(s.wifi.state);
    d["mode"] = ApiJson::wifiModeString(s.wifi);
    d["apActive"] = s.wifi.apActive;
    if (s.wifi.state == WiFiConnectionState::Connected) {
        d["ssid"] = s.wifi.ssid;
        d["ip"] = s.wifi.ip;
        d["rssi"] = s.wifi.rssi;
    }
    if (s.wifi.error[0]) d["error"] = s.wifi.error;
    String out;
    serializeJson(d, out);
    _sendJson(r, 200, out);
}

void ApiServer::_hWifiReset(AsyncWebServerRequest* r, const char*) {
    Command cmd{};
    cmd.type = CmdType::WifiReset;
    if (!_enqueueOrError(r, cmd)) return;
    _sendSimple(r, 202, "{\"status\":\"resetting\"}");
}

void ApiServer::_hReboot(AsyncWebServerRequest* r, const char*) {
    Command cmd{};
    cmd.type = CmdType::Reboot;
    if (!_enqueueOrError(r, cmd)) return;
    _sendSimple(r, 202, "{\"status\":\"rebooting\"}");
}

void ApiServer::_hFactoryReset(AsyncWebServerRequest* r, const char*) {
    ErrorInfo err;
    JsonDocument body;
    if (!_parseBody(r, body, err, false)) { _sendError(r, err); return; }
    if (!body["confirm"].is<const char*>() || strcmp(body["confirm"].as<const char*>(), "RESET") != 0) {
        err.set(ApiError::InvalidValue, "confirm", "must be \"RESET\"");
        _sendError(r, err);
        return;
    }
    Command cmd{};
    cmd.type = CmdType::FactoryReset;
    if (!_enqueueOrError(r, cmd)) return;
    _sendSimple(r, 202, "{\"status\":\"factory_reset\"}");
}
