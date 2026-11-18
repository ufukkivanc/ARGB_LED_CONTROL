import 'package:argb_controller/models/device_state.dart';
import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/led_color.dart';

/// docs/PROTOCOL.md ile birebir uyumlu tel (wire) modelleri.
/// Hiçbir model token veya Wi-Fi şifresi için toString() üretmez.

const int kProtocolVersion = 1;
const int kMaxChannels = 4;

/// Hız (1..100) -> animasyon periyodu (ms). Firmware (animation_engine.cpp) ile AYNI formül:
/// 1 => 5000 ms (yavaş), 100 => 500 ms (hızlı); tamsayı bölmesi korunur.
int speedToPeriodMs(int speed) {
  final s = speed.clamp(1, 100);
  final ms = 5000 - (((s - 1) * 4500) ~/ 99);
  return ms < 200 ? 200 : ms;
}

/// Efekt adından güvenli ayrıştırma (bilinmeyen -> null).
EffectType? effectTypeFromName(String? name) {
  if (name == null) return null;
  for (final t in EffectType.values) {
    if (t.name == name) return t;
  }
  return null;
}

/// Telde renk: yalnızca {r,g,b}.
Map<String, int> colorToWire(LedColor c) => {'r': c.r, 'g': c.g, 'b': c.b};

LedColor? colorFromWire(dynamic v) {
  if (v is! Map) return null;
  final r = v['r'], g = v['g'], b = v['b'];
  if (r is! num || g is! num || b is! num) return null;
  return LedColor(
    r: r.toInt().clamp(0, 255),
    g: g.toInt().clamp(0, 255),
    b: b.toInt().clamp(0, 255),
  );
}

/// Yeniden başlatma bekleyen kanal yapılandırması.
class PendingChannelConfig {
  final bool enabled;
  final int ledCount;
  final String colorOrder;
  const PendingChannelConfig({
    required this.enabled,
    required this.ledCount,
    required this.colorOrder,
  });
}

/// Bir kanalın cihazdaki tam durumu (state mesajındaki `channels[]` öğesi).
class ChannelState {
  final int ch;
  final bool enabled;
  final int ledCount;
  final bool power;
  final LedColor color;
  final LedColor color2;
  final EffectType effect;
  final int brightness;
  final int speed;
  final int direction;
  final int intensity;
  final List<LedColor> palette;
  final PendingChannelConfig? pending;

  const ChannelState({
    required this.ch,
    required this.enabled,
    required this.ledCount,
    required this.power,
    required this.color,
    required this.color2,
    required this.effect,
    required this.brightness,
    required this.speed,
    required this.direction,
    required this.intensity,
    this.palette = const [],
    this.pending,
  });

  static ChannelState? tryParse(dynamic j) {
    if (j is! Map) return null;
    final ch = j['ch'];
    if (ch is! int || ch < 1 || ch > kMaxChannels) return null;
    final color = colorFromWire(j['color']);
    final color2 = colorFromWire(j['color2']);
    final effect = effectTypeFromName(j['effect'] as String?);
    if (color == null || color2 == null || effect == null) return null;
    PendingChannelConfig? pending;
    final p = j['pendingConfig'];
    if (p is Map) {
      pending = PendingChannelConfig(
        enabled: p['enabled'] == true,
        ledCount: (p['ledCount'] as num?)?.toInt() ?? 0,
        colorOrder: (p['colorOrder'] as String?) ?? 'GRB',
      );
    }
    return ChannelState(
      ch: ch,
      enabled: j['enabled'] == true,
      ledCount: (j['ledCount'] as num?)?.toInt() ?? 0,
      power: j['power'] == true,
      color: color,
      color2: color2,
      effect: effect,
      brightness: ((j['brightness'] as num?)?.toInt() ?? 0).clamp(0, 255),
      speed: ((j['speed'] as num?)?.toInt() ?? 50).clamp(1, 100),
      direction: (j['direction'] as num?)?.toInt() == -1 ? -1 : 1,
      intensity: ((j['intensity'] as num?)?.toInt() ?? 50).clamp(0, 100),
      palette: paletteFromWire(j['palette']),
      pending: pending,
    );
  }

  DeviceState toDeviceState() => DeviceState(
        isOn: power,
        color: color,
        secondaryColor: color2,
        effectType: effect,
        brightness: brightness,
        speed: speed,
        direction: direction,
        intensity: intensity,
        palette: palette,
      );

  /// Belirli alanları üzerine yazar (anahtar adları protokol alan adlarıdır).
  ChannelState withFields(Map<String, dynamic> f) {
    return ChannelState(
      ch: ch,
      enabled: enabled,
      ledCount: ledCount,
      power: f.containsKey('power') ? f['power'] as bool : power,
      color: f.containsKey('color') ? colorFromWire(f['color']) ?? color : color,
      color2: f.containsKey('color2') ? colorFromWire(f['color2']) ?? color2 : color2,
      effect: f.containsKey('effect')
          ? effectTypeFromName(f['effect'] as String?) ?? effect
          : effect,
      brightness: f.containsKey('brightness') ? f['brightness'] as int : brightness,
      speed: f.containsKey('speed') ? f['speed'] as int : speed,
      direction: f.containsKey('direction') ? f['direction'] as int : direction,
      intensity: f.containsKey('intensity') ? f['intensity'] as int : intensity,
      palette: f.containsKey('palette') ? paletteFromWire(f['palette']) : palette,
      pending: pending,
    );
  }
}

/// `set` mesajı için kısmi alanlar (yalnızca değişenler).
/// DeviceState'in tüm protokol alanları (çoklu kanalda "dokunulan" alanı açıkça göndermek için).
Map<String, dynamic> deviceStateToFields(DeviceState s) => {
      'power': s.isOn,
      'color': colorToWire(s.color),
      'color2': colorToWire(s.secondaryColor),
      'effect': s.effectType.name,
      'brightness': s.brightness,
      'speed': s.speed,
      'direction': s.direction >= 0 ? 1 : -1,
      'intensity': s.intensity,
      'palette': paletteToWire(s.palette),
    };

Map<String, dynamic> deviceStateDiffToFields(DeviceState from, DeviceState to) {
  final f = <String, dynamic>{};
  if (from.isOn != to.isOn) f['power'] = to.isOn;
  if (from.color != to.color) f['color'] = colorToWire(to.color);
  if (from.secondaryColor != to.secondaryColor) f['color2'] = colorToWire(to.secondaryColor);
  if (from.effectType != to.effectType) f['effect'] = to.effectType.name;
  if (from.brightness != to.brightness) f['brightness'] = to.brightness;
  if (from.speed != to.speed) f['speed'] = to.speed;
  if (from.direction != to.direction) f['direction'] = to.direction >= 0 ? 1 : -1;
  if (from.intensity != to.intensity) f['intensity'] = to.intensity;
  if (!_samePalette(from.palette, to.palette)) f['palette'] = paletteToWire(to.palette);
  return f;
}

/// /api/discover yanıtı (herkese açık).
class DiscoverInfo {
  final String deviceId;
  final String name;
  final String model;
  final String fw;
  final int proto;
  final bool paired;
  final bool pairingOpen;
  final String mode;

  const DiscoverInfo({
    required this.deviceId,
    required this.name,
    required this.model,
    required this.fw,
    required this.proto,
    required this.paired,
    required this.pairingOpen,
    required this.mode,
  });

  static DiscoverInfo? tryParse(dynamic j) {
    if (j is! Map || j['deviceId'] is! String) return null;
    return DiscoverInfo(
      deviceId: j['deviceId'] as String,
      name: (j['name'] as String?) ?? 'ESP32 ARGB',
      model: (j['model'] as String?) ?? '',
      fw: (j['fw'] as String?) ?? '',
      proto: (j['proto'] as num?)?.toInt() ?? 0,
      paired: j['paired'] == true,
      pairingOpen: j['pairingOpen'] == true,
      mode: (j['mode'] as String?) ?? 'offline',
    );
  }
}

class ChannelConfigInfo {
  final int ch;
  final bool enabled;
  final int ledCount;
  final String colorOrder;
  final int maxBrightness;
  final int gpio;
  final int? pendingLedCount;   // yeniden başlatma bekleyen LED sayısı
  const ChannelConfigInfo({
    required this.ch,
    required this.enabled,
    required this.ledCount,
    required this.colorOrder,
    required this.maxBrightness,
    required this.gpio,
    this.pendingLedCount,
  });
}

/// /api/info (token gerekir).
class DeviceInfo {
  final String deviceId;
  final String name;
  final String fw;
  final int proto;
  final Set<String> supportedEffects;
  final List<ChannelConfigInfo> channels;
  final String wifiMode;
  final String? wifiSsid;
  final String? ip;
  final int? rssi;
  final int freeHeap;
  final Set<String> features;
  final int maxLedsPerChannel;
  final int maxTotalLeds;
  final int warnLedsPerChannel;
  final int warnTotalLeds;

  const DeviceInfo({
    required this.deviceId,
    required this.name,
    required this.fw,
    required this.proto,
    required this.supportedEffects,
    required this.channels,
    required this.wifiMode,
    this.wifiSsid,
    this.ip,
    this.rssi,
    this.freeHeap = 0,
    this.features = const {},
    this.maxLedsPerChannel = 512,
    this.maxTotalLeds = 1024,
    this.warnLedsPerChannel = 300,
    this.warnTotalLeds = 600,
  });

  bool get supportsPalette => features.contains('palette');

  static DeviceInfo? tryParse(dynamic j) {
    if (j is! Map || j['deviceId'] is! String) return null;
    final fx = <String>{};
    final rawFx = j['supportedEffects'];
    if (rawFx is List) {
      for (final e in rawFx) {
        if (e is String) fx.add(e);
      }
    }
    final cfgs = <ChannelConfigInfo>[];
    final rawCfg = j['channelConfigs'];
    if (rawCfg is List) {
      for (final c in rawCfg) {
        if (c is Map && c['ch'] is int) {
          cfgs.add(ChannelConfigInfo(
            ch: c['ch'] as int,
            enabled: c['enabled'] == true,
            ledCount: (c['ledCount'] as num?)?.toInt() ?? 0,
            colorOrder: (c['colorOrder'] as String?) ?? 'GRB',
            maxBrightness: (c['maxBrightness'] as num?)?.toInt() ?? 255,
            gpio: (c['gpio'] as num?)?.toInt() ?? 0,
            pendingLedCount: c['pending'] is Map ? ((c['pending'] as Map)['ledCount'] as num?)?.toInt() : null,
          ));
        }
      }
    }
    final w = j['wifi'] is Map ? j['wifi'] as Map : const {};
    return DeviceInfo(
      deviceId: j['deviceId'] as String,
      name: (j['name'] as String?) ?? 'ESP32 ARGB',
      fw: (j['fw'] as String?) ?? '',
      proto: (j['proto'] as num?)?.toInt() ?? 0,
      supportedEffects: fx,
      channels: cfgs,
      wifiMode: (w['mode'] as String?) ?? 'offline',
      wifiSsid: w['ssid'] as String?,
      ip: w['ip'] as String?,
      rssi: (w['rssi'] as num?)?.toInt(),
      freeHeap: (j['freeHeap'] as num?)?.toInt() ?? 0,
      features: {
        if (j['features'] is List)
          for (final e in j['features'] as List)
            if (e is String) e,
      },
      maxLedsPerChannel: (j['maxLedsPerChannel'] as num?)?.toInt() ?? 512,
      maxTotalLeds: (j['maxTotalLeds'] as num?)?.toInt() ?? 1024,
      warnLedsPerChannel: (j['warnLedsPerChannel'] as num?)?.toInt() ?? 300,
      warnTotalLeds: (j['warnTotalLeds'] as num?)?.toInt() ?? 600,
    );
  }
}

/// ESP32 taramasında bulunan bir erişim noktası.
class WifiNetwork {
  final String ssid;
  final int rssi;
  final String security;
  final int channel;
  const WifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.security,
    required this.channel,
  });

  bool get isOpen => security == 'OPEN';

  /// ESP32 istasyon modunda WPA2-Enterprise'a bu projede bağlanılamaz.
  bool get isSupported => security != 'WPA2_ENTERPRISE';

  static WifiNetwork? tryParse(dynamic j) {
    if (j is! Map || j['ssid'] is! String) return null;
    return WifiNetwork(
      ssid: j['ssid'] as String,
      rssi: (j['rssi'] as num?)?.toInt() ?? -100,
      security: (j['security'] as String?) ?? 'UNKNOWN',
      channel: (j['channel'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Aynı SSID'li erişim noktalarını tek satırda toplar (en güçlü sinyal korunur).
class WifiNetworkGroup {
  final String ssid;
  final WifiNetwork best;
  final int accessPointCount;
  const WifiNetworkGroup({
    required this.ssid,
    required this.best,
    required this.accessPointCount,
  });
}

List<WifiNetworkGroup> groupNetworks(Iterable<WifiNetwork> nets) {
  final map = <String, List<WifiNetwork>>{};
  for (final n in nets) {
    if (n.ssid.isEmpty) continue;
    map.putIfAbsent(n.ssid, () => []).add(n);
  }
  final groups = map.entries.map((e) {
    final list = e.value..sort((a, b) => b.rssi.compareTo(a.rssi));
    return WifiNetworkGroup(ssid: e.key, best: list.first, accessPointCount: list.length);
  }).toList();
  groups.sort((a, b) => b.best.rssi.compareTo(a.best.rssi));
  return groups;
}

/// 0..4 sinyal çubuğu.
int signalBars(int rssi) {
  if (rssi >= -55) return 4;
  if (rssi >= -65) return 3;
  if (rssi >= -75) return 2;
  if (rssi >= -85) return 1;
  return 0;
}

enum WifiConnState { disconnected, connecting, connected, failed, ap, unknown }

class WifiStatus {
  final WifiConnState state;
  final String mode;
  final bool apActive;
  final String? ssid;
  final String? ip;
  final String? error; // auth_failed | not_found | timeout

  const WifiStatus({
    required this.state,
    required this.mode,
    required this.apActive,
    this.ssid,
    this.ip,
    this.error,
  });

  static WifiStatus? tryParse(dynamic j) {
    if (j is! Map) return null;
    WifiConnState st;
    switch (j['state']) {
      case 'disconnected':
        st = WifiConnState.disconnected;
      case 'connecting':
        st = WifiConnState.connecting;
      case 'connected':
        st = WifiConnState.connected;
      case 'failed':
        st = WifiConnState.failed;
      case 'ap':
        st = WifiConnState.ap;
      default:
        st = WifiConnState.unknown;
    }
    return WifiStatus(
      state: st,
      mode: (j['mode'] as String?) ?? 'offline',
      apActive: j['apActive'] == true,
      ssid: j['ssid'] as String?,
      ip: j['ip'] as String?,
      error: j['error'] as String?,
    );
  }
}

/// WLED uyumluluk katmanının erişim modu (docs/WLED_COMPAT.md).
/// off: kapalı (varsayılan) · readonly: /json/* ve WS durumu TOKENSİZ okunabilir ·
/// control: ek olarak TOKENSİZ yazma (açmak için fiziksel BOOT onayı gerekir).
class WledAccess {
  final bool compiled; // firmware ENABLE_WLED_COMPAT ile mi derlendi?
  final String mode; // off | readonly | control
  const WledAccess({required this.compiled, required this.mode});

  static WledAccess? tryParse(dynamic j) {
    if (j is! Map) return null;
    final m = j['mode'];
    return WledAccess(
      compiled: j['compiled'] == true,
      mode: (m == 'readonly' || m == 'control') ? m as String : 'off',
    );
  }
}

class PairedClient {
  final String tokenId;
  final String clientName;
  final bool current;
  const PairedClient({required this.tokenId, required this.clientName, required this.current});
}

/// API / protokol hatası. `code` protokoldeki hata kodudur (ör. pairing_closed).
class ApiException implements Exception {
  final String code;
  final int? httpStatus;
  final String? field;
  final String? message;
  const ApiException(this.code, {this.httpStatus, this.field, this.message});

  bool get isNetwork => code == 'network' || code == 'timeout_client';

  @override
  String toString() => 'ApiException($code${field != null ? ', $field' : ''})';
}

/// Kullanıcıya gösterilecek Türkçe hata metni.
String describeApiError(Object e) {
  if (e is ApiException) {
    switch (e.code) {
      case 'network':
        return 'Cihaza ulaşılamadı. Aynı Wi-Fi ağında olduğunuzdan emin olun.';
      case 'timeout_client':
        return 'Cihaz zamanında yanıt vermedi.';
      case 'unauthorized':
        return 'Yetkilendirme reddedildi. Cihazı yeniden eşleştirin.';
      case 'rate_limited':
        return 'Çok fazla başarısız deneme. Bir dakika sonra tekrar deneyin.';
      case 'pairing_closed':
        return 'Eşleştirme penceresi kapalı. ESP32 üzerindeki BOOT düğmesine 3 saniye basılı tutup bırakın.';
      case 'slots_full':
        return 'Cihazda eşleştirme slotu kalmadı (en fazla 4). ESP32 BOOT düğmesine 10 saniye basarak güvenlik sıfırlaması yapın veya başka bir istemciyi kaldırın.';
      case 'busy':
        return 'Cihaz meşgul, lütfen tekrar deneyin.';
      case 'invalid_value':
        return 'Geçersiz değer${e.field != null ? ' (${e.field})' : ''}.';
      case 'led_budget_exceeded':
        return e.message ?? 'Toplam LED sınırı aşıldı.';
      case 'bad_version':
        return 'Uygulama ve cihaz yazılımı protokol sürümleri uyumsuz.';
      default:
        return 'Cihaz hatası: ${e.code}';
    }
  }
  return 'Beklenmeyen hata.';
}

/// Wi-Fi bağlantı hata kodunu kullanıcı metnine çevirir.
String describeWifiError(String? code) {
  switch (code) {
    case 'auth_failed':
      return 'Wi-Fi şifresi yanlış görünüyor.';
    case 'not_found':
      return 'Ağ bulunamadı. ESP32 yalnızca 2.4 GHz ağları görür; ağ adını ve menzili kontrol edin.';
    case 'timeout':
      return 'Bağlantı zaman aşımına uğradı.';
    default:
      return 'Bağlantı kurulamadı.';
  }
}

/// Palet (0..5 renk): tel biçimi `[{r,g,b}, ...]`. Geçersiz öğeler atlanır; en fazla [kMaxPaletteColors] renk.
const int kMaxPaletteColors = 5;

List<LedColor> paletteFromWire(dynamic v) {
  if (v is! List) return const [];
  final out = <LedColor>[];
  for (final e in v) {
    final c = colorFromWire(e);
    if (c != null && out.length < kMaxPaletteColors) out.add(c);
  }
  return out;
}

List<Map<String, int>> paletteToWire(List<LedColor> p) =>
    [for (final c in p.take(kMaxPaletteColors)) colorToWire(c)];

bool _samePalette(List<LedColor> a, List<LedColor> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].r != b[i].r || a[i].g != b[i].g || a[i].b != b[i].b) return false;
  }
  return true;
}
