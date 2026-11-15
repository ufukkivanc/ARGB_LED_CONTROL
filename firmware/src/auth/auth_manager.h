#pragma once

#include <Arduino.h>
#include <functional>
#include "config.h"

// Token tabanlı kimlik doğrulama ve eşleştirme.
//  - Token: 32 bayt donanım RNG -> 64 hex karakter. Cihaz yalnızca SHA-256 özetini saklar.
//  - Token yalnızca pair() çıktısında bir kez döner; log'a yazılmaz.
//  - Core 0 (async) ve core 1 (loop) tarafından çağrılabilir: iç mutex ile korunur.
//  - Kendi Preferences örneğini kullanır (NvsStorage'ın paylaşılan handle'ından bağımsız).
class AuthManager {
public:
    static constexpr size_t TOKEN_LEN = 64;   // hex karakter
    static constexpr size_t ID_LEN    = 8;
    static constexpr size_t NAME_LEN  = 24;

    struct TokenInfo {
        char id[ID_LEN + 1];
        char name[NAME_LEN + 1];
    };

    enum class PairResult : uint8_t { Ok, Closed, SlotsFull, Internal };

    using RevokeCallback = std::function<void(const char* tokenId)>;

    static AuthManager& instance();

    bool begin();

    // ── Eşleştirme penceresi (fiziksel onay: BOOT düğmesi ya da yetkili istemci) ──
    void openPairingWindow(uint32_t durationMs = PAIRING_WINDOW_MS);
    void closePairingWindow();
    bool isPairingOpen() const;
    uint32_t pairingRemainingMs() const;

    // Pencere kapalıyken yapılan eşleştirme denemelerini sınırlar (3/dk)
    bool pairAttemptAllowed();

    // tokenOut: en az 65, idOut: en az 9 bayt. bypassWindow yalnızca PAIRING_ALLOW_AP_FIRST_SETUP için.
    PairResult pair(const char* clientName, bool bypassWindow, char* tokenOut, char* idOut);

    // ── Doğrulama ──────────────────────────────────────────────────────────
    bool verify(const char* token, char* idOut = nullptr);

    // ── İptal ──────────────────────────────────────────────────────────────
    bool revoke(const char* tokenId);
    void revokeAll();
    void setRevokeCallback(RevokeCallback cb) { _revokeCb = cb; }

    size_t count();
    size_t list(TokenInfo* out, size_t maxItems);

    // ── Kaba kuvvet koruması (IP başına) ───────────────────────────────────
    bool isLocked(uint32_t ip, uint32_t* retryAfterMs = nullptr);
    void recordFailure(uint32_t ip);
    void recordSuccess(uint32_t ip);

private:
    AuthManager() = default;

    struct Slot {
        bool    used;
        uint8_t hash[32];
        char    id[ID_LEN + 1];
        char    name[NAME_LEN + 1];
    };

    struct Limiter {
        uint32_t ip;
        uint8_t  fails;
        uint8_t  level;
        uint32_t lockUntil;   // millis
        uint32_t lastSeen;
        bool     locked;
    };

    static void _sha256(const uint8_t* in, size_t len, uint8_t out[32]);
    static void _toHex(const uint8_t* in, size_t len, char* out);
    void _persistSlot(int idx);
    void _eraseSlot(int idx);

    SemaphoreHandle_t _mutex = nullptr;
    Slot _slots[AUTH_MAX_TOKENS] = {};
    Limiter _limiters[8] = {};

    volatile bool _pairingOpen = false;
    volatile uint32_t _pairingUntil = 0;

    uint32_t _pairWindowStart = 0;
    uint8_t  _pairAttempts = 0;

    RevokeCallback _revokeCb;
};
