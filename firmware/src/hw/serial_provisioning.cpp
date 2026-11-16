#include "serial_provisioning.h"
#include <ArduinoJson.h>
#include "device_id.h"
#include "network/wifi_manager.h"
#include "api/api_json.h"

SerialProvisioning& SerialProvisioning::instance() {
    static SerialProvisioning s;
    return s;
}

void SerialProvisioning::begin() {
    _len = 0;
    _overflow = false;
    _open = false;
}

void SerialProvisioning::openWindow(uint32_t durationMs) {
    _until = millis() + durationMs;
    _open = true;
    Serial.printf("[SerialSetup] Setup window OPEN for %u s (BOOT button).\n", (unsigned)(durationMs / 1000));
}

void SerialProvisioning::closeWindow() {
    if (_open) Serial.println("[SerialSetup] Setup window closed.");
    _open = false;
}

bool SerialProvisioning::isOpen() const {
    return _open && static_cast<int32_t>(_until - millis()) > 0;
}

uint32_t SerialProvisioning::remainingMs() const {
    return isOpen() ? (_until - millis()) : 0;
}

// ── Yanıt yardımcıları (tüm çıktılar "ARGB:" önekli tek satır JSON) ─────────

// Tek bir Serial.write ile gönderilir: başka görevlerin log satırlarıyla iç içe geçmesini azaltır.
static void sendDoc(const JsonDocument& d) {
    String out = "ARGB:";
    serializeJson(d, out);
    out += '\n';
    Serial.write(reinterpret_cast<const uint8_t*>(out.c_str()), out.length());
}

void SerialProvisioning::_replyError(const char* code) {
    JsonDocument d;
    d["v"] = API_PROTO_VERSION;
    d["type"] = "error";
    d["code"] = code;
    sendDoc(d);
}

void SerialProvisioning::_replyStatus(const char* type) {
    WiFiManager& w = WiFiManager::instance();
    JsonDocument d;
    d["v"] = API_PROTO_VERSION;
    d["type"] = type;
    d["deviceId"] = getDeviceId();
    d["fw"] = FIRMWARE_VERSION;
    d["window"] = isOpen();
    d["remainingMs"] = remainingMs();
    d["state"] = ApiJson::wifiStateString(w.getState());
    if (w.isConnected()) {
        d["ssid"] = w.getSSID();
        d["ip"] = w.getLocalIP();
    }
    String err = w.getLastError();
    if (err.length() > 0) d["error"] = err;
    sendDoc(d);
}

// ── Satır işleme ───────────────────────────────────────────────────────────

void SerialProvisioning::_handleLine(const char* line) {
    // DİKKAT: `line` şifre içerebilir; asla yazdırılmaz/loglanmaz.
    JsonDocument doc;
    if (deserializeJson(doc, line) || !doc.is<JsonObject>()) {
        _replyError("bad_json");
        return;
    }
    const char* cmd = doc["cmd"].is<const char*>() ? doc["cmd"].as<const char*>() : nullptr;
    if (cmd == nullptr) {
        _replyError("missing_cmd");
        return;
    }

    if (strcmp(cmd, "hello") == 0) { _replyStatus("hello"); return; }
    if (strcmp(cmd, "status") == 0) { _replyStatus("status"); return; }

    if (strcmp(cmd, "scan") == 0) {
        if (!isOpen()) {
            _open = false;
            _replyError("window_closed");
            return;
        }
        if (_scanning || !WiFiManager::instance().startScan()) {
            _replyError("scan_busy");
            return;
        }
        _scanning = true;
        _scanStarted = millis();
        JsonDocument r;
        r["v"] = API_PROTO_VERSION;
        r["type"] = "scanStarted";
        sendDoc(r);
        return;
    }

    if (strcmp(cmd, "wifi") == 0) {
        if (!isOpen()) {
            _open = false;
            _replyError("window_closed");   // fiziksel BOOT onayı yok
            return;
        }
        if (!doc["ssid"].is<const char*>()) { _replyError("invalid_ssid"); return; }
        const char* ssid = doc["ssid"].as<const char*>();
        const char* pass = doc["pass"].is<const char*>() ? doc["pass"].as<const char*>() : "";
        size_t sl = strlen(ssid), pl = strlen(pass);
        if (sl < 1 || sl > 32) { _replyError("invalid_ssid"); return; }
        if (pl > 63 || (pl > 0 && pl < 8)) { _replyError("invalid_password"); return; }

        // Kimlik bilgisi yalnızca bağlantı başarılı olunca NVS'e yazılır (WiFiManager).
        WiFiManager::instance().submitCredentials(String(ssid), String(pass));
        _watching = true;
        _lastReported = WiFiConnectionState::Disconnected;

        JsonDocument r;
        r["v"] = API_PROTO_VERSION;
        r["type"] = "wifiAccepted";
        sendDoc(r);
        return;
    }

    _replyError("unknown_cmd");
}

void SerialProvisioning::_event() {
    WiFiConnectionState st = WiFiManager::instance().getState();
    if (st == _lastReported) return;
    _lastReported = st;
    if (st == WiFiConnectionState::Connected) {
        _replyStatus("event");
        _watching = false;
        closeWindow();                      // başarılı kurulum: pencere kapanır
    } else if (st == WiFiConnectionState::ConnectionFailed) {
        _replyStatus("event");              // pencere açık kalır: yeniden deneme mümkün
        _watching = false;
    } else if (st == WiFiConnectionState::Connecting) {
        _replyStatus("event");
    }
}

// Tarama bitince sonucu tek satırlık "scanResult" olarak gönderir (SSID'ler şifre değildir).
void SerialProvisioning::_updateScan() {
    WiFiManager& w = WiFiManager::instance();
    if (w.isScanComplete()) {
        std::vector<DiscoveredNetwork> res = w.getScanResults();
        JsonDocument d;
        d["v"] = API_PROTO_VERSION;
        d["type"] = "scanResult";
        JsonArray arr = d["networks"].to<JsonArray>();
        for (const auto& n : res) {
            if (arr.size() >= SCAN_MAX_RESULTS) break;
            JsonObject o = arr.add<JsonObject>();
            o["ssid"] = n.ssid;
            o["rssi"] = n.rssi;
            o["security"] = n.security;
            o["channel"] = n.channel;
        }
        sendDoc(d);
        _scanning = false;
    } else if ((millis() - _scanStarted) > SCAN_TIMEOUT_MS) {
        w.cancelScan();
        _scanning = false;
        _replyError("scan_timeout");
    }
}

void SerialProvisioning::update() {
    if (_open && !isOpen()) closeWindow();   // süre doldu
    if (_scanning) _updateScan();

    if (_watching) _event();

    // Bloklamadan: turda en çok 64 bayt oku
    for (int i = 0; i < 64 && Serial.available() > 0; i++) {
        int c = Serial.read();
        if (c < 0) break;
        if (c == '\r') continue;
        if (c == '\n') {
            if (!_overflow && _len > 0) {
                _line[_len] = '\0';
                _handleLine(_line);
            } else if (_overflow) {
                _replyError("line_too_long");
            }
            // Bellekte şifre bırakma
            memset(_line, 0, sizeof(_line));
            _len = 0;
            _overflow = false;
            continue;
        }
        if (_len < SERIAL_SETUP_MAX_LINE) {
            _line[_len++] = static_cast<char>(c);
        } else {
            _overflow = true;
        }
    }
}
