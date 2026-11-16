import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'package:argb_controller/services/serial/serial_transport.dart';

/// flutter_libserialport tabanlı uygulama. Yalnızca WINDOWS masaüstünde desteklenir ve
/// sunulur (diğer platformlarda test edilmedi).
///
/// NATİVE BELLEK SAHİPLİĞİ KURALLARI (Debug CRT çökmesinin kök nedeni ve düzeltmesi):
///  1. `port.config = cfg` atamasından sonra [SerialPortConfig] nesnesinin SAHİBİ port'tur;
///     `SerialPort.dispose()` onu serbest bırakır. Çağıran taraf `cfg.dispose()` ÇAĞIRMAZ
///     (eski kod çağırıyordu -> `sp_free_config` iki kez -> `_CrtIsValidHeapPointer` assert'i).
///     Burada config, port'un kendi `port.config` nesnesi üzerinden değiştirilir.
///  2. `SerialPortReader` kullanılmaz: o, port işaretçisini ham adres olarak ayrı bir isolate'a
///     verir ve `Isolate.kill()` sıkı döngüyü kesemediğinden, `sp_free_port` sonrası isolate
///     serbest bırakılmış belleğe erişebilir (use-after-free). Bunun yerine okuma, port'un sahibi
///     olan aynı isolate'ta zamanlayıcıyla (non-blocking) yapılır.
///  3. Kapanış sırası tek ve idempotent: zamanlayıcıyı durdur -> `sp_close` -> `sp_free_port`.
SerialBackend createSerialBackend() => _LibSerialBackend();

class _LibSerialBackend implements SerialBackend {
  @override
  bool get supported => Platform.isWindows;

  static T? _safe<T>(T? Function() f) {
    try {
      return f();
    } catch (_) {
      return null; // USB olmayan portlarda (COM1 vb.) bilgi alanları hata verebilir
    }
  }

  @override
  List<SerialPortInfo> listPorts() {
    if (!supported) return const [];
    final result = <SerialPortInfo>[];
    List<String> names;
    try {
      names = SerialPort.availablePorts;
    } catch (_) {
      return const []; // libserialport yüklenemedi
    }
    for (final name in names) {
      SerialPort? p;
      try {
        p = SerialPort(name);
        final port = p;
        result.add(SerialPortInfo(
          name: name,
          description: _safe(() => port.description) ?? '',
          vendorId: _safe(() => port.vendorId),
          productId: _safe(() => port.productId),
          manufacturer: _safe(() => port.manufacturer),
        ));
      } catch (_) {
        // Bu port okunamadı: yine de listede göster
        result.add(SerialPortInfo(name: name));
      } finally {
        p?.dispose(); // yalnızca bu fonksiyonun oluşturduğu port; config atanmadı
      }
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  @override
  Future<SerialTransport> open(String portName, {int baudRate = 115200}) async {
    if (!supported) throw const SerialException('Bu platformda USB seri port desteklenmiyor.');
    final port = SerialPort(portName);
    if (!port.openReadWrite()) {
      final err = _safe(() => SerialPort.lastError?.message) ?? 'bilinmeyen hata';
      port.dispose();
      throw SerialException('$portName açılamadı ($err). Başka bir program (seri monitör) kullanıyor olabilir.');
    }
    try {
      // port.config: port'a ait nesne (port.dispose() serbest bırakır) -> elle dispose ETME.
      final cfg = port.config;
      cfg.baudRate = baudRate;
      cfg.bits = 8;
      cfg.parity = SerialPortParity.none;
      cfg.stopBits = 1;
      cfg.setFlowControl(SerialPortFlowControl.none);
      cfg.dtr = SerialPortDtr.off; // otomatik reset hatlarını yükseltme
      cfg.rts = SerialPortRts.off;
      port.config = cfg; // aynı nesne: önceki config serbest bırakılmaz, çift sahiplik yok
    } catch (e) {
      port.close();
      port.dispose();
      throw SerialException('$portName yapılandırılamadı.');
    }
    return _LibTransport(port);
  }
}

class _LibTransport implements SerialTransport {
  _LibTransport(this._port) {
    _controller = StreamController<List<int>>(
      onListen: _startPolling,
      onCancel: _stopPolling,
    );
  }

  final SerialPort _port;
  late final StreamController<List<int>> _controller;
  Timer? _timer;
  bool _closed = false;

  @override
  Stream<List<int>> get data => _controller.stream;

  void _startPolling() {
    _timer ??= Timer.periodic(const Duration(milliseconds: 15), (_) => _poll());
  }

  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  void _poll() {
    if (_closed) return;
    try {
      final n = _port.bytesAvailable;
      if (n > 0) {
        final bytes = _port.read(n); // non-blocking
        if (bytes.isNotEmpty && !_controller.isClosed) _controller.add(bytes);
      } else if (n < 0) {
        // Kablo çekildi vb.: akışı kapat
        unawaited(close());
      }
    } catch (_) {
      unawaited(close());
    }
  }

  @override
  void write(List<int> bytes) {
    if (_closed) return;
    try {
      _port.write(Uint8List.fromList(bytes));
    } catch (_) {
      // yazma hatası: üst katman zaman aşımıyla yakalar
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return; // idempotent: çift kapatma/çift free yok
    _closed = true;
    _stopPolling();
    try {
      _port.close(); // önce sp_close
    } catch (_) {}
    try {
      _port.dispose(); // sonra sp_free_port (config'i de port serbest bırakır)
    } catch (_) {}
    if (!_controller.isClosed) await _controller.close();
  }
}
