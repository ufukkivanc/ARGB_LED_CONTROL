#include "wifi_manager.h"
#include <esp_wifi.h>
#include <algorithm>

WiFiManager& WiFiManager::instance() {
    static WiFiManager manager;
    return manager;
}

WiFiManager::WiFiManager()
    : _state(WiFiConnectionState::Disconnected),
      _apRunning(false),
      _connectStartTime(0),
      _retryCount(0),
      _scanning(false),
      _lastScanTime(0) {
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

    // Check saved credentials from NVS
    String savedSSID, savedPass;
    if (NvsStorage::instance().loadWiFiCredentials(savedSSID, savedPass) && savedSSID.length() > 0) {
        Serial.printf("[WiFiManager] Found saved network credentials for SSID: '%s'\n", savedSSID.c_str());
        _targetSSID = savedSSID;
        _targetPassword = savedPass;
        _retryCount = 0;
        _startStaConnection(savedSSID, savedPass);
    } else {
        Serial.println("[WiFiManager] No Wi-Fi credentials stored. Starting Setup AP mode.");
        startSetupAP();
    }
}

void WiFiManager::_startStaConnection(const String& ssid, const String& password) {
    _targetSSID = ssid;
    _targetPassword = password;

    if (_apRunning) {
        WiFi.mode(WIFI_AP_STA);
    } else {
        WiFi.mode(WIFI_STA);
    }

    Serial.printf("[WiFiManager] Connecting to '%s' (Attempt %d/%d)...\n",
                  ssid.c_str(), _retryCount + 1, WIFI_MAX_RETRY_ATTEMPTS);

    WiFi.begin(ssid.c_str(), password.c_str());
    _connectStartTime = millis();
    _setState(WiFiConnectionState::Connecting, "Connecting to " + ssid);
}

void WiFiManager::startSetupAP() {
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
        _setState(WiFiConnectionState::AccessPointActive, "Setup AP active: " + _apSSID);
    } else {
        Serial.println("[WiFiManager] ERROR: Failed to start SoftAP!");
        _setState(WiFiConnectionState::ConnectionFailed, "Failed to start AP");
    }
}

void WiFiManager::update() {
    // ── Non-blocking Connection State Monitor ──────────────────────────────
    if (_state == WiFiConnectionState::Connecting) {
        if (WiFi.status() == WL_CONNECTED) {
            _connectStartTime = 0;
            _retryCount = 0;
            Serial.printf("[WiFiManager] Connected successfully! IP: %s, RSSI: %d dBm\n",
                          WiFi.localIP().toString().c_str(), WiFi.RSSI());

            // If AP was running purely for setup and connection succeeded, shut AP down to reduce 2.4 GHz RF load
            if (_apRunning) {
                WiFi.softAPdisconnect(true);
                WiFi.mode(WIFI_STA);
                _apRunning = false;
                Serial.println("[WiFiManager] Provisioning complete. Shutting down setup AP.");
            }

            _setState(WiFiConnectionState::Connected, "Connected to " + _targetSSID);
        } else if (millis() - _connectStartTime > WIFI_CONNECT_TIMEOUT_MS) {
            _retryCount++;
            Serial.printf("[WiFiManager] Connection timeout (attempt %d of %d)\n",
                          _retryCount, WIFI_MAX_RETRY_ATTEMPTS);

            if (_retryCount < WIFI_MAX_RETRY_ATTEMPTS) {
                _startStaConnection(_targetSSID, _targetPassword);
            } else {
                Serial.println("[WiFiManager] All connection attempts failed. Activating Setup AP.");
                _setState(WiFiConnectionState::ConnectionFailed, "Failed to connect to " + _targetSSID);
                if (!_apRunning) {
                    startSetupAP();
                }
            }
        }
    } else if (_state == WiFiConnectionState::Connected) {
        // Detect connection drops
        if (WiFi.status() != WL_CONNECTED) {
            Serial.println("[WiFiManager] Wi-Fi connection lost! Reconnecting...");
            _retryCount = 0;
            _startStaConnection(_targetSSID, _targetPassword);
        }
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

bool WiFiManager::submitCredentials(const String& ssid, const String& password) {
    if (ssid.length() == 0) {
        Serial.println("[WiFiManager] Cannot submit empty SSID");
        return false;
    }

    Serial.printf("[WiFiManager] New Wi-Fi credentials submitted for '%s'\n", ssid.c_str());

    // Save to NVS
    NvsStorage::instance().saveWiFiCredentials(ssid, password);

    // Reset attempt counter and initiate non-blocking connection
    _retryCount = 0;
    _startStaConnection(ssid, password);
    return true;
}

void WiFiManager::resetCredentialsAndStartAP() {
    Serial.println("[WiFiManager] Clearing Wi-Fi credentials and resetting to AP mode...");
    NvsStorage::instance().clearWiFiCredentials();
    WiFi.disconnect(true);
    _targetSSID = "";
    _targetPassword = "";
    startSetupAP();
}

bool WiFiManager::startScan() {
    if (_scanning) {
        return false;
    }

    // Ensure we are in at least STA mode to scan
    if (WiFi.getMode() == WIFI_MODE_NULL) {
        WiFi.mode(WIFI_AP_STA);
    }

    Serial.println("[WiFiManager] Starting async 2.4 GHz Wi-Fi scan...");
    int16_t status = WiFi.scanNetworks(true, false); // async = true, show_hidden = false
    if (status == WIFI_SCAN_RUNNING || status == 0) {
        _scanning = true;
        _lastScanTime = millis();
        return true;
    }
    return false;
}

bool WiFiManager::isScanComplete() {
    if (!_scanning) return false;
    int16_t status = WiFi.scanComplete();
    if (status >= 0) {
        _scanning = false;
        return true;
    }
    return false;
}

std::vector<DiscoveredNetwork> WiFiManager::getScanResults() {
    std::vector<DiscoveredNetwork> results;
    int16_t count = WiFi.scanComplete();

    if (count > 0) {
        results.reserve(count);
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
            results.push_back(net);
        }

        // Sort networks by signal strength (RSSI descending)
        std::sort(results.begin(), results.end(), [](const DiscoveredNetwork& a, const DiscoveredNetwork& b) {
            return a.rssi > b.rssi;
        });

        // Clean up scan results from memory
        WiFi.scanDelete();
    }

    _scanning = false;
    return results;
}

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
