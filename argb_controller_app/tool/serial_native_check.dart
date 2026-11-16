// Windows seri port (libserialport/FFI) bellek güvenliği doğrulama aracı.
//
// Kullanım (Debug serialport.dll'in bulunduğu klasörde, PowerShell):
//   $env:PATH = "<...>\build\windows\x64\runner\Debug;$env:PATH"
//   dart run tool/serial_native_check.dart old COM3   # ESKİ (hatalı) dizilim: çökmeyi yeniden üretir
//   dart run tool/serial_native_check.dart new COM3   # DÜZELTİLMİŞ üretim kodu: döngüyle sınar
//
// Debug CRT assertion'ları pencere yerine stderr'e yazılır ve süreç sonlanır (CI/terminal için).
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'package:argb_controller/services/serial/serial_backend.dart';

void routeCrtAssertsToStderr() {
  try {
    final crt = DynamicLibrary.open('ucrtbased.dll');
    final setMode = crt.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('_CrtSetReportMode');
    final setFile = crt.lookupFunction<IntPtr Function(Int32, IntPtr), int Function(int, int)>('_CrtSetReportFile');
    final abortBeh = crt.lookupFunction<Uint32 Function(Uint32, Uint32), int Function(int, int)>('_set_abort_behavior');
    for (final t in [0 /*WARN*/, 1 /*ERROR*/, 2 /*ASSERT*/]) {
      setMode(t, 1 /*_CRTDBG_MODE_FILE*/);
      setFile(t, -4 /*_CRTDBG_FILE_STDERR*/);
    }
    abortBeh(0, 1 | 2);
    stderr.writeln('[check] CRT assert çıktısı stderr\'e yönlendirildi.');
  } catch (e) {
    stderr.writeln('[check] ucrtbased.dll yönlendirmesi yapılamadı: $e');
  }
}

/// ESKİ üretim kodunun birebir dizilimi (hatalı).
Future<void> legacy(String name) async {
  final port = SerialPort(name);
  if (!port.openReadWrite()) {
    stderr.writeln('açılamadı: ${SerialPort.lastError}');
    return;
  }
  final cfg = SerialPortConfig()
    ..baudRate = 115200
    ..bits = 8
    ..parity = SerialPortParity.none
    ..stopBits = 1;
  cfg.setFlowControl(SerialPortFlowControl.none);
  cfg.dtr = SerialPortDtr.off;
  cfg.rts = SerialPortRts.off;
  port.config = cfg; // port, cfg'nin SAHİBİ olur
  cfg.dispose(); //     1. free  (HATA: sahip olunan nesneyi serbest bırakma)
  final reader = SerialPortReader(port);
  final sub = reader.stream.listen((_) {});
  await Future<void>.delayed(const Duration(milliseconds: 800));
  await sub.cancel();
  reader.close();
  port.close();
  port.dispose(); //    2. free  -> port kendi _config'ini tekrar free eder (DOUBLE FREE)
  await Future<void>.delayed(const Duration(milliseconds: 300));
  stdout.writeln('legacy: çökme olmadı (beklenmeyen)');
}

/// DÜZELTİLMİŞ üretim kodu: listeleme + aç/yaz/oku/kapat döngüsü.
Future<void> fixed(String name) async {
  final backend = createSerialBackend();
  for (var i = 0; i < 5; i++) {
    final ports = backend.listPorts();
    stdout.writeln('[$i] portlar: ${ports.map((p) => '${p.name}(${p.vendorId?.toRadixString(16)})').join(', ')}');
  }
  for (var i = 1; i <= 25; i++) {
    final t = await backend.open(name);
    final got = <int>[];
    final sub = t.data.listen(got.addAll);
    t.write(utf8.encode('{"cmd":"hello"}\n'));
    await Future<void>.delayed(Duration(milliseconds: i % 3 == 0 ? 20 : 400));
    await sub.cancel();
    await t.close();
    await t.close(); // idempotent olmalı
    stdout.writeln('[$i] aç/yaz/oku/kapat tamam, alınan bayt: ${got.length}');
  }
  stdout.writeln('fixed: 25 döngü çökmeden tamamlandı.');
}

Future<void> main(List<String> args) async {
  final mode = args.isNotEmpty ? args[0] : 'new';
  final port = args.length > 1 ? args[1] : 'COM3';
  routeCrtAssertsToStderr();
  stdout.writeln('mod=$mode port=$port');
  if (mode == 'old') {
    await legacy(port);
  } else {
    await fixed(port);
  }
  exit(0);
}

// Kullanılmayan import uyarısını önlemek için
// ignore: unused_element
Uint8List _unused() => Uint8List(0);
