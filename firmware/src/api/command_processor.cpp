#include "command_processor.h"
#include "api_server.h"
#include "api_json.h"
#include "auth/auth_manager.h"
#include "led/channel_manager.h"
#include "network/wifi_manager.h"
#include "network/mdns_service.h"
#include "storage/nvs_storage.h"
#include "storage/persistence_scheduler.h"
#include "wled/wled_compat.h"

static bool sameState(const ChannelState& a, const ChannelState& b) {
    return a.isOn == b.isOn &&
           a.primaryColor == b.primaryColor &&
           a.secondaryColor == b.secondaryColor &&
           a.effectType == b.effectType &&
           a.brightness == b.brightness &&
           a.speed == b.speed &&
           a.direction == b.direction &&
           a.intensity == b.intensity;
}

CommandProcessor& CommandProcessor::instance() {
    static CommandProcessor p;
    return p;
}

void CommandProcessor::begin() {
    SnapshotStore::instance().begin();
    if (_queue == nullptr) {
        _queue = xQueueCreate(CMD_QUEUE_LENGTH, sizeof(Command));
    }
    _refreshSnapshot(true);
    Serial.printf("[Cmd] Command queue ready (%d slots x %u bytes).\n",
                  CMD_QUEUE_LENGTH, (unsigned)sizeof(Command));
}

bool CommandProcessor::enqueue(const Command& cmd) {
    if (_queue == nullptr) return false;
    if (xQueueSend(_queue, &cmd, 0) != pdTRUE) {
        _dropped++;
        return false;
    }
    return true;
}

// ════════════════════════════════════════════════════════════════════════════
//  Ana güncelleme (loop)
// ════════════════════════════════════════════════════════════════════════════

void CommandProcessor::update() {
    uint32_t now = millis();
    bool applied = false;

    for (int i = 0; i < CMD_MAX_PER_LOOP; i++) {
        Command cmd;
        if (xQueueReceive(_queue, &cmd, 0) != pdTRUE) break;
        _apply(cmd);
        memset(&cmd, 0, sizeof(cmd));   // Wi-Fi şifresi yığında kalmasın
        _processed++;
        applied = true;
    }

    _updateScan(now);

    // Eşleştirilmiş istemci sayısı değiştiyse mDNS "paired" TXT'sini güncelle
    size_t tc = AuthManager::instance().count();
    if (tc != _lastTokenCount) {
        _lastTokenCount = tc;
        MdnsService::instance().setPaired(tc > 0);
    }

    if (applied || (now - _lastSnapshot) >= SNAPSHOT_REFRESH_MS) {
        _refreshSnapshot(true);
    }

    _broadcastChanges(now);

    if (_rebootScheduled && static_cast<int32_t>(now - _rebootAt) >= 0) {
        Serial.println("[Cmd] Rebooting...");
        Serial.flush();
        delay(50);
        ESP.restart();
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  Komut yürütme
// ════════════════════════════════════════════════════════════════════════════

void CommandProcessor::_apply(Command& cmd) {
    switch (cmd.type) {
        case CmdType::Set:          _applySet(cmd); break;
        case CmdType::SetConfig:    _applyConfig(cmd); break;
        case CmdType::WifiConnect:  _applyWifiConnect(cmd); break;

        case CmdType::WifiScan: {
            if (WiFiManager::instance().startScan()) {
                _scanRunning = true;
                _scanStarted = millis();
            } else if (!_scanRunning) {
                static ScanSnapshot empty;
                empty.status = ScanStatus::Done;
                empty.count = 0;
                SnapshotStore::instance().setScan(empty);
            }
            break;
        }

        case CmdType::WifiReset:
            WiFiManager::instance().resetCredentialsAndStartAP();
            break;

        case CmdType::Reboot:
            _sendAck(cmd, false);
            scheduleReboot();
            break;

        case CmdType::FactoryReset:
            _sendAck(cmd, false);
            _factoryReset();
            break;

        case CmdType::GetState: {
            _refreshSnapshot(true);
            Snapshot s;
            SnapshotStore::instance().getState(s);
            ApiServer::instance().sendToClient(cmd.clientId, ApiJson::buildState(s, 0x0F, false));
            break;
        }

        case CmdType::GetInfo: {
            _refreshSnapshot(true);
            Snapshot s;
            SnapshotStore::instance().getState(s);
            ApiServer::instance().sendToClient(cmd.clientId,
                ApiJson::buildInfo(s, ApiServer::instance().deviceName().c_str()));
            break;
        }
    }
}

void CommandProcessor::_applySet(const Command& cmd) {
    bool anyChange = false;

    for (uint8_t i = 0; i < MAX_CHANNELS; i++) {
        if (!(cmd.chMask & (1 << i))) continue;
        LedChannel* ch = ChannelManager::instance().getChannel(i + 1);
        if (ch == nullptr) continue;

        ChannelState before = ch->getState();

        // save=false: kalıcılığı PersistenceScheduler (debounce) yönetir.
        // Bu setter'lar animasyon fazını/zamanlayıcıyı sıfırlamaz.
        if (cmd.fieldMask & F_POWER)     ch->setPower(cmd.power, false);
        if (cmd.fieldMask & F_COLOR)     ch->setColor(cmd.color, false);
        if (cmd.fieldMask & F_COLOR2)    ch->setSecondaryColor(cmd.color2, false);
        if (cmd.fieldMask & F_EFFECT)    ch->setEffect(cmd.effect, false);
        if (cmd.fieldMask & F_BRIGHT)    ch->setBrightness(cmd.brightness, false);
        if (cmd.fieldMask & F_SPEED)     ch->setSpeed(cmd.speed, false);
        if (cmd.fieldMask & F_DIRECTION) ch->setDirection(cmd.direction, false);
        if (cmd.fieldMask & F_INTENSITY) ch->setIntensity(cmd.intensity, false);

        if (!sameState(before, ch->getState())) {
            _changedMask |= (1 << i);
            PersistenceScheduler::instance().markStateDirty(i + 1);
            anyChange = true;
        }
    }

    if (anyChange) _rev++;
    _sendAck(cmd, false);
}

void CommandProcessor::_applyConfig(const Command& cmd) {
    uint8_t idx = cmd.cfgChannel - 1;
    LedChannel* ch = ChannelManager::instance().getChannel(cmd.cfgChannel);
    ErrorInfo err;
    if (ch == nullptr) {
        err.set(ApiError::InvalidValue, "ch");
        _sendError(cmd, err);
        return;
    }

    const ChannelConfig live = ch->getConfig();
    ChannelConfig base = _hasPending[idx] ? _pending[idx] : live;
    ChannelConfig next = base;

    if (cmd.cfgMask & CF_ENABLED)   next.enabled = cmd.cfgEnabled;
    if (cmd.cfgMask & CF_LEDCOUNT)  next.ledCount = cmd.cfgLedCount;
    if (cmd.cfgMask & CF_ORDER) {
        strncpy(next.colorOrder, cmd.cfgColorOrder, sizeof(next.colorOrder) - 1);
        next.colorOrder[sizeof(next.colorOrder) - 1] = '\0';
    }
    if (cmd.cfgMask & CF_MAXBRIGHT) next.maxBrightness = cmd.cfgMaxBrightness;
    next.gpioPin = live.gpioPin;    // pin derleme zamanlıdır (salt okunur)
    next.channelId = live.channelId;

    if (next.enabled && next.ledCount < 1) {
        err.set(ApiError::InvalidValue, "ledCount", "enabled channel needs >= 1 LED");
        _sendError(cmd, err);
        return;
    }

    // LED bütçesi
    uint32_t total = 0;
    for (uint8_t i = 0; i < MAX_CHANNELS; i++) {
        const ChannelConfig* c;
        if (i == idx) {
            c = &next;
        } else if (_hasPending[i]) {
            c = &_pending[i];
        } else {
            c = &ChannelManager::instance().getChannel(i + 1)->getConfig();
        }
        if (c->enabled) total += c->ledCount;
    }
    if (total > MAX_TOTAL_LEDS) {
        err.set(ApiError::LedBudgetExceeded, "ledCount", "total <= 1024");
        _sendError(cmd, err);
        return;
    }

    bool changed = next.enabled != base.enabled ||
                   next.ledCount != base.ledCount ||
                   next.maxBrightness != base.maxBrightness ||
                   strcmp(next.colorOrder, base.colorOrder) != 0;

    if (changed) {
        // maxBrightness canlı uygulanır; diğerleri yeniden başlatma gerektirir
        // (FastLED denetleyicileri çalışırken kaldırılamaz, LED tamponu yeniden ayrılamaz).
        ch->setMaxBrightness(next.maxBrightness);

        bool needsReboot = next.enabled != live.enabled ||
                           next.ledCount != live.ledCount ||
                           strcmp(next.colorOrder, live.colorOrder) != 0;
        _hasPending[idx] = needsReboot;
        if (needsReboot) _pending[idx] = next;

        PersistenceScheduler::instance().markConfigDirty(cmd.cfgChannel, next);
        _changedMask |= (1 << idx);
        _rev++;
    }
    _refreshSnapshot(true);
    _sendAck(cmd, _hasPending[idx]);
}

void CommandProcessor::_applyWifiConnect(Command& cmd) {
    // SSID/şifre loglanmaz (WiFiManager yalnızca SSID'yi yazar)
    WiFiManager::instance().submitCredentials(String(cmd.wifiSsid), String(cmd.wifiPassword));
    memset(cmd.wifiPassword, 0, sizeof(cmd.wifiPassword));
}

void CommandProcessor::_factoryReset() {
    Serial.println("[Cmd] FACTORY RESET requested.");
    PersistenceScheduler::instance().discardAll();
    AuthManager::instance().revokeAll();
    AuthManager::instance().closePairingWindow();
    NvsStorage::instance().resetAll();
    _rebootAt = millis() + 600;
    _rebootScheduled = true;
}

void CommandProcessor::securityReset() {
    Serial.println("[Cmd] SECURITY RESET: tokens and Wi-Fi credentials cleared.");
    AuthManager::instance().revokeAll();
    AuthManager::instance().closePairingWindow();
    WiFiManager::instance().resetCredentialsAndStartAP();
}

void CommandProcessor::scheduleReboot(uint32_t delayMs) {
    PersistenceScheduler::instance().flushAll();
    _rebootAt = millis() + delayMs;
    _rebootScheduled = true;
}

// ════════════════════════════════════════════════════════════════════════════
//  Yanıtlar, snapshot, yayın, tarama
// ════════════════════════════════════════════════════════════════════════════

void CommandProcessor::_sendAck(const Command& cmd, bool rebootRequired) {
    if (cmd.clientId == 0) return;
    ApiServer::instance().sendToClient(cmd.clientId, ApiJson::buildAck(cmd.reqId, _rev, rebootRequired));
}

void CommandProcessor::_sendError(const Command& cmd, const ErrorInfo& err) {
    if (cmd.clientId == 0) return;
    ApiServer::instance().sendToClient(cmd.clientId, ApiJson::buildError(cmd.reqId, err));
}

void CommandProcessor::_refreshSnapshot(bool force) {
    uint32_t now = millis();
    if (!force && (now - _lastSnapshot) < SNAPSHOT_REFRESH_MS) return;
    _lastSnapshot = now;

    Snapshot s{};
    s.rev = _rev;
    for (uint8_t i = 0; i < MAX_CHANNELS; i++) {
        LedChannel* ch = ChannelManager::instance().getChannel(i + 1);
        if (ch == nullptr) continue;
        s.ch[i].cfg = ch->getConfig();
        s.ch[i].st = ch->getState();
        s.ch[i].hasPending = _hasPending[i];
        if (_hasPending[i]) s.ch[i].pending = _pending[i];
    }

    WiFiManager& w = WiFiManager::instance();
    s.wifi.state = w.getState();
    s.wifi.apActive = w.isApActive();
    strncpy(s.wifi.ssid, w.getSSID().c_str(), sizeof(s.wifi.ssid) - 1);
    strncpy(s.wifi.ip, w.getLocalIP().c_str(), sizeof(s.wifi.ip) - 1);
    s.wifi.rssi = static_cast<int16_t>(w.getRSSI());
    strncpy(s.wifi.error, w.getLastError().c_str(), sizeof(s.wifi.error) - 1);

    s.uptimeMs = now;
    s.freeHeap = ESP.getFreeHeap();
    SnapshotStore::instance().setState(s);
}

void CommandProcessor::_broadcastChanges(uint32_t now) {
    if (_changedMask == 0) return;
    if ((now - _lastBroadcast) < STATE_BROADCAST_INTERVAL_MS) return;
    _lastBroadcast = now;

    Snapshot s;
    SnapshotStore::instance().getState(s);
    ApiServer::instance().broadcastAuthed(ApiJson::buildState(s, _changedMask, true));
#if ENABLE_WLED_COMPAT
    WledCompat::instance().notifyStateChanged();
#endif
    _changedMask = 0;
}

void CommandProcessor::_updateScan(uint32_t now) {
    if (!_scanRunning) return;

    static ScanSnapshot snap;   // yığını şişirmemek için statik
    WiFiManager& w = WiFiManager::instance();

    if (w.isScanComplete()) {
        std::vector<DiscoveredNetwork> res = w.getScanResults();
        snap.status = ScanStatus::Done;
        snap.count = 0;
        for (const auto& n : res) {
            if (snap.count >= SCAN_MAX_RESULTS) break;
            ScanNetwork& d = snap.nets[snap.count++];
            memset(&d, 0, sizeof(d));
            strncpy(d.ssid, n.ssid.c_str(), sizeof(d.ssid) - 1);
            d.rssi = static_cast<int8_t>(n.rssi);
            d.channel = static_cast<uint8_t>(n.channel);
            strncpy(d.security, n.security.c_str(), sizeof(d.security) - 1);
        }
        SnapshotStore::instance().setScan(snap);
        _scanRunning = false;
    } else if ((now - _scanStarted) > SCAN_TIMEOUT_MS) {
        w.cancelScan();
        snap.status = ScanStatus::Done;
        snap.count = 0;
        SnapshotStore::instance().setScan(snap);
        _scanRunning = false;
        Serial.println("[Cmd] Wi-Fi scan timed out.");
    }
}
