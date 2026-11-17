import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/effect_capabilities.dart';
import 'package:argb_controller/models/protocol.dart';

/// Flutter <-> firmware sözleşme testleri: firmware kaynağını okuyarak
/// efekt listesi, hız formülü ve desteklenen efekt bildiriminin uyumunu doğrular.
/// (Donanım gerektirmez; depo kökündeki firmware/ klasörü yoksa atlanır.)
void main() {
  final root = Directory('../firmware');
  final types = File('../firmware/include/types.h');
  final engine = File('../firmware/src/led/animation_engine.cpp');
  final apiJson = File('../firmware/src/api/api_json.cpp');
  final available = root.existsSync() && types.existsSync() && engine.existsSync() && apiJson.existsSync();

  List<String> firmwareEffectNames() {
    final src = types.readAsStringSync();
    final block = RegExp(r'enum class EffectType[^{]*\{([^}]*)\}').firstMatch(src)!.group(1)!;
    return RegExp(r'(\w+)\s*=\s*(\d+)')
        .allMatches(block)
        .map((m) => (int.parse(m.group(2)!), m.group(1)!))
        .toList()
        .map((e) => e)
        .fold<List<String>>(List.filled(20, ''), (acc, e) {
      acc[e.$1] = e.$2;
      return acc;
    });
  }

  group('firmware sözleşmesi', skip: available ? false : 'firmware/ bulunamadı', () {
    test('EffectType adları ve sırası Dart enum ile birebir aynı', () {
      expect(EffectType.values.map((e) => e.name).toList(), firmwareEffectNames());
    });

    test('animasyon motoru 20 efektin her birini render eder (statik düşüş yok)', () {
      final src = engine.readAsStringSync();
      for (final n in firmwareEffectNames()) {
        expect(src.contains('case EffectType::$n:'), isTrue, reason: '$n için case yok');
      }
      // Bilinmeyen değer sessizce statik renge düşmemeli
      expect(src.contains('unknown effect id'), isTrue);
    });

    test('cihaz tüm efektleri desteklenen olarak bildirir', () {
      final src = apiJson.readAsStringSync();
      final block = RegExp(r'SUPPORTED_EFFECTS\[\]\s*=\s*\{([^}]*)\}').firstMatch(src)!.group(1)!;
      final listed = RegExp(r'"(\w+)"').allMatches(block).map((m) => m.group(1)!).toSet();
      expect(listed, firmwareEffectNames().toSet());
    });

    test('hız formülü firmware kaynağında docs ile aynı', () {
      final src = engine.readAsStringSync();
      expect(src.contains('5000 - (static_cast<uint32_t>(speed - 1) * 4500 / 99)'), isTrue);
      expect(src.contains('ms < 200 ? 200 : ms'), isTrue);
    });

    test('hız yalnızca yeni faz biriktirir: faz sıfırlama yok (sıçrama olmaz)', () {
      final src = engine.readAsStringSync();
      expect(RegExp(r'setAnimProgress\(0').hasMatch(src), isFalse);
    });
  });

  group('telefon kurulum sayfası (firmware)', skip: available ? false : 'firmware/ bulunamadı', () {
    final page = File('../firmware/src/api/setup_page.h');
    final server = File('../firmware/src/api/api_server.cpp');
    final wifi = File('../firmware/src/network/wifi_manager.cpp');

    String code(File f) => f
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join(' ');

    test('sayfa XSS-güvenli ve gizli bilgi sızdırmaz', () {
      final src = code(page);
      expect(src.contains('innerHTML'), isFalse, reason: 'SSID textContent ile yazılmalı');
      expect(src.contains('console.'), isFalse, reason: 'şifre/SSID loglanmamalı');
      expect(src.contains('localStorage'), isFalse);
      expect(src.contains('sessionStorage'), isFalse);
      expect(src.contains('textContent'), isTrue);
      expect(src.contains('X-Setup-Request'), isTrue);
      expect(src.contains('viewport'), isTrue, reason: 'mobil uyumlu');
    });

    test('tarama ve bağlanma uç noktaları BOOT penceresi korumasını kullanır', () {
      final src = code(server);
      expect(RegExp(r'_setupGuard\(r, true\)').allMatches(src).length, greaterThanOrEqualTo(3));
      expect(src.contains('SerialProvisioning::instance().isOpen()'), isTrue);
      expect(src.contains('"X-Setup-Request"'), isTrue);
    });

    test('Wi-Fi yöneticisi SSID/şifreyi seri loga yazmaz', () {
      final src = code(wifi);
      final prints = RegExp(r'Serial\.print[a-z]*\([^;]*;').allMatches(src).map((m) => m.group(0)!);
      for (final p in prints) {
        // İSTİSNA (4B kararı): kurulum SoftAP'sinin kendi şifresi prototipte seri porttan gösterilir.
        // Ev Wi-Fi'ının SSID/şifresi ASLA yazılmaz.
        if (p.contains('Device-Specific Secure Key')) continue;
        expect(p.contains('_targetSSID') || p.contains('savedSSID') || p.contains('_targetPassword'), isFalse, reason: p);
        expect(RegExp(r'ssid\.c_str\(\)|password\.c_str\(\)').hasMatch(p), isFalse, reason: p);
      }
    });
  });

  group('WLED uyumluluk katmanı (firmware sözleşmesi)', skip: available ? false : 'firmware/ bulunamadı', () {
    final compat = File('../firmware/src/wled/wled_compat.cpp');
    final map = File('../firmware/src/wled/wled_map.cpp');
    final config = File('../firmware/include/config.h');
    final mdns = File('../firmware/src/network/mdns_service.cpp');
    final ini = File('../firmware/platformio.ini');

    String code(File f) => f.readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join(' ');

    test('derleme zamanı anahtarı: varsayılan açık, WLED\'siz ortam var', () {
      expect(config.readAsStringSync().contains('#define ENABLE_WLED_COMPAT          1'), isTrue);
      expect(ini.readAsStringSync().contains('esp32dev_nowled'), isTrue);
      expect(ini.readAsStringSync().contains('-D ENABLE_WLED_COMPAT=0'), isTrue);
    });

    test('varsayılan erişim modu KAPALI; bozuk NVS değeri de KAPALI', () {
      final src = code(compat);
      expect(src.contains('uint8_t m = 0;'), isTrue);
      expect(src.contains('(m <= 2) ? m : 0'), isTrue);
    });

    test('tehlikeli uç noktalar sunulmaz (OTA, ayarlar, dosya, reboot)', () {
      final src = code(compat);
      for (final bad in ['"/update"', '"/settings', '"/edit"', '"/cfg', '"/upload"', '"/reset"']) {
        expect(src.contains(bad), isFalse, reason: bad);
      }
      final m = code(map);
      for (final k in ['"rb"', '"ota"', '"psave"', '"pdel"', '"cfg"']) {
        expect(m.contains(k), isTrue, reason: '$k yok sayılan anahtarlar listesinde olmalı');
      }
    });

    test('yazma yalnızca Control modunda; tarayıcı koruması (Host/Origin/Content-Type) var', () {
      final src = code(compat);
      expect(src.contains('write && mode() != WledMode::Control'), isTrue);
      expect(src.contains('hostAllowed'), isTrue);
      expect(src.contains('originAllowed'), isTrue);
      expect(src.contains('content_type_must_be_json'), isTrue);
      expect(src.contains('allowRate'), isTrue);
      expect(src.contains('clientForeignOrigin'), isTrue, reason: 'WebSocket (cross-site hijacking) koruması');
    });

    test('mDNS _wled._tcp yalnızca mod KAPALI değilken yayınlanır', () {
      final src = code(mdns);
      expect(src.contains('setWledAdvertised(WledCompat::instance().enabled())'), isTrue);
      expect(src.contains('mdns_service_remove("_wled", "_tcp")'), isTrue);
    });

    test('mod değişimi token ister; control için fiziksel onay ister', () {
      final api = code(File('../firmware/src/api/api_server.cpp'));
      expect(RegExp(r'_post\("/api/wled", true').hasMatch(api), isTrue, reason: 'token zorunlu');
      expect(api.contains('m == WledMode::Control') && api.contains('isPairingOpen() || SerialProvisioning::instance().isOpen()'), isTrue);
    });
  });

  group('LED kontrol arayüzü (firmware, /)', skip: available ? false : 'firmware/ bulunamadı', () {
    final page = File('../firmware/src/wled/control_page.h');
    final compat = File('../firmware/src/wled/wled_compat.cpp');
    final api = File('../firmware/src/api/api_server.cpp');

    String code(File f) => f.readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join(' ');
    String control() {
      final src = page.readAsStringSync();
      final i = src.indexOf('CONTROL_PAGE_HTML');
      final j = src.indexOf('OFF_PAGE_HTML');
      return src.substring(i, j);
    }

    test('sayfa tamamen gömülü: harici kaynak, CDN, depolama, günlük yok', () {
      final src = control();
      expect(src.contains('innerHTML'), isFalse, reason: 'DOM yalnızca textContent ile yazılmalı');
      expect(src.contains('console.'), isFalse);
      expect(src.contains('localStorage') || src.contains('sessionStorage'), isFalse);
      expect(src.contains('eval('), isFalse);
      expect(src.contains('<script src'), isFalse);
      expect(src.contains('<link '), isFalse);
      expect(src.contains('@import'), isFalse);
      expect(RegExp('https?://').hasMatch(src), isFalse, reason: 'internet/CDN bağımlılığı olmamalı');
      expect(src.contains('viewport-fit=cover'), isTrue, reason: 'iPhone çentik/güvenli alan');
    });

    test('sayfa yalnızca mevcut WLED API yollarını kullanır (yeni yazma uç noktası yok)', () {
      final src = control();
      final paths = RegExp(r'"(/[a-z/]+)"').allMatches(src).map((m) => m.group(1)!).toSet();
      // '/json' yalnızca GET yedeği (efekt listesi /json/eff başarısız olursa); yeni yazma yolu yok
      expect(paths, {'/json/state', '/json/si', '/json/eff', '/json', '/ws', '/setup'});
    });

    test('yetenek tablosu (CAPS) Flutter effect_capabilities ile birebir aynı', () {
      final m = RegExp(r'CAPS=\[([0-9,]+)\]').firstMatch(control())!;
      final caps = m.group(1)!.split(',').map(int.parse).toList();
      expect(caps.length, 20);
      for (var i = 0; i < 20; i++) {
        final c = effectCaps(EffectType.values[i]);
        final bits = (c.speed ? 1 : 0) | (c.intensity ? 2 : 0) | (c.color ? 4 : 0) | (c.color2 ? 8 : 0);
        expect(caps[i], bits, reason: EffectType.values[i].name);
      }
    });

    test('/ yönlendirmesi: WLED açık derlemede kontrol arayüzü, /setup korunur', () {
      final a = code(api);
      expect(a.contains('_server.on("/", HTTP_GET, [](AsyncWebServerRequest* r) { WledCompat::instance().serveRoot(r); });'), isTrue);
      expect(a.contains('_server.on("/setup", HTTP_GET'), isTrue);
      // WLED derlenmediyse / kurulum sayfasına döner
      expect(a.contains('_server.on("/", HTTP_GET, [this](AsyncWebServerRequest* r) { _hSetupPage(r); });'), isTrue);
    });

    test('off modunda kontrol arayüzü sunulmaz; Host doğrulaması ve hız sınırı var', () {
      final c = code(compat);
      expect(c.contains('on ? CONTROL_PAGE_HTML : OFF_PAGE_HTML'), isTrue);
      expect(c.contains('hostAllowed(host.c_str(), MDNS_HOSTNAME)'), isTrue);
      final root = c.substring(c.indexOf('void WledCompat::serveRoot'));
      expect(root.contains('allowRate'), isTrue);
      expect(root.contains('frame-ancestors'), isTrue);
      // kontrol sayfası WS bağlantısını yalnızca kendi host'una izin veren CSP ile sunar
      expect(root.contains('connect-src'), isTrue);
    });

    test('off sayfası cihaz verisi/kontrol içermez', () {
      final src = page.readAsStringSync();
      final off = src.substring(src.indexOf('OFF_PAGE_HTML'));
      expect(off.contains('<script'), isFalse);
      expect(off.contains('/json'), isFalse);
      expect(off.contains('/setup'), isTrue);
    });
  });

  group('Flutter efekt kataloğu', () {
    test('20 efektin hepsi listede ve yetenek tablosunda var', () {
      final listed = Effect.builtInEffects.map((e) => e.type).toSet();
      expect(listed, EffectType.values.toSet());
      for (final t in EffectType.values) {
        final caps = effectCaps(t);
        // Her efekt en az bir parametreden (renk/hız/yoğunluk) etkilenir
        expect(caps.speed || caps.intensity || caps.color || caps.color2, isTrue, reason: t.name);
      }
    });

    test('hızdan etkilenmeyen efektler hız kontrolünü göstermez', () {
      expect(effectCaps(EffectType.staticColor).speed, isFalse);
      expect(effectCaps(EffectType.customGradient).speed, isFalse);
      for (final t in EffectType.values) {
        if (t != EffectType.staticColor && t != EffectType.customGradient) {
          expect(effectCaps(t).speed, isTrue, reason: t.name);
        }
      }
    });
  });

  group('palet ve LED sayısı sözleşmesi (firmware <-> Flutter <-> iPhone paneli)', skip: available ? false : 'firmware/ bulunamadı', () {
    String read(String p) => File(p).readAsStringSync();
    int constant(String src, String name) => int.parse(RegExp(name + r'\s+(\d+)').firstMatch(src)!.group(1)!);

    test('en fazla palet rengi ve LED sınırları üç tarafta aynı', () {
      final cfg = read('../firmware/include/config.h');
      final typesSrc = read('../firmware/include/types.h');
      final wledMap = read('../firmware/src/wled/wled_map.h');
      expect(RegExp(r'PALETTE_MAX_COLORS\s*=\s*(\d+)').firstMatch(typesSrc)!.group(1), '$kMaxPaletteColors');
      expect(RegExp(r'kPaletteMax\s*=\s*(\d+)').firstMatch(wledMap)!.group(1), '$kMaxPaletteColors');
      final info = DeviceInfo.tryParse({'deviceId': 'x'})!;   // varsayılanlar firmware sabitleriyle aynı olmalı
      expect(constant(cfg, 'MAX_LEDS_PER_CHANNEL'), info.maxLedsPerChannel);
      expect(constant(cfg, 'MAX_TOTAL_LEDS'), info.maxTotalLeds);
      expect(constant(cfg, 'LED_WARN_PER_CHANNEL'), info.warnLedsPerChannel);
      expect(constant(cfg, 'LED_WARN_TOTAL'), info.warnTotalLeds);
      expect(RegExp(r'kMaxLedsPerCh\s*=\s*(\d+)').firstMatch(wledMap)!.group(1), '${info.maxLedsPerChannel}');
      expect(RegExp(r'kMaxTotalLeds\s*=\s*(\d+)').firstMatch(wledMap)!.group(1), '${info.maxTotalLeds}');
    });

    test('REST/WS: palette alanı state ve set içinde; uzantı bayrakları info içinde', () {
      final json = read('../firmware/src/api/api_json.cpp');
      expect(json.contains('o["palette"]'), isTrue);
      expect(json.contains('feat.add("palette")'), isTrue);
      final server = read('../firmware/src/api/api_server.cpp');
      expect(server.contains('msg["palette"]') && server.contains('PALETTE_MAX_COLORS'), isTrue);
      expect(read('../firmware/src/api/command.h').contains('F_PALETTE'), isTrue);
      expect(read('../firmware/src/api/command_processor.cpp').contains('ch->setPalette(cmd.palette, false)'), isTrue,
          reason: 'palet kalıcılığı PersistenceScheduler (debounce) üzerinden: setter save=false');
    });

    test('NVS: palet ayrı blob anahtarında; eski sürümde anahtar yoksa palet boş', () {
      final nvs = read('../firmware/src/storage/nvs_storage.cpp');
      expect(nvs.contains('_channelKey(channelId, "pal")'), isTrue);
      expect(nvs.contains('state.palette = Palette();'), isTrue, reason: 'anahtar yoksa varsayılan: palet yok');
    });

    test('WLED/iPhone: sayfa ve eşleme aynı anahtarları kullanır (apal, argb.leds, pal)', () {
      final page = read('../firmware/src/wled/control_page.h');
      final map = read('../firmware/src/wled/wled_map.cpp');
      expect(map.contains('o["apal"]') && map.contains('"apal"'), isTrue);
      expect(map.contains('obj["argb"]'), isTrue);
      expect(page.contains('apal') && page.contains('argb:{leds:'), isTrue);
      // WLED rb anahtarı hâlâ yok sayılır; yeniden başlatma yalnızca argb.reboot + bekleyen yapılandırma ile
      expect(map.contains('"rb"'), isTrue);
      expect(read('../firmware/src/wled/wled_compat.cpp').contains('if (pending)'), isTrue);
    });

    test('mevcut 20 efekt orijinal çizim dalında bozulmadan duruyor; palet ayrı modülde', () {
      final engine = read('../firmware/src/led/animation_engine.cpp');
      for (final f in ['_renderStatic(a)', '_renderRainbow(a, progress)', '_renderFire(a, fx)', '_renderMusic(a, fx)']) {
        expect(engine.contains(f), isTrue, reason: f);
      }
      expect(engine.contains('if (pal.n > 0)'), isTrue);
      expect(File('../firmware/src/led/palette_fx.cpp').existsSync(), isTrue);
    });
  });
}
