#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <vector>
#include <functional>
#include "types.h"
#include "config.h"
#include "storage/nvs_storage.h"

// Wi-Fi bağlantı ve tarama yöneticisi (tek çekirdek/loop() içinden kullanılır).
//
// v0.3.1 tasarımı:
//  - Arduino çekirdeğinin otomatik yeniden bağlanması KAPALI (setAutoReconnect(false)).
//    Çekirdek açıkken her NO_AP_FOUND (201) sonrası ~2,9 sn'de bir kendiliğinden WiFi.begin()
//    çağırıyor, WiFiManager AP'ye düştükten sonra bile sonsuza dek sürüyordu. Bağlantı denemesi
//    sürerken sürücü kullanıcı taramasını reddettiğinden tarama hep "scan_busy" ile bitiyordu.
//  - Tüm STA denemeleri burada, aralarında WIFI_RETRY_BACKOFF_MS boşlukla yapılır.
//  - Tarama tek sahiplidir: HTTP ve seri tüketiciler aynı taramaya katılır (requestScan),
//    tamamlanmayı scanGeneration() artışıyla anlar ve sonucu getScanResults() ile kopyalar.
//  - Tarama sırasında süren STA denemesi duraklatılır, tarama bitince kaldığı yerden sürer.
//  - Başarısız/zaman aşımlı tarama denemesi SCAN_MAX_ATTEMPTS'e kadar otomatik tekrarlanır.
//  - Tarama bitişi sürücünün SCAN_DONE olayından (ve olaydaki durumdan) anlaşılır. Çekirdeğin scanComplete()
//    içindeki 20 x max_ms_per_chan (= 6 sn) zaman aşımı bir sürücü hatası DEĞİLDİR: AP+STA modunda tarama
//    ~6 sn sürer, çekirdek erken WIFI_SCAN_FAILED döndürürken sürücü taramaya devam eder. Bu sonuç yok sayılır;
//    yalnızca kendi bekçimiz (SCAN_ATTEMPT_TIMEOUT_MS) dolarsa tarama durdurulur.
class WiFiManager {
public:
    using StateChangeCallback = std::function<void(WiFiConnectionState, const String&)>;

    enum class ScanPhase : uint8_t { Idle, Running, Done, Failed };

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

    // Kurulum etkinliği (seri pencere, tarama, AP istemcisi): arka plan STA yeniden denemesini erteler.
    void holdBackgroundRetry(uint32_t ms = WIFI_STA_HOLD_MS);

    // ── Asynchronous Network Scanning ──────────────────────────────────────
    // Tarama başlatır; zaten sürüyorsa yeni radyo taraması BAŞLATMAZ, çağıran mevcut taramaya katılır.
    // false yalnızca Wi-Fi alt sistemi taramaya hiç uygun değilse döner.
    bool requestScan();
    bool isScanRunning() const { return _scanPhase == ScanPhase::Running; }
    ScanPhase getScanPhase() const { return _scanPhase; }
    // Her tamamlanan (başarılı veya başarısız) taramada bir artar.
    uint32_t scanGeneration() const { return _scanGen; }
    bool lastScanOk() const { return _scanPhase == ScanPhase::Done; }
    // Son başarılı taramanın kopyası (RSSI'ye göre azalan, gizli ağlar hariç, ≤ SCAN_MAX_RESULTS).
    std::vector<DiscoveredNetwork> getScanResults() const { return _scanResults; }

    // ── State Change Listener ──────────────────────────────────────────────
    void onStateChange(StateChangeCallback callback) { _stateCallback = callback; }

private:
    WiFiManager();

    void _setState(WiFiConnectionState newState, const String& detail = "");
    void _initApSSID();
    bool _ensureAp();

    // Bağlantı döngüsü
    void _startConnectCycle(const String& ssid, const String& password);
    void _beginAttempt();
    void _updateConnecting(uint32_t now);
    void _attemptFailed(uint32_t now);
    void _updateBackgroundRetry(uint32_t now);
    void _onStaDisconnected(uint8_t reason);
    void _onScanDone(uint32_t status, uint8_t number);

    // Tarama durum makinesi
    void _tryStartScan(uint32_t now);
    void _updateScan(uint32_t now);
    void _scanAttemptFailed(uint32_t now, const char* why);
    void _finishScan(bool ok, uint32_t now);
    void _collectScan(int16_t count);

    WiFiConnectionState _state;
    StateChangeCallback _stateCallback;

    String _targetSSID;
    String _targetPassword;
    String _apSSID;
    bool _apRunning;

    // Bağlantı
    bool _attemptRunning;       // WiFi.begin() verildi, sonuç bekleniyor
    uint32_t _connectStartTime;
    uint32_t _nextAttemptAt;    // _attemptRunning == false iken sonraki denemenin zamanı
    uint32_t _apShutdownAt;     // 0 = planlanmamış
    bool _pendingSave;          // kimlik bilgisi yalnızca bağlantı başarılı olunca NVS'e yazılır
    String _lastError;
    uint8_t _retryCount;
    uint32_t _fallbackAt;       // en son AP'ye düşülen an (arka plan yeniden denemesi için)
    uint32_t _holdUntil;        // bu ana kadar arka plan STA denemesi yapılmaz
    bool _eventsRegistered;

    // STA_DISCONNECTED olayı Wi-Fi olay görevinde gelir; yalnızca sayaç/neden yazılır.
    volatile uint32_t _discCount;
    volatile uint8_t _discReason;
    uint32_t _discCountAtStart;
    bool _backgroundCycle;      // AP'deyken kayıtlı ağın tek denemelik arka plan sınaması

    // Tarama
    ScanPhase _scanPhase;
    bool _scanInFlight;         // radyo taraması başlatıldı, scanComplete() izleniyor
    uint8_t _scanAttempt;
    uint32_t _scanAttemptStart;
    uint32_t _scanRetryAt;
    uint32_t _scanGen;
    std::vector<DiscoveredNetwork> _scanResults;
    bool _earlyTimeoutLogged;   // çekirdeğin erken WIFI_SCAN_FAILED'i bu denemede loglandı mı

    // SCAN_DONE olayı (Wi-Fi olay görevi): çekirdek sonuçları sakladıktan SONRA çağrılır.
    volatile uint32_t _scanDoneCount;
    volatile uint32_t _scanDoneStatus;   // 0 = sürücü başarılı, aksi halde sürücü hatası
    volatile uint8_t _scanDoneNumber;    // sürücünün bulduğu AP sayısı
    uint32_t _scanDoneAtStart;
};
