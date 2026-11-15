import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/services/device_api.dart';
import 'package:argb_controller/services/nsd_source_stub.dart'
    if (dart.library.io) 'package:argb_controller/services/nsd_source_io.dart' as mdns;

/// Yerel ağda bulunan bir ESP32.
class FoundDevice {
  final String id;
  final String name;
  final String host;
  final int port;
  final bool paired;
  final bool pairingOpen;
  final String mode; // sta | ap | ap+sta
  final String fw;

  const FoundDevice({
    required this.id,
    required this.name,
    required this.host,
    this.port = 80,
    this.paired = false,
    this.pairingOpen = false,
    this.mode = 'sta',
    this.fw = '',
  });

  bool get isSetupAp => mode == 'ap';
}

/// SoftAP kurulum adresi (ESP32'nin kendi ağı).
const String kSetupApHost = '192.168.4.1';

/// mDNS ana makine adı (firmware: MDNS_HOSTNAME).
const String kMdnsHost = 'esp32-argb.local';

/// Platform kısıtları:
///  - Android/iOS/macOS/Windows: nsd ile mDNS taraması + bilinen adreslerin yoklanması.
///  - Flutter Web: tarayıcıda mDNS/UDP yok; yalnızca doğrudan yoklama
///    (`esp32-argb.local`, 192.168.4.1) ve elle IP girişi çalışır.
///  - iOS: Yerel Ağ izni ve Info.plist'te NSBonjourServices gerekir.
class DeviceDiscovery {
  DeviceDiscovery({
    this.probeTimeout = const Duration(seconds: 2),
    this.httpClientFactory,
    this.useMdns = true,
  });

  final Duration probeTimeout;
  final http.Client Function()? httpClientFactory;
  final bool useMdns;

  bool get mdnsAvailable => useMdns && mdns.mdnsSupported;

  /// Tek bir adresi yoklar; cihaz değilse veya yanıt yoksa null.
  Future<FoundDevice?> probe(String host, {int port = 80}) async {
    final api = DeviceApi(
      host: host,
      port: port,
      timeout: probeTimeout,
      client: httpClientFactory?.call(),
    );
    try {
      final d = await api.discover();
      if (d.proto != kProtocolVersion) return null;
      return FoundDevice(
        id: d.deviceId,
        name: d.name,
        host: host,
        port: port,
        paired: d.paired,
        pairingOpen: d.pairingOpen,
        mode: d.mode,
        fw: d.fw,
      );
    } catch (_) {
      return null;
    } finally {
      api.close();
    }
  }

  /// Cihazları bulundukça yayınlar; [timeout] sonunda tamamlanır.
  /// [extraHosts]: kayıtlı/elle girilmiş adresler.
  Stream<FoundDevice> scan({
    Duration timeout = const Duration(seconds: 6),
    Iterable<String> extraHosts = const [],
  }) {
    final controller = StreamController<FoundDevice>();
    final seen = <String>{};
    final pending = <Future<void>>[];
    StreamSubscription<mdns.MdnsHit>? sub;

    void tryHost(String host, int port) {
      pending.add(() async {
        final d = await probe(host, port: port);
        if (d != null && seen.add(d.id) && !controller.isClosed) controller.add(d);
      }());
    }

    final stop = Completer<void>();
    Timer? timer;

    controller.onListen = () async {
      final hosts = <String>{kMdnsHost, kSetupApHost, ...extraHosts};
      for (final h in hosts) {
        tryHost(h, 80);
      }
      if (mdnsAvailable) {
        sub = mdns.mdnsServices(timeout).listen((hit) => tryHost(hit.host, hit.port));
      }
      timer = Timer(timeout, () {
        if (!stop.isCompleted) stop.complete();
      });
      await stop.future;
      timer?.cancel();
      await sub?.cancel();
      await Future.wait(pending);
      if (!controller.isClosed) await controller.close();
    };
    controller.onCancel = () async {
      timer?.cancel();
      if (!stop.isCompleted) stop.complete();
      await sub?.cancel();
    };
    return controller.stream;
  }

  /// Belirli bir cihazı (kimliğiyle) yeniden bulur; bulunamazsa null.
  Future<FoundDevice?> findById(
    String deviceId, {
    Duration timeout = const Duration(seconds: 8),
    Iterable<String> extraHosts = const [],
  }) async {
    await for (final d in scan(timeout: timeout, extraHosts: extraHosts)) {
      if (d.id == deviceId) return d;
    }
    return null;
  }
}
