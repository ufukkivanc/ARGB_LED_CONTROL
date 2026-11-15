#include "auth_manager.h"
#include "constants.h"
#include <Preferences.h>
#include <esp_system.h>
#include <mbedtls/sha256.h>

AuthManager& AuthManager::instance() {
    static AuthManager mgr;
    return mgr;
}

// ── Yardımcılar ────────────────────────────────────────────────────────────

void AuthManager::_sha256(const uint8_t* in, size_t len, uint8_t out[32]) {
    mbedtls_sha256_context ctx;
    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts_ret(&ctx, 0);
    mbedtls_sha256_update_ret(&ctx, in, len);
    mbedtls_sha256_finish_ret(&ctx, out);
    mbedtls_sha256_free(&ctx);
}

void AuthManager::_toHex(const uint8_t* in, size_t len, char* out) {
    static const char* hex = "0123456789abcdef";
    for (size_t i = 0; i < len; i++) {
        out[i * 2]     = hex[in[i] >> 4];
        out[i * 2 + 1] = hex[in[i] & 0x0F];
    }
    out[len * 2] = '\0';
}

static void slotKey(char* buf, size_t sz, int idx, char kind) {
    snprintf(buf, sz, "t%d%c", idx, kind);
}

void AuthManager::_persistSlot(int idx) {
    Preferences p;
    if (!p.begin(NVS_NS_AUTH, false)) return;
    char k[8];
    slotKey(k, sizeof(k), idx, 'h'); p.putBytes(k, _slots[idx].hash, 32);
    slotKey(k, sizeof(k), idx, 'i'); p.putString(k, _slots[idx].id);
    slotKey(k, sizeof(k), idx, 'n'); p.putString(k, _slots[idx].name);
    p.end();
}

void AuthManager::_eraseSlot(int idx) {
    Preferences p;
    if (p.begin(NVS_NS_AUTH, false)) {
        char k[8];
        slotKey(k, sizeof(k), idx, 'h'); p.remove(k);
        slotKey(k, sizeof(k), idx, 'i'); p.remove(k);
        slotKey(k, sizeof(k), idx, 'n'); p.remove(k);
        p.end();
    }
    memset(&_slots[idx], 0, sizeof(Slot));
}

// ── Başlatma ───────────────────────────────────────────────────────────────

bool AuthManager::begin() {
    if (_mutex == nullptr) _mutex = xSemaphoreCreateMutex();

    Preferences p;
    if (!p.begin(NVS_NS_AUTH, false)) {
        Serial.println("[Auth] ERROR: NVS namespace could not be opened.");
        return false;
    }

    xSemaphoreTake(_mutex, portMAX_DELAY);
    for (int i = 0; i < AUTH_MAX_TOKENS; i++) {
        char k[8];
        memset(&_slots[i], 0, sizeof(Slot));
        slotKey(k, sizeof(k), i, 'h');
        if (p.getBytesLength(k) == 32) {
            p.getBytes(k, _slots[i].hash, 32);
            slotKey(k, sizeof(k), i, 'i');
            String id = p.getString(k, "");
            slotKey(k, sizeof(k), i, 'n');
            String name = p.getString(k, "client");
            strncpy(_slots[i].id, id.c_str(), ID_LEN);
            strncpy(_slots[i].name, name.c_str(), NAME_LEN);
            _slots[i].used = id.length() == ID_LEN;
        }
    }
    xSemaphoreGive(_mutex);
    p.end();

    Serial.printf("[Auth] %u paired client(s) loaded.\n", (unsigned)count());
    return true;
}

// ── Eşleştirme penceresi ───────────────────────────────────────────────────

void AuthManager::openPairingWindow(uint32_t durationMs) {
    _pairingUntil = millis() + durationMs;
    _pairingOpen = true;
    Serial.printf("[Auth] Pairing window OPEN for %u s.\n", (unsigned)(durationMs / 1000));
}

void AuthManager::closePairingWindow() {
    if (_pairingOpen) Serial.println("[Auth] Pairing window closed.");
    _pairingOpen = false;
}

bool AuthManager::isPairingOpen() const {
    return _pairingOpen && static_cast<int32_t>(_pairingUntil - millis()) > 0;
}

uint32_t AuthManager::pairingRemainingMs() const {
    if (!isPairingOpen()) return 0;
    return _pairingUntil - millis();
}

bool AuthManager::pairAttemptAllowed() {
    uint32_t now = millis();
    xSemaphoreTake(_mutex, portMAX_DELAY);
    if (now - _pairWindowStart > 60000 || _pairAttempts == 0) {
        _pairWindowStart = now;
        _pairAttempts = 0;
    }
    bool ok = _pairAttempts < 3;
    if (ok) _pairAttempts++;
    xSemaphoreGive(_mutex);
    return ok;
}

AuthManager::PairResult AuthManager::pair(const char* clientName, bool bypassWindow,
                                           char* tokenOut, char* idOut) {
    if (!bypassWindow && !isPairingOpen()) return PairResult::Closed;

    xSemaphoreTake(_mutex, portMAX_DELAY);

    int freeIdx = -1;
    for (int i = 0; i < AUTH_MAX_TOKENS; i++) {
        if (!_slots[i].used) { freeIdx = i; break; }
    }
    if (freeIdx < 0) {
        xSemaphoreGive(_mutex);
        return PairResult::SlotsFull;
    }

    uint8_t raw[32];
    esp_fill_random(raw, sizeof(raw));
    _toHex(raw, sizeof(raw), tokenOut);
    memset(raw, 0, sizeof(raw));

    Slot& s = _slots[freeIdx];
    memset(&s, 0, sizeof(Slot));
    _sha256(reinterpret_cast<const uint8_t*>(tokenOut), TOKEN_LEN, s.hash);

    uint8_t idHash[32];
    _sha256(s.hash, 32, idHash);
    _toHex(idHash, ID_LEN / 2, s.id);

    strncpy(s.name, (clientName && clientName[0]) ? clientName : "client", NAME_LEN);
    s.used = true;

    // Kalıcı yaz; başarısızsa geri al
    _persistSlot(freeIdx);
    Preferences p;
    bool persisted = false;
    if (p.begin(NVS_NS_AUTH, true)) {
        char k[8];
        slotKey(k, sizeof(k), freeIdx, 'h');
        persisted = p.getBytesLength(k) == 32;
        p.end();
    }
    if (!persisted) {
        memset(&s, 0, sizeof(Slot));
        memset(tokenOut, 0, TOKEN_LEN + 1);
        xSemaphoreGive(_mutex);
        return PairResult::Internal;
    }

    strncpy(idOut, s.id, ID_LEN);
    idOut[ID_LEN] = '\0';
    xSemaphoreGive(_mutex);

    closePairingWindow();   // tek kullanımlık pencere
    Serial.printf("[Auth] Client paired (id=%s).\n", idOut);
    return PairResult::Ok;
}

// ── Doğrulama ──────────────────────────────────────────────────────────────

bool AuthManager::verify(const char* token, char* idOut) {
    if (token == nullptr || strlen(token) != TOKEN_LEN) return false;
    for (size_t i = 0; i < TOKEN_LEN; i++) {
        char c = token[i];
        bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        if (!hex) return false;
    }

    uint8_t h[32];
    _sha256(reinterpret_cast<const uint8_t*>(token), TOKEN_LEN, h);

    int found = -1;
    xSemaphoreTake(_mutex, portMAX_DELAY);
    for (int i = 0; i < AUTH_MAX_TOKENS; i++) {
        if (!_slots[i].used) continue;
        uint8_t diff = 0;
        for (int j = 0; j < 32; j++) diff |= (_slots[i].hash[j] ^ h[j]);   // sabit zamanlı
        if (diff == 0) found = i;
    }
    if (found >= 0 && idOut) {
        strncpy(idOut, _slots[found].id, ID_LEN);
        idOut[ID_LEN] = '\0';
    }
    xSemaphoreGive(_mutex);
    memset(h, 0, sizeof(h));
    return found >= 0;
}

// ── İptal ──────────────────────────────────────────────────────────────────

bool AuthManager::revoke(const char* tokenId) {
    if (tokenId == nullptr) return false;
    char removed[ID_LEN + 1] = {0};
    bool ok = false;

    xSemaphoreTake(_mutex, portMAX_DELAY);
    for (int i = 0; i < AUTH_MAX_TOKENS; i++) {
        if (_slots[i].used && strncmp(_slots[i].id, tokenId, ID_LEN) == 0) {
            strncpy(removed, _slots[i].id, ID_LEN);
            _eraseSlot(i);
            ok = true;
            break;
        }
    }
    xSemaphoreGive(_mutex);

    if (ok) {
        Serial.printf("[Auth] Token revoked (id=%s).\n", removed);
        if (_revokeCb) _revokeCb(removed);
    }
    return ok;
}

void AuthManager::revokeAll() {
    char removed[AUTH_MAX_TOKENS][ID_LEN + 1] = {};
    int n = 0;

    xSemaphoreTake(_mutex, portMAX_DELAY);
    for (int i = 0; i < AUTH_MAX_TOKENS; i++) {
        if (_slots[i].used) {
            strncpy(removed[n++], _slots[i].id, ID_LEN);
            _eraseSlot(i);
        }
    }
    xSemaphoreGive(_mutex);

    Serial.printf("[Auth] All tokens revoked (%d).\n", n);
    if (_revokeCb) {
        for (int i = 0; i < n; i++) _revokeCb(removed[i]);
    }
}

size_t AuthManager::count() {
    size_t n = 0;
    xSemaphoreTake(_mutex, portMAX_DELAY);
    for (int i = 0; i < AUTH_MAX_TOKENS; i++) if (_slots[i].used) n++;
    xSemaphoreGive(_mutex);
    return n;
}

size_t AuthManager::list(TokenInfo* out, size_t maxItems) {
    size_t n = 0;
    xSemaphoreTake(_mutex, portMAX_DELAY);
    for (int i = 0; i < AUTH_MAX_TOKENS && n < maxItems; i++) {
        if (!_slots[i].used) continue;
        strncpy(out[n].id, _slots[i].id, ID_LEN);
        out[n].id[ID_LEN] = '\0';
        strncpy(out[n].name, _slots[i].name, NAME_LEN);
        out[n].name[NAME_LEN] = '\0';
        n++;
    }
    xSemaphoreGive(_mutex);
    return n;
}

// ── Kaba kuvvet koruması ───────────────────────────────────────────────────

bool AuthManager::isLocked(uint32_t ip, uint32_t* retryAfterMs) {
    uint32_t now = millis();
    bool locked = false;
    xSemaphoreTake(_mutex, portMAX_DELAY);
    for (auto& l : _limiters) {
        if (l.ip == ip && l.ip != 0 && l.locked) {
            int32_t remain = static_cast<int32_t>(l.lockUntil - now);
            if (remain > 0) {
                locked = true;
                if (retryAfterMs) *retryAfterMs = remain;
            } else {
                l.locked = false;
                l.fails = 0;
            }
            break;
        }
    }
    xSemaphoreGive(_mutex);
    return locked;
}

void AuthManager::recordFailure(uint32_t ip) {
    uint32_t now = millis();
    xSemaphoreTake(_mutex, portMAX_DELAY);

    Limiter* target = nullptr;
    Limiter* oldest = &_limiters[0];
    for (auto& l : _limiters) {
        if (l.ip == ip) { target = &l; break; }
        if (l.lastSeen < oldest->lastSeen) oldest = &l;
    }
    if (!target) {
        target = oldest;
        memset(target, 0, sizeof(Limiter));
        target->ip = ip;
    }
    target->lastSeen = now;
    target->fails++;
    if (target->fails >= AUTH_FAIL_LIMIT) {
        uint32_t lockMs = AUTH_LOCK_BASE_MS;
        for (uint8_t i = 0; i < target->level && lockMs < AUTH_LOCK_MAX_MS; i++) lockMs *= 2;
        if (lockMs > AUTH_LOCK_MAX_MS) lockMs = AUTH_LOCK_MAX_MS;
        target->lockUntil = now + lockMs;
        target->locked = true;
        target->fails = 0;
        if (target->level < 8) target->level++;
        Serial.printf("[Auth] Client locked out for %u s after repeated failures.\n", (unsigned)(lockMs / 1000));
    }
    xSemaphoreGive(_mutex);
}

void AuthManager::recordSuccess(uint32_t ip) {
    xSemaphoreTake(_mutex, portMAX_DELAY);
    for (auto& l : _limiters) {
        if (l.ip == ip) { memset(&l, 0, sizeof(Limiter)); break; }
    }
    xSemaphoreGive(_mutex);
}
