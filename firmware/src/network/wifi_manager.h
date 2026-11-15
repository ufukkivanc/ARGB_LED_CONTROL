#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <vector>
#include <functional>
#include "types.h"
#include "config.h"
#include "storage/nvs_storage.h"

class WiFiManager {
public:
    using StateChangeCallback = std::function<void(WiFiConnectionState, const String&)>;

    static WiFiManager& instance();

    void begin();
    void update(); // Called non-blockingly from main loop

    // ── State Queries ──────────────────────────────────────────────────────
    WiFiConnectionState getState() const { return _state; }
    String getStateString() const;
    bool isConnected() const { return _state == WiFiConnectionState::Connected; }
    bool isApActive() const { return _state == WiFiConnectionState::AccessPointActive || _apRunning; }

    String getLocalIP() const;
    String getApIP() const;
    String getSSID() const;
    int32_t getRSSI() const;
    String getMacAddress() const;
    String getApSSID() const { return _apSSID; }
    String getSetupPassword() const;
    String getLastError() const { return _lastError; }

    // ── Provisioning & Management ──────────────────────────────────────────
    bool submitCredentials(const String& ssid, const String& password);
    void resetCredentialsAndStartAP();
    void startSetupAP();

    // ── Asynchronous Network Scanning ──────────────────────────────────────
    bool startScan();
    bool isScanComplete();
    void cancelScan();
    std::vector<DiscoveredNetwork> getScanResults();

    // ── State Change Listener ──────────────────────────────────────────────
    void onStateChange(StateChangeCallback callback) { _stateCallback = callback; }

private:
    WiFiManager();

    void _setState(WiFiConnectionState newState, const String& detail = "");
    void _startStaConnection(const String& ssid, const String& password);
    void _initApSSID();

    WiFiConnectionState _state;
    StateChangeCallback _stateCallback;

    String _targetSSID;
    String _targetPassword;
    String _apSSID;
    bool _apRunning;

    uint32_t _connectStartTime;
    uint32_t _apShutdownAt;     // 0 = planlanmamış
    bool _pendingSave;          // kimlik bilgisi yalnızca bağlantı başarılı olunca NVS'e yazılır
    String _lastError;
    uint8_t _retryCount;

    bool _scanning;
    uint32_t _lastScanTime;
};
