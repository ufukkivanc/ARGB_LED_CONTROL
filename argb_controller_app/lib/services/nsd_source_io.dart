import 'dart:async';
import 'dart:io' show Platform;

import 'package:nsd/nsd.dart' as nsd;

typedef MdnsHit = ({String host, int port});

/// nsd paketi Android, iOS, macOS ve Windows'u destekler.
bool get mdnsSupported =>
    Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows;

/// `_http._tcp` servislerini [timeout] süresince tarar; yalnızca bu projenin
/// TXT işaretini (`proto`) taşıyanları yayınlar.
Stream<MdnsHit> mdnsServices(Duration timeout) {
  final controller = StreamController<MdnsHit>();
  nsd.Discovery? discovery;
  Timer? timer;

  Future<void> stop() async {
    timer?.cancel();
    final d = discovery;
    discovery = null;
    if (d != null) {
      try {
        await nsd.stopDiscovery(d);
      } catch (_) {}
    }
    if (!controller.isClosed) await controller.close();
  }

  controller.onListen = () async {
    try {
      discovery = await nsd.startDiscovery(
        '_http._tcp',
        autoResolve: true,
        ipLookupType: nsd.IpLookupType.v4,
      );
      discovery!.addServiceListener((service, status) {
        if (status != nsd.ServiceStatus.found || controller.isClosed) return;
        final txt = service.txt;
        if (txt == null || !txt.containsKey('proto')) return; // başka cihazları ele
        final addrs = service.addresses;
        final host = (addrs != null && addrs.isNotEmpty) ? addrs.first.address : service.host;
        final port = service.port ?? 80;
        if (host != null) controller.add((host: host, port: port));
      });
    } catch (_) {
      await stop();
      return;
    }
    timer = Timer(timeout, stop);
  };
  controller.onCancel = stop;
  return controller.stream;
}
