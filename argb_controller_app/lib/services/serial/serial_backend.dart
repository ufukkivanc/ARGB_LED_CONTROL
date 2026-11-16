// Web'de dart:ffi/dart:io olmadığı için koşullu içe aktarma kullanılır.
export 'package:argb_controller/services/serial/serial_backend_stub.dart'
    if (dart.library.io) 'package:argb_controller/services/serial/serial_backend_io.dart';
