#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>
#include "command.h"
#include "snapshot.h"

// JSON üreticiler (docs/PROTOCOL.md §5). Hiçbiri gizli bilgi (token, Wi-Fi şifresi) içermez.
namespace ApiJson {

// Etkin (render edilen) efektler — Stage 6'ya kadar
extern const char* const SUPPORTED_EFFECTS[];
extern const size_t SUPPORTED_EFFECTS_COUNT;

// Efekt adı geçerli mi? (effectTypeFromString bilinmeyen adı sessizce staticColor yapar; burada katı)
bool parseEffectName(const char* name, EffectType& out);

// channelMask: bit0..3 = kanal 1..4. partial=true ise yalnızca maskedeki kanallar yazılır.
String buildState(const Snapshot& s, uint8_t channelMask, bool partial);
String buildInfo(const Snapshot& s, const char* deviceName);
String buildAck(const char* reqId, uint32_t rev, bool rebootRequired);
String buildError(const char* reqId, const ErrorInfo& err);
String buildPong();

void writeChannel(JsonObject o, const ChannelSnapshot& c, uint8_t channelId);
const char* wifiModeString(const WifiSnapshot& w);
const char* wifiStateString(WiFiConnectionState st);

}  // namespace ApiJson
