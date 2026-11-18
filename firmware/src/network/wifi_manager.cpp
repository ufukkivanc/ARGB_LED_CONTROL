#include "wifi_manager.h"
#include <esp_wifi.h>
#include <algorithm>

// millis() taşmasına dayanıklı "zamanı geldi mi" karşılaştırması
static inline bool timeReached(uint32_t now, uint32_t at) {
    return static_cast<int32_t>(now - at) >= 0;
}

WiFiManager& WiFiManager::instance() {
    static WiFiManager manager;
    return manager;
}

WiFiManager::WiFiManager()
    : _state(WiFiConnectionState::Disconnected),
      _apRunning(false),
      _attemptRunning(false),
      _connectStartTime(0),
      _nextAttemptAt(0),
      _apShutdownAt(0),
      _pendingSave(false),
      _retryCount(0),
      _fallbackAt(0),
      _holdUntil(0),
      _eventsRegistered(false),
      _discCount(0),
      _discReason(0),
      _discCountAtStart(0),
      _backgroundCycle(false),
      _scanPhase(ScanPhase::Idle),
      _scanInFlight(false),
      _scanAttempt(0),
      _scanAttemptStart(0),
      _scanRetryAt(0),
      _scanGen(0),
      _earlyTimeoutLogged(false),
      _scanDoneCount(0),
      _scanDoneStatus(0),
      _scanDoneNumber(0),
      _scanDoneAtStart(0) {
    _initApSSID();
}

void WiFiManager::_initApSSID() {
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    char buf[32];
    snprintf(buf, sizeof(buf), "%s%02X%02X", AP_SSID_PREFIX, mac[4], mac[5]);
    _apSSID = String(buf);
}

void WiFiManager::begin() {
    Serial.println("[WiFiManager] Initializing Wi-Fi subsystems...");

    // Kimlik bilgileri uygulamanın kendi NVS alanında tutulur; IDF'nin ayrıca flash'a yazmasına gerek yok.
    WiFi.persistent(false);
    // KÖK NEDEN DÜZELTMESİ: çekirdeğin kendi yeniden bağlanma döngüsü kapatılır (bkz. wifi_manager.h).
    WiFi.setAutoReconnect(false);

    if (!_eventsRegistered) {
        _eventsRegistered = true;
        WiFi.onEvent([](WiFiEvent_t, WiFiEventInfo_t info) {
            WiFiManager::instance()._onStaDisconnected(info.wifi_sta_disconnected.reason);
        }, ARDUINO_EVENT_WIFI_STA_DISCONNECTED);
        WiFi.onEvent([](WiFiEvent_t, WiFiEventInfo_t info) {
            WiFiManager::instance()._onScanDone(info.wifi_scan_done.status, info.wifi_scan_done.number);
        }, ARDUINO_EVENT_WIFI_SCAN_DONE);
    }

    // Check saved credentials from NVS
    String savedSSID, savedPass;
    if (NvsStorage::instance().loadWiFiCredentials(savedSSID, savedPass) && savedSSID.length() > 0) {
        Serial.println("[WiFiManager] Found saved network credentials (not logged).");
        _startConnectCycle(savedSSID, savedPass);
    } else {
        Serial.println("[WiFiManager] No Wi-Fi credentials stored. Starting Setup AP mode.");
        startSetupAP();
    }
}

// Wi-Fi olay görevinden çağrılır: yalnızca neden + sayaç yazılır, durum makinesi loop()'ta işler.
void WiFiManager::_onStaDisconnected(uint8_t reason) {
    // ASSOC_LEAVE: kendi WiFi.disconnect() çağrımız (duraklatma/iptal) — deneme başarısızlığı sayılmaz.
    if (reason == WIFI_REASON_ASSOC_LEAVE) return;
    _discReason = reason;
    _discCount = _discCount + 1;
}

// Wi-Fi olay görevinden: yalnızca durum + sayaç yazılır (önce durum, sonra sayaç).
void WiFiManager::_onScanDone(uint32_t status, uint8_t number) {
    _scanDoneStatus = status;
    _scanDoneNumber = number;
    _scanDoneCount = _scanDoneCount + 1;
}

static const char* wifiModeName(wifi_mode_t m) {
    switch (m) {
        case WIFI_MODE_STA:   return "STA";
        case WIFI_MODE_AP:    return "AP";
        case WIFI_MODE_APSTA: return "AP_STA";
        default:              return "OFF";
    }
}

// ── Bağlantı döngüsü ───────────────────────────────────────────────────────

void WiFiManager::_startConnectCycle(const String& ssid, const String& password) {
    _targetSSID = ssid;
    _targetPassword = password;
    _retryCount = 0;
    _attemptRunning = false;
    _nextAttemptAt = millis();                 // hemen (tarama sürüyorsa tarama bitince)
    _setState(WiFiConnectionState::Connecting, "Connecting");
    if (!isScanRunning()) _beginAttempt();
}

void WiFiManager::_beginAttempt() {
    if (_apRunning) {
        WiFi.mode(WIFI_AP_STA);
    } else {
        WiFi.mode(WIFI_STA);
    }

    // SSID/şifre loglanmaz (kurulum bilgisi gizliliği)
    Serial.printf("[WiFiManager] Connecting to Wi-Fi (Attempt %d/%d)%s...\n",
                  _retryCount + 1, _backgroundCycle ? 1 : WIFI_MAX_RETRY_ATTEMPTS,
                  _backgroundCycle ? " [background]" : "");

    _discCountAtStart = _discCount;
    WiFi.begin(_targetSSID.c_str(), _targetPassword.c_str());
    _connectStartTime = millis();
    _attemptRunning = true;
}

void WiFiManager::_updateConnecting(uint32_t now) {
    // Tarama sürerken STA denemesi duraklatılmıştır (requestScan); tarama bitince sürer.
    if (isScanRunning()) return;

    if (!_attemptRunning) {
        if (timeReached(now, _nextAttemptAt)) _beginAttempt();
        return;
    }

    if (WiFi.status() == WL_CONNECTED) {
        _attemptRunning = false;
        _retryCount = 0;
        _backgroundCycle = false;
        Serial.printf("[WiFiManager] Connected successfully! IP: %s, RSSI: %d dBm\n",
                      WiFi.localIP().toString().c_str(), WiFi.RSSI());

        _lastError = "";

        // Kimlik bilgileri yalnızca başarılı bağlantıdan sonra kalıcı yazılır
        if (_pendingSave) {
            NvsStorage::instance().saveWiFiCredentials(_targetSSID, _targetPassword);
            _pendingSave = false;
        }

        // AP hemen kapatılmaz: uygulamanın sonucu okuyabilmesi için gecikmeli kapatılır
        if (_apRunning && _apShutdownAt == 0) {
            _apShutdownAt = now + AP_SHUTDOWN_DELAY_MS;
            Serial.printf("[WiFiManager] Provisioning complete. Setup AP will close in %d s.\n",
                          AP_SHUTDOWN_DELAY_MS / 1000);
        }

        _setState(WiFiConnectionState::Connected, "Connected");
        return;
    }

    // Sürücü denemeyi kesin olarak reddetti mi (NO_AP_FOUND, AUTH_FAIL ...)? 15 sn beklemeye gerek yok.
    bool rejected = (_discCount != _discCountAtStart);
    if (rejected || (now - _connectStartTime) > WIFI_CONNECT_TIMEOUT_MS) {
        _attemptFailed(now);
    }
}

void WiFiManager::_attemptFailed(uint32_t now) {
    bool rejected = (_discCount != _discCountAtStart);
    uint8_t reason = _discReason;

    if (rejected) {
        switch (reason) {
            case WIFI_REASON_NO_AP_FOUND:
                _lastError = "not_found"; break;
            case WIFI_REASON_AUTH_FAIL:
            case WIFI_REASON_AUTH_EXPIRE:
            case WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT:
            case WIFI_REASON_HANDSHAKE_TIMEOUT:
            case WIFI_REASON_802_1X_AUTH_FAILED:
                _lastError = "auth_failed"; break;
            default:
                _lastError = "timeout"; break;
        }
    } else {
        wl_status_t st = WiFi.status();
        if (st == WL_NO_SSID_AVAIL)        _lastError = "not_found";
        else if (st == WL_CONNECT_FAILED)  _lastError = "auth_failed";
        else                               _lastError = "timeout";
    }

    // Sürücüde süren (veya çekirdeğin tek seferlik ilk-bağlantı tekrarı) denemeyi durdur:
    // radyo bekleme süresince boş kalır, kullanıcı taraması ve SoftAP istemcileri etkilenmez.
    WiFi.disconnect(false, false);
    _attemptRunning = false;
    _retryCount++;

    uint8_t maxAttempts = _backgroundCycle ? 1 : WIFI_MAX_RETRY_ATTEMPTS;
    Serial.printf("[WiFiManager] Connection attempt %d of %d failed (%s, reason %u)\n",
                  _retryCount, maxAttempts, _lastError.c_str(), rejected ? reason : 0);

    if (_retryCount < maxAttempts) {
        _nextAttemptAt = now + WIFI_RETRY_BACKOFF_MS;
        return;
    }

    Serial.println(_backgroundCycle
                   ? "[WiFiManager] Background retry failed. Staying in Setup AP."
                   : "[WiFiManager] All connection attempts failed. Activating Setup AP.");
    _backgroundCycle = false;
    _pendingSave = false;                     // hatalı yeni bilgi asla kalıcı olmaz
    _fallbackAt = now;
    _ensureAp();
    // AP açık olsa da durum "failed" kalır: kurulum istemcileri başarısızlığı görebilsin.
    _setState(WiFiConnectionState::ConnectionFailed, "Failed to connect");
}

// AP'ye düşüldükten sonra kayıtlı ağ (ör. yeniden başlayan modem) arka planda tek denemeyle sınanır.
// Kurulum sürerken (AP istemcisi, seri pencere, tarama) yapılmaz: SoftAP kanal değiştirmesin.
void WiFiManager::_updateBackgroundRetry(uint32_t now) {
    if (_state != WiFiConnectionState::ConnectionFailed &&
        _state != WiFiConnectionState::AccessPointActive) return;
    if (!_apRunning || isScanRunning()) return;
    if (!timeReached(now, _holdUntil)) return;
    if ((now - _fallbackAt) < WIFI_BACKGROUND_RETRY_MS) return;

    _fallbackAt = now;                        // başarısız olursa tekrar tam aralık beklenir
    if (WiFi.softAPgetStationNum() > 0) return;

    String ssid, pass;
    if (!NvsStorage::instance().loadWiFiCredentials(ssid, pass) || ssid.length() == 0) return;

    _backgroundCycle = true;
    _pendingSave = false;
    _startConnectCycle(ssid, pass);
}

void WiFiManager::holdBackgroundRetry(uint32_t ms) {
    uint32_t until = millis() + ms;
    if (!timeReached(_holdUntil, until)) _holdUntil = until;   // yalnızca uzatır
}

// ── Ana döngü ──────────────────────────────────────────────────────────────

void WiFiManager::update() {
    uint32_t now = millis();

    _updateScan(now);

    if (_state == WiFiConnectionState::Connecting) {
        _updateConnecting(now);
    } else if (_state == WiFiConnectionState::Connected) {
        // Gecikmeli AP kapatma (tarama sürerken mod değiştirilmez)
        if (_apRunning && _apShutdownAt != 0 && timeReached(now, _apShutdownAt) && !isScanRunning()) {
            WiFi.softAPdisconnect(true);
            WiFi.mode(WIFI_STA);
            _apRunning = false;
            _apShutdownAt = 0;
            Serial.println("[WiFiManager] Setup AP shut down.");
        }

        // Detect connection drops
        if (WiFi.status() != WL_CONNECTED) {
            Serial.println("[WiFiManager] Wi-Fi connection lost! Reconnecting...");
            _backgroundCycle = false;
            _startConnectCycle(_targetSSID, _targetPassword);
        }
    } else {
        _updateBackgroundRetry(now);
    }
}

void WiFiManager::_setState(WiFiConnectionState newState, const String& detail) {
    if (_state != newState) {
        _state = newState;
        if (_stateCallback) {
            _stateCallback(_state, detail);
        }
    }
}

// ── SoftAP ─────────────────────────────────────────────────────────────────

bool WiFiManager::_ensureAp() {
    if (_apRunning) {
        if (!(WiFi.getMode() & WIFI_MODE_AP)) WiFi.mode(WIFI_AP_STA);
        return true;
    }
    WiFi.mode(WIFI_AP_STA);

    String password = NvsStorage::instance().getOrGenerateSetupPassword();

    WiFi.softAPConfig(AP_IP_ADDRESS, AP_IP_ADDRESS, AP_NETMASK);
    bool apSuccess = WiFi.softAP(_apSSID.c_str(), password.c_str(), AP_DEFAULT_CHANNEL, 0, AP_MAX_CONNECTIONS);

    if (apSuccess) {
        _apRunning = true;
        Serial.printf("[WiFiManager] ========================================\n");
        Serial.printf("[WiFiManager] Setup Access Point Started:\n");
        Serial.printf("[WiFiManager] SSID:     %s\n", _apSSID.c_str());
        Serial.printf("[WiFiManager] Password: %s (Device-Specific Secure Key)\n", password.c_str());
        Serial.printf("[WiFiManager] IP:       %s\n", WiFi.softAPIP().toString().c_str());
        Serial.printf("[WiFiManager] ========================================\n");
    } else {
        Serial.println("[WiFiManager] ERROR: Failed to start SoftAP!");
    }
    return apSuccess;
}

void WiFiManager::startSetupAP() {
    _attemptRunning = false;
    _backgroundCycle = false;
    _apRunning = false;                        // her zaman temiz yapılandır (sıfırlama yolu)
    if (_ensureAp()) {
        _setState(WiFiConnectionState::AccessPointActive, "Setup AP active: " + _apSSID);
    } else {
        _setState(WiFiConnectionState::ConnectionFailed, "Failed to start AP");
    }
}

bool WiFiManager::submitCredentials(const String& ssid, const String& password) {
    if (ssid.length() == 0) {
        Serial.println("[WiFiManager] Cannot submit empty SSID");
        return false;
    }

    Serial.println("[WiFiManager] New Wi-Fi credentials submitted (not logged).");

    // Süren (ör. arka plan) denemeyi bırak; yeni döngü temiz başlar.
    if (_attemptRunning) WiFi.disconnect(false, false);
    _attemptRunning = false;
    _backgroundCycle = false;

    // NVS'e yalnızca bağlantı başarılı olunca yazılır (hatalı şifre kalıcı olmasın)
    _pendingSave = true;
    _apShutdownAt = 0;
    _lastError = "";

    // Önceki durum zaten Connecting olabilir; kurulum istemcileri yeni döngüyü görsün.
    if (_state == WiFiConnectionState::Connecting) _setState(WiFiConnectionState::Disconnected);
    _startConnectCycle(ssid, password);
    return true;
}

void WiFiManager::resetCredentialsAndStartAP() {
    Serial.println("[WiFiManager] Clearing Wi-Fi credentials and resetting to AP mode...");
    NvsStorage::instance().clearWiFiCredentials();
    WiFi.disconnect(true);
    _targetSSID = "";
    _targetPassword = "";
    _pendingSave = false;
    _apShutdownAt = 0;
    startSetupAP();
}

// ── Tarama ─────────────────────────────────────────────────────────────────

bool WiFiManager::requestScan() {
    uint32_t now = millis();
    holdBackgroundRetry();

    if (_scanPhase == ScanPhase::Running) {
        Serial.println("[WiFiManager] Scan already running; request joined.");
        return true;
    }

    _scanPhase = ScanPhase::Running;
    _scanAttempt = 0;
    _scanInFlight = false;
    _scanRetryAt = now;

    // Bağlantı denemesi sürüyorsa duraklat: sürücü "connecting" durumunda kullanıcı taramasını reddeder.
    if (_state == WiFiConnectionState::Connecting && _attemptRunning) {
        Serial.println("[WiFiManager] Pausing STA connection attempt for scan.");
        WiFi.disconnect(false, false);
        _attemptRunning = false;
        _nextAttemptAt = now;                  // tarama biter bitmez aynı deneme yeniden başlar
        _scanRetryAt = now + 100;              // sürücünün bağlantıyı bırakması için kısa pay
        return true;
    }

    _tryStartScan(now);
    return true;
}

void WiFiManager::_tryStartScan(uint32_t now) {
    // Tarama STA arayüzü ister; AP açıksa AP korunur.
    wifi_mode_t mode = WiFi.getMode();
    if (!(mode & WIFI_MODE_STA)) {
        WiFi.mode((mode & WIFI_MODE_AP) ? WIFI_AP_STA : WIFI_STA);
    }

    _scanAttempt++;
    _earlyTimeoutLogged = false;
    _scanDoneAtStart = _scanDoneCount;          // bu andan sonraki SCAN_DONE bu denemeye aittir
    Serial.printf("[WiFiManager] Scan start: attempt %u/%u, mode=%s, sta=%s, %u ms/ch\n",
                  _scanAttempt, (unsigned)SCAN_MAX_ATTEMPTS, wifiModeName(WiFi.getMode()),
                  _state == WiFiConnectionState::Connected ? "connected" :
                  (_state == WiFiConnectionState::Connecting ? "paused" : "idle"),
                  (unsigned)SCAN_MS_PER_CHANNEL);
    WiFi.scanDelete();
    int16_t r = WiFi.scanNetworks(true /*async*/, false /*hidden*/, false /*passive*/, SCAN_MS_PER_CHANNEL);
    if (r == WIFI_SCAN_RUNNING || r >= 0) {
        _scanInFlight = true;
        _scanAttemptStart = now;
    } else {
        // esp_wifi_scan_start() reddetti: sürücüde tarama başlamadı, durdurulacak bir şey yok.
        _scanAttemptFailed(now, "start rejected by driver (scanNetworks=-2)");
    }
}

void WiFiManager::_updateScan(uint32_t now) {
    if (_scanPhase != ScanPhase::Running) return;

    if (!_scanInFlight) {
        if (timeReached(now, _scanRetryAt)) _tryStartScan(now);
        return;
    }

    uint32_t elapsed = now - _scanAttemptStart;

    // 1) Sürücü taramayı bitirdi (SCAN_DONE). Çekirdek sonuçları zaten sakladı.
    if (_scanDoneCount != _scanDoneAtStart) {
        uint32_t st = _scanDoneStatus;
        uint8_t found = _scanDoneNumber;
        if (st != 0) {
            char why[64];
            snprintf(why, sizeof(why), "SCAN_DONE status=%u (driver error)", (unsigned)st);
            _scanAttemptFailed(now, why);
            return;
        }
        int16_t n = WiFi.scanComplete();      // DONE biti set, _scanStarted=0 -> sayıyı döndürür
        if (n < 0) {
            Serial.printf("[WiFiManager] Scan done event but scanComplete()=%d (driver count %u)\n",
                          n, (unsigned)found);
            n = 0;
        }
        _collectScan(n);
        Serial.printf("[WiFiManager] Scan done: attempt %u, %u ms, status=0, driver=%u AP, listed=%u\n",
                      _scanAttempt, (unsigned)elapsed, (unsigned)found, (unsigned)_scanResults.size());
        _finishScan(true, now);
        return;
    }

    // 2) Çekirdeğin erken zaman aşımı: yalnızca loglanır, tarama İPTAL EDİLMEZ.
    if (!_earlyTimeoutLogged && WiFi.scanComplete() == WIFI_SCAN_FAILED) {
        _earlyTimeoutLogged = true;
        Serial.printf("[WiFiManager] scanComplete()=-2 at %u ms (Arduino 20x%u ms timeout, not a driver error); "
                      "waiting for SCAN_DONE\n", (unsigned)elapsed, (unsigned)SCAN_MS_PER_CHANNEL);
    }

    // 3) Gerçek bekçi: sürücü SCAN_DONE üretmedi.
    if (elapsed > SCAN_ATTEMPT_TIMEOUT_MS) {
        Serial.printf("[WiFiManager] Scan watchdog: no SCAN_DONE after %u ms, stopping driver scan\n",
                      (unsigned)elapsed);
        esp_wifi_scan_stop();                  // yalnızca burada: sürücü gerçekten takıldı
        _scanAttemptFailed(now, "watchdog timeout");
    }
}

void WiFiManager::_scanAttemptFailed(uint32_t now, const char* why) {
    _scanInFlight = false;
    WiFi.scanDelete();
    // Bağlı değilken sürücüde bir STA bağlantısı sürüyorsa bu bizim değildir (bizimki duraklatıldı):
    // ör. çekirdeğin açılıştaki tek seferlik "first_connect" tekrarı. Durdurulmazsa sonraki deneme de reddedilir.
    if (_state != WiFiConnectionState::Connected) WiFi.disconnect(false, false);
    Serial.printf("[WiFiManager] Scan attempt %u/%u failed: %s\n",
                  _scanAttempt, (unsigned)SCAN_MAX_ATTEMPTS, why);
    if (_scanAttempt < SCAN_MAX_ATTEMPTS) {
        _scanRetryAt = now + (uint32_t)SCAN_RETRY_DELAY_MS * _scanAttempt;
        return;
    }
    _finishScan(false, now);
}

void WiFiManager::_finishScan(bool ok, uint32_t now) {
    _scanInFlight = false;
    _scanPhase = ok ? ScanPhase::Done : ScanPhase::Failed;
    if (!ok) _scanResults.clear();
    _scanGen++;
    holdBackgroundRetry();                     // kullanıcı şimdi ağ seçecek
    if (ok) {
        Serial.printf("[WiFiManager] Scan result: OK, %u network(s), gen=%u\n",
                      (unsigned)_scanResults.size(), (unsigned)_scanGen);
    } else {
        Serial.printf("[WiFiManager] Scan result: FAILED after %u attempt(s), gen=%u\n",
                      _scanAttempt, (unsigned)_scanGen);
    }
    // Duraklatılmış bağlantı denemesi (varsa) _updateConnecting içinde _nextAttemptAt'te sürer.
    (void)now;
}

void WiFiManager::_collectScan(int16_t count) {
    _scanResults.clear();
    _scanResults.reserve(count);
    for (int16_t i = 0; i < count; i++) {
        String ssid = WiFi.SSID(i);
        if (ssid.length() == 0) continue; // Skip hidden/blank networks

        DiscoveredNetwork net;
        net.ssid = ssid;
        net.rssi = WiFi.RSSI(i);
        net.channel = WiFi.channel(i);

        switch (WiFi.encryptionType(i)) {
            case WIFI_AUTH_OPEN:            net.security = "OPEN"; break;
            case WIFI_AUTH_WEP:             net.security = "WEP"; break;
            case WIFI_AUTH_WPA_PSK:         net.security = "WPA_PSK"; break;
            case WIFI_AUTH_WPA2_PSK:        net.security = "WPA2_PSK"; break;
            case WIFI_AUTH_WPA_WPA2_PSK:    net.security = "WPA_WPA2_PSK"; break;
            case WIFI_AUTH_WPA2_ENTERPRISE: net.security = "WPA2_ENTERPRISE"; break;
            case WIFI_AUTH_WPA3_PSK:        net.security = "WPA3_PSK"; break;
            default:                        net.security = "UNKNOWN"; break;
        }
        _scanResults.push_back(net);
    }

    // Sort networks by signal strength (RSSI descending)
    std::sort(_scanResults.begin(), _scanResults.end(), [](const DiscoveredNetwork& a, const DiscoveredNetwork& b) {
        return a.rssi > b.rssi;
    });
    if (_scanResults.size() > SCAN_MAX_RESULTS) _scanResults.resize(SCAN_MAX_RESULTS);

    // Clean up scan results from driver memory
    WiFi.scanDelete();
}

// ── Sorgular ───────────────────────────────────────────────────────────────

String WiFiManager::getStateString() const {
    switch (_state) {
        case WiFiConnectionState::Disconnected:      return "Disconnected";
        case WiFiConnectionState::Connecting:        return "Connecting";
        case WiFiConnectionState::Connected:         return "Connected";
        case WiFiConnectionState::ConnectionFailed:  return "ConnectionFailed";
        case WiFiConnectionState::AccessPointActive: return "AccessPointActive";
        default:                                     return "Unknown";
    }
}

String WiFiManager::getLocalIP() const {
    return isConnected() ? WiFi.localIP().toString() : "";
}

String WiFiManager::getApIP() const {
    return _apRunning ? WiFi.softAPIP().toString() : "";
}

String WiFiManager::getSSID() const {
    return isConnected() ? WiFi.SSID() : "";
}

int32_t WiFiManager::getRSSI() const {
    return isConnected() ? WiFi.RSSI() : 0;
}

String WiFiManager::getMacAddress() const {
    return WiFi.macAddress();
}

String WiFiManager::getSetupPassword() const {
    return NvsStorage::instance().getOrGenerateSetupPassword();
}
