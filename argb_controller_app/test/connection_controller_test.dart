import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:argb_controller/services/device_api.dart';
import 'package:argb_controller/services/device_discovery.dart';
import 'package:argb_controller/services/token_store.dart';
import 'package:argb_controller/state/connection_controller.dart';

import 'support/fake_esp32.dart';

const _dev = FoundDevice(id: 'esp32-argb-TEST01', name: 'ESP32 Test', host: '192.168.1.40');

const _fast = ConnectionTuning(
  throttle: Duration(milliseconds: 30),
  authTimeout: Duration(milliseconds: 300),
  connectTimeout: Duration(milliseconds: 300),
  pingInterval: Duration(seconds: 30),
  silenceTimeout: Duration(seconds: 60),
  suppressRemote: Duration(milliseconds: 100),
  backoff: [Duration(milliseconds: 30), Duration(milliseconds: 60)],
);

Future<void> settle([int ms = 120]) => Future<void>.delayed(Duration(milliseconds: ms));

DeviceConnectionController make(
  MemoryTokenStore tokens,
  List<FakeSocket> sockets, {
  void Function(FakeSocket)? setup,
}) {
  var i = 0;
  final fakeEsp = FakeEsp32Http()..validToken = 'tok';
  return DeviceConnectionController(
    tokens: tokens,
    tuning: _fast,
    socketFactory: (Uri uri) {
      expect(uri.scheme, 'ws');
      expect(uri.path, '/ws');
      expect(uri.query, isEmpty, reason: 'token URL parametresi OLMAMALI');
      final s = i < sockets.length ? sockets[i] : FakeSocket();
      i++;
      (setup ?? standardDevice)(s);
      return s;
    },
    apiFactory: (d, t) => DeviceApi(host: d.host, token: t, client: fakeEsp.client()),
  );
}

void main() {
  late MemoryTokenStore tokens;

  setUp(() async {
    tokens = MemoryTokenStore();
    await tokens.write(_dev.id, 'tok');
  });

  test('token yoksa needsPairing; soket açılmaz', () async {
    final empty = MemoryTokenStore();
    var opened = 0;
    final c = DeviceConnectionController(
      tokens: empty,
      tuning: _fast,
      socketFactory: (_) {
        opened++;
        return FakeSocket();
      },
    );
    await c.connect(_dev);
    expect(c.state.status, LinkStatus.needsPairing);
    expect(opened, 0);
    c.dispose();
  });

  test('auth mesajı ilk gönderilir, token yalnızca auth içinde taşınır; state alınır', () async {
    final sock = FakeSocket();
    final c = make(tokens, [sock]);
    await c.connect(_dev);
    await settle();
    expect(sock.sent.first['type'], 'auth');
    expect(sock.sent.first['token'], 'tok');
    expect(c.state.status, LinkStatus.connected);
    expect(c.state.channels[1]!.brightness, 220);
    // Sonraki mesajlarda token yok
    for (final m in sock.sent.skip(1)) {
      expect(jsonEncode(m).contains('tok'), isFalse);
    }
    await settle(); // info (HTTP) tamamlanır
    expect(c.state.info?.supportedEffects, {'staticColor', 'breathing'});
    c.dispose();
  });

  test('hızlı slider akışı birleştirilir (throttle) ve son değer kesin gider', () async {
    final sock = FakeSocket();
    final c = make(tokens, [sock]);
    await c.connect(_dev);
    await settle();

    for (var v = 1; v <= 40; v++) {
      c.sendSet(1, {'speed': v});
    }
    await settle(200);

    final sets = sock.sets;
    expect(sets.length, lessThanOrEqualTo(3), reason: '40 değişim en çok birkaç mesaja inmeli');
    expect(sets.last['speed'], 40);
    expect(sets.last['ch'], 1);
    c.dispose();
  });

  test('aynı değer tekrar gönderilmez (gereksiz trafik yok)', () async {
    final sock = FakeSocket();
    final c = make(tokens, [sock]);
    await c.connect(_dev);
    await settle();

    c.sendSet(1, {'brightness': 100});
    await settle(80);
    c.sendSet(1, {'brightness': 100});
    await settle(80);
    expect(sock.sets.length, 1);
    // Cihazın bildirdiği değerle aynıysa (220) hiç gönderme
    c.sendSet(1, {'speed': 55});
    await settle(80);
    expect(sock.sets.where((m) => m.containsKey('speed')).length, 0);
    c.dispose();
  });

  test('state mesajı UI durumunu günceller; yeni gönderilen alan eski değerle ezilmez', () async {
    final sock = FakeSocket();
    final c = make(tokens, [sock]);
    await c.connect(_dev);
    await settle();

    // Başka bir istemci parlaklığı 10 yaptı
    sock.emit(stateMsg(rev: 5, partial: true, channels: [channelJson(brightness: 10)]));
    await settle(30);
    expect(c.state.channels[1]!.brightness, 10);

    // Biz 200 gönderdik; hemen ardından eski (10) değerli yayın gelirse yok sayılmalı
    c.sendSet(1, {'brightness': 200});
    await settle(40);
    sock.emit(stateMsg(rev: 6, partial: true, channels: [channelJson(brightness: 10)]));
    await settle(30);
    expect(c.state.channels[1]!.brightness, 200);
    c.dispose();
  });

  test('eski rev ile gelen kısmi güncelleme yok sayılır', () async {
    final sock = FakeSocket();
    final c = make(tokens, [sock]);
    await c.connect(_dev);
    await settle();
    sock.emit(stateMsg(rev: 10, partial: true, channels: [channelJson(brightness: 50)]));
    await settle(30);
    sock.emit(stateMsg(rev: 3, partial: true, channels: [channelJson(brightness: 99)]));
    await settle(30);
    expect(c.state.channels[1]!.brightness, 50);
    c.dispose();
  });

  test('busy hatasında yalnızca yeniden gönderilir', () async {
    final sock = FakeSocket();
    final c = make(tokens, [sock], setup: (s) {
      var first = true;
      s.onClient = (m) {
        if (m['type'] == 'auth') {
          s.emit({'v': 1, 'type': 'authOk'});
          s.emit(stateMsg());
        } else if (m['type'] == 'set' && first) {
          first = false;
          s.emit({'v': 1, 'type': 'error', 'id': m['id'], 'code': 'busy'});
        }
      };
    });
    await c.connect(_dev);
    await settle();
    c.sendSet(1, {'brightness': 77});
    await settle(300);
    expect(sock.sets.length, 2);
    expect(sock.sets.last['brightness'], 77);
    c.dispose();
  });

  test('4403 (token iptal) -> needsPairing ve yerel token silinir; yeniden bağlanma yok', () async {
    final sock = FakeSocket();
    final c = make(tokens, [sock]);
    await c.connect(_dev);
    await settle();
    sock.serverClose(4403);
    await settle(150);
    expect(c.state.status, LinkStatus.needsPairing);
    expect(await tokens.read(_dev.id), isNull);
    c.dispose();
  });

  test('bağlantı kopunca kontrollü yeniden bağlanır', () async {
    final s1 = FakeSocket();
    final s2 = FakeSocket();
    final c = make(tokens, [s1, s2]);
    await c.connect(_dev);
    await settle();
    expect(c.state.status, LinkStatus.connected);

    s1.serverClose(1006);
    await settle(10);
    expect(c.state.status, LinkStatus.reconnecting);
    await settle(250);
    expect(c.state.status, LinkStatus.connected);
    expect(s2.sent.first['type'], 'auth');
    c.dispose();
  });

  test('soket kurulamazsa reconnecting; çevrimdışıyken sendSet yok sayılır', () async {
    final c = make(tokens, [FakeSocket(failReady: true), FakeSocket(failReady: true), FakeSocket(failReady: true)]);
    await c.connect(_dev);
    await settle(60);
    expect(c.state.status, LinkStatus.reconnecting);
    c.sendSet(1, {'brightness': 1});
    await settle(60);
    expect(c.sentMessages, 0);
    c.dispose();
  });

  test('yanıt vermeyen cihazda auth zaman aşımı -> yeniden bağlanma denenir', () async {
    final sock = FakeSocket();
    final c = make(tokens, [sock], setup: (s) {}); // hiç yanıt vermez
    final seen = <LinkStatus>[];
    c.addListener((st) => seen.add(st.status), fireImmediately: false);
    await c.connect(_dev);
    await settle(500);
    expect(seen, contains(LinkStatus.reconnecting));
    expect(c.state.isConnected, isFalse);
    c.dispose();
  });

  test('disconnect yeniden bağlanmayı durdurur', () async {
    final sock = FakeSocket();
    final c = make(tokens, [sock]);
    await c.connect(_dev);
    await settle();
    await c.disconnect();
    expect(c.state.status, LinkStatus.idle);
    await settle(150);
    expect(c.state.status, LinkStatus.idle);
    c.dispose();
  });
}
