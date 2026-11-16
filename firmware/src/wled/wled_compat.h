#pragma once

#include "config.h"

#if ENABLE_WLED_COMPAT

#include <Arduino.h>
#include <ArduinoJson.h>
#include <ESPAsyncWebServer.h>

// WLED (iOS/Android uygulaması) uyumluluk katmanı — docs/WLED_COMPAT.md
//
// ERİŞİM MODELİ (token sisteminin yerine GEÇMEZ; ayrı ve açıkça seçilen bir istisnadır):
//   Off      (varsayılan) : /json/* ve WLED WebSocket kapalı, mDNS _wled._tcp yayınlanmaz.
//   ReadOnly              : /json/* GET ve WS durum yayını TOKENSİZ açık; yazma 403.
//   Control               : ReadOnly + on/bri/seg(col,fx,sx,ix,rev) yazma TOKENSİZ açık.
// Modu yalnızca token sahibi (POST /api/wled) değiştirebilir; Control'e geçmek ek olarak
// fiziksel BOOT onayı ister. WLED istemcileri token gönderemediği için bu mod, aynı yerel ağdaki
// herkese LED kontrolü verir (bkz. belge: güvenlik sınırları).
//
// Bilerek YOK: /update (OTA), /settings*, cfg yazma, Wi-Fi/ağ ayarı, ön ayar (preset) yazma, reboot.
enum class WledMode : uint8_t { Off = 0, ReadOnly = 1, Control = 2 };

const char* wledModeName(WledMode m);
bool wledModeFromName(const char* s, WledMode& out);

class WledCompat {
public:
    static WledCompat& instance();

    // loop() tarafı (core 1)
    void begin();
    void tick();
    void notifyStateChanged();   // CommandProcessor çağırır

    // core 0 (async) tarafı
    void registerRoutes(AsyncWebServer& server);
    void serveRoot(AsyncWebServerRequest* r);   // GET /  (mod off: bilgi sayfası, aksi halde kontrol arayüzü)
    void onWsConnect(AsyncWebSocketClient* client);
    bool handleWsPlain(AsyncWebSocketClient* client, const uint8_t* data, size_t len);   // "p" -> "pong"
    bool handleWsMessage(AsyncWebSocketClient* client, JsonObjectConst msg);

    WledMode mode() const { return static_cast<WledMode>(_mode); }
    bool enabled() const { return mode() != WledMode::Off; }

    // Yetki kontrolünü ÇAĞIRAN yapar (ApiServer: token + Control için BOOT onayı).
    bool setMode(WledMode m);

private:
    WledCompat() = default;

    struct RateEntry {
        uint32_t ip;
        float tokens;
        uint32_t last;
    };

    bool guard(AsyncWebServerRequest* r, bool write, bool post);
    bool allowRate(uint32_t ip);
    void sendJson(AsyncWebServerRequest* r, int code, const String& body);
    void sendError(AsyncWebServerRequest* r, int code, const char* message);
    void collectBody(AsyncWebServerRequest* r, uint8_t* data, size_t len, size_t index, size_t total);
    void handlePost(AsyncWebServerRequest* r);

    String buildState();
    String buildInfo();
    String buildSi();
    String buildFull();
    String buildFrame();

    volatile uint8_t _mode = 0;
    volatile bool _dirty = false;
    volatile bool _mdnsDirty = true;
    uint32_t _lastPush = 0;
    RateEntry _rate[8] = {};
};

#endif  // ENABLE_WLED_COMPAT
