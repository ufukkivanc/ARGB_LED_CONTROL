import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket soyutlaması (testlerde sahte uygulama ile değiştirilebilir).
abstract class DeviceSocket {
  /// Bağlantı kurulduğunda tamamlanır; kurulamazsa hata fırlatır.
  Future<void> get ready;
  Stream<String> get messages;
  void send(String data);

  /// Bağlantı kapandığında WebSocket kapanış kodu (varsa).
  int? get closeCode;
  Future<void> close();
}

typedef SocketFactory = DeviceSocket Function(Uri uri);

class ChannelDeviceSocket implements DeviceSocket {
  ChannelDeviceSocket(Uri uri) : _channel = WebSocketChannel.connect(uri);

  final WebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<String> get messages => _channel.stream.map((e) => e.toString());

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  int? get closeCode => _channel.closeCode;

  @override
  Future<void> close() async {
    try {
      await _channel.sink.close();
    } catch (_) {}
  }
}

DeviceSocket defaultSocketFactory(Uri uri) => ChannelDeviceSocket(uri);
