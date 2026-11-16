import 'dart:async';

/// Seri port bilgisi (aygıt yöneticisinden).
class SerialPortInfo {
  final String name; // ör. COM3
  final String description;
  final int? vendorId;
  final int? productId;
  final String? manufacturer;

  const SerialPortInfo({
    required this.name,
    this.description = '',
    this.vendorId,
    this.productId,
    this.manufacturer,
  });

  /// ESP32 DevKit kartlarında yaygın USB-UART köprü çipleri:
  /// CP210x (10C4), CH340/CH9102 (1A86), FTDI (0403), Espressif yerleşik USB (303A).
  bool get likelyEsp32 => const {0x10C4, 0x1A86, 0x0403, 0x303A}.contains(vendorId);

  String get label => description.isEmpty ? name : '$name — $description';
}

/// Açık bir seri bağlantı (bayt akışı).
abstract class SerialTransport {
  Stream<List<int>> get data;
  void write(List<int> bytes);
  Future<void> close();
}

class SerialException implements Exception {
  final String message;
  const SerialException(this.message);
  @override
  String toString() => 'SerialException($message)';
}

/// Platforma özgü seri port erişimi (Windows: libserialport; Web/mobil: desteklenmez).
abstract class SerialBackend {
  bool get supported;
  List<SerialPortInfo> listPorts();

  /// DTR/RTS yükseltilmeden açılır (çoğu DevKit'te otomatik reset'i önlemek için).
  Future<SerialTransport> open(String portName, {int baudRate = 115200});
}
