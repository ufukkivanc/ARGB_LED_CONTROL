import 'package:argb_controller/services/serial/serial_transport.dart';

/// Web gibi seri portun olmadığı platformlar.
SerialBackend createSerialBackend() => _UnsupportedBackend();

class _UnsupportedBackend implements SerialBackend {
  @override
  bool get supported => false;

  @override
  List<SerialPortInfo> listPorts() => const [];

  @override
  Future<SerialTransport> open(String portName, {int baudRate = 115200}) =>
      Future.error(const SerialException('Bu platformda USB seri port desteklenmiyor.'));
}
