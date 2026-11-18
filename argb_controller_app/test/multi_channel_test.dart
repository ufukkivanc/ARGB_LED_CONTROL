// v0.3.2: çoklu kanal seçimi ve seçili kanallara renk uygulama.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:argb_controller/models/effect.dart';
import 'package:argb_controller/models/led_color.dart';
import 'package:argb_controller/models/protocol.dart';
import 'package:argb_controller/providers/device_provider.dart';
import 'package:argb_controller/services/device_api.dart';
import 'package:argb_controller/services/device_discovery.dart';
import 'package:argb_controller/services/token_store.dart';
import 'package:argb_controller/state/app_state.dart';
import 'package:argb_controller/state/connection_controller.dart';
import 'package:argb_controller/widgets/channel_selector.dart';
import 'package:argb_controller/widgets/color_wheel.dart';

import 'support/fake_esp32.dart';

const _dev = FoundDevice(id: 'esp32-argb-TEST01', name: 'ESP32 Test', host: '192.168.1.40');

const _fast = ConnectionTuning(
  throttle: Duration(milliseconds: 30),
  authTimeout: Duration(milliseconds: 300),
  connectTimeout: Duration(milliseconds: 300),
  pingInterval: Duration(seconds: 30),
  silenceTimeout: Duration(seconds: 60),
  suppressRemote: Duration(milliseconds: 100),
  backoff: [Duration(milliseconds: 30)],
);

Future<void> settle([int ms = 120]) => Future<void>.delayed(Duration(milliseconds: ms));

const _red = {'r': 255, 'g': 0, 'b': 0};

/// CH1 nefes/mor, CH2 ateş/kırmızı, CH3 kuyruklu yıldız/mavi, CH4 kapalı.
List<Map<String, dynamic>> _fourChannels() => [
      channelJson(ch: 1, effect: 'breathing'),
      channelJson(ch: 2, effect: 'fire', color: _red),
      channelJson(ch: 3, effect: 'comet', color: const {'r': 0, 'g': 0, 'b': 255}),
      channelJson(ch: 4, enabled: false),
    ];

void _fourChannelDevice(FakeSocket s) {
  var rev = 1;
  s.onClient = (m) {
    switch (m['type']) {
      case 'auth':
        s.emit({'v': 1, 'type': 'authOk', 'deviceId': 'esp32-argb-TEST01', 'tokenId': 'abcd1234'});
        s.emit(stateMsg(rev: rev, channels: _fourChannels()));
      case 'set':
        rev++;
        s.emit({'v': 1, 'type': 'ack', 'id': m['id'], 'rev': rev});
    }
  };
}

DeviceConnectionController _controller(MemoryTokenStore tokens, FakeSocket sock) {
  final fakeEsp = FakeEsp32Http()..validToken = 'tok';
  return DeviceConnectionController(
    tokens: tokens,
    tuning: _fast,
    socketFactory: (_) {
      _fourChannelDevice(sock);
      return sock;
    },
    apiFactory: (d, t) => DeviceApi(host: d.host, token: t, client: fakeEsp.client()),
  );
}

void main() {
  group('ChannelSelection kuralları (iPhone paneliyle ortak)', () {
    const enabled = {1, 2, 3};

    test('ilk durumda tüm etkin kanallar seçilir; kapalı kanal seçilmez', () {
      final s = const ChannelSelection().reconcile(enabled);
      expect(s.sortedChannels, [1, 2, 3]);
      expect(s.initialized, isTrue);
    });

    test('durum gelmeden (etkin kanal yok) seçim başlatılmaz', () {
      final s = const ChannelSelection().reconcile(const {});
      expect(s.initialized, isFalse);
      expect(s.isEmpty, isTrue);
    });

    test('birden çok kanal seçilebilir ve hepsi kaldırılabilir (boş seçim geçerli)', () {
      var s = const ChannelSelection().reconcile(enabled).clear();
      expect(s.isEmpty, isTrue);
      s = s.toggle(3, enabled).toggle(1, enabled);
      expect(s.sortedChannels, [1, 3]);
      s = s.toggle(1, enabled).toggle(3, enabled);
      expect(s.isEmpty, isTrue, reason: 'son seçim de kaldırılabilir');
    });

    test('kapalı kanal işaretlenemez', () {
      final s = const ChannelSelection().reconcile(enabled).clear().toggle(4, enabled);
      expect(s.isEmpty, isTrue);
    });

    test('kapanan kanal seçimden çıkar; sonradan etkinleşen kanal kendiliğinden eklenmez', () {
      var s = const ChannelSelection().reconcile(enabled);
      s = s.reconcile({1, 3});
      expect(s.sortedChannels, [1, 3]);
      s = s.reconcile({1, 2, 3, 4});
      expect(s.sortedChannels, [1, 3]);
    });

    test('referans kanal: seçili en küçük; seçim boşsa ilk etkin kanal', () {
      final s = const ChannelSelection().reconcile(enabled).toggle(1, enabled);
      expect(s.referenceChannel(enabled), 2);
      expect(s.clear().referenceChannel(enabled), 1);
      expect(const ChannelSelection().referenceChannel(const {}), isNull);
    });
  });

  group('Bağlantı katmanı: sendSetMulti', () {
    late MemoryTokenStore tokens;
    setUp(() async {
      tokens = MemoryTokenStore();
      await tokens.write(_dev.id, 'tok');
    });

    test('aynı renk seçili kanallara TEK set mesajıyla (ch dizisi) ve yalnızca color alanıyla gider', () async {
      final sock = FakeSocket();
      final c = _controller(tokens, sock);
      await c.connect(_dev);
      await settle();
      c.sendSetMulti([1, 3], {'color': const {'r': 1, 'g': 2, 'b': 3}});
      await settle();
      expect(sock.sets.length, 1);
      final m = sock.sets.single;
      expect(m['ch'], [1, 3]);
      expect(m.keys.toSet(), {'v', 'type', 'id', 'ch', 'color'}, reason: 'efekt/hız vb. gönderilmez');
      c.dispose();
    });

    test('rengi zaten aynı olan kanal atlanır (o kanala hiçbir komut gitmez)', () async {
      final sock = FakeSocket();
      final c = _controller(tokens, sock);
      await c.connect(_dev);
      await settle();
      c.sendSetMulti([1, 2, 3], {'color': _red}); // CH2 zaten kırmızı
      await settle();
      expect(sock.sets.single['ch'], [1, 3]);
      c.dispose();
    });

    test('tek kanal seçiliyse geriye uyumlu tamsayı ch kullanılır', () async {
      final sock = FakeSocket();
      final c = _controller(tokens, sock);
      await c.connect(_dev);
      await settle();
      c.sendSetMulti([2], {'speed': 90});
      await settle();
      expect(sock.sets.single['ch'], 2);
      c.dispose();
    });

    test('hızlı renk çarkı sürüklemesi çoklu kanalda da birleştirilir', () async {
      final sock = FakeSocket();
      final c = _controller(tokens, sock);
      await c.connect(_dev);
      await settle();
      for (var v = 0; v < 40; v++) {
        c.sendSetMulti([1, 2, 3], {'color': {'r': v, 'g': 10, 'b': 20}});
      }
      await settle(200);
      expect(sock.sets.length, lessThanOrEqualTo(3));
      expect(sock.sets.last['ch'], [1, 2, 3]);
      expect(sock.sets.last['color'], {'r': 39, 'g': 10, 'b': 20});
      c.dispose();
    });
  });

  group('Sağlayıcılar: seçili kanallara uygulama (uçtan uca, sahte ESP32)', () {
    late ProviderContainer container;
    late FakeSocket sock;

    setUp(() async {
      SharedPreferences.setMockInitialValues({'app_mode': 'device'});
      final tokens = MemoryTokenStore();
      await tokens.write(_dev.id, 'tok');
      sock = FakeSocket();
      container = ProviderContainer(overrides: [
        connectionProvider.overrideWith((ref) => _controller(tokens, sock)),
      ]);
      container.read(deviceProvider); // gönderici bağlanır
      await settle(50); // uygulama modu (device) yüklenir
      await container.read(connectionProvider.notifier).connect(_dev);
      await settle();
    });

    tearDown(() => container.dispose());

    test('ilk durumda etkin kanallar (CH1–CH3) seçili; seçim değişimi cihaza mesaj göndermez', () async {
      expect(container.read(channelSelectionProvider).sortedChannels, [1, 2, 3]);
      final before = sock.sent.length;
      container.read(channelSelectionProvider.notifier).toggle(2);
      container.read(channelSelectionProvider.notifier).toggle(2);
      container.read(channelSelectionProvider.notifier).clear();
      container.read(channelSelectionProvider.notifier).selectAll();
      await settle();
      expect(sock.sent.length, before, reason: 'seçim yalnızca yereldir; animasyonlar etkilenmez');
    });

    test('renk yalnızca seçili kanallara gider; seçilmeyen kanal ve efektler değişmez', () async {
      container.read(channelSelectionProvider.notifier).toggle(2); // CH2 seçimi kaldır -> {1,3}
      container.read(deviceProvider.notifier).setColor(const LedColor(r: 10, g: 200, b: 30));
      await settle();
      final m = sock.sets.single;
      expect(m['ch'], [1, 3]);
      expect(m['color'], {'r': 10, 'g': 200, 'b': 30});
      expect(m.containsKey('effect'), isFalse);
      expect(sock.sets.any((s) => s['ch'] == 2 || (s['ch'] is List && (s['ch'] as List).contains(2))), isFalse);
      // Kanalların efektleri yerel durumda da korunur
      final ch = container.read(connectionProvider).channels;
      expect(ch[2]!.effect, EffectType.fire);
      expect(ch[3]!.effect, EffectType.comet);
    });

    test('hazır renk: referans kanalda aynı olsa bile diğer seçili kanallara uygulanır', () async {
      // Referans CH2 (kırmızı); CH3 mavi. Kırmızı hazır rengi seçilir -> yalnızca CH3'e gider (CH2 zaten kırmızı).
      container.read(channelSelectionProvider.notifier)
        ..clear()
        ..toggle(2)
        ..toggle(3);
      await settle(20);
      expect(container.read(referenceChannelProvider), 2);
      container.read(deviceProvider.notifier).setColor(const LedColor(r: 255, g: 0, b: 0));
      await settle();
      expect(sock.sets.single['ch'], 3);
      expect(sock.sets.single['color'], _red);
    });

    test('hiçbir kanal seçili değilse renk komutu gönderilmez ve yerel durum değişmez', () async {
      container.read(channelSelectionProvider.notifier).clear();
      await settle(20);
      final before = container.read(deviceProvider);
      container.read(deviceProvider.notifier).setColor(const LedColor(r: 1, g: 1, b: 1));
      container.read(deviceProvider.notifier).setEffect(EffectType.rainbow);
      await settle();
      expect(sock.sets, isEmpty);
      expect(container.read(deviceProvider), before);
    });

    test('ters yön yalnızca seçili kanallara direction:-1 olarak gider', () async {
      container.read(channelSelectionProvider.notifier).toggle(2); // {1,3}
      container.read(deviceProvider.notifier).setDirection(-1);
      await settle();
      expect(sock.sets.single['ch'], [1, 3]);
      expect(sock.sets.single['direction'], -1);
      expect(sock.sets.single.keys.toSet(), {'v', 'type', 'id', 'ch', 'direction'});
    });

    test('parlaklık ve güç yalnızca seçili kanallara gider (iPhone paneliyle aynı)', () async {
      container.read(channelSelectionProvider.notifier).toggle(1); // {2,3}
      await settle(20);
      container.read(deviceProvider.notifier).setBrightness(77);
      await settle();
      container.read(deviceProvider.notifier).togglePower();
      await settle();
      expect(sock.sets.map((m) => m['ch']).toList(), [
        [2, 3],
        [2, 3],
      ]);
      expect(sock.sets[0]['brightness'], 77);
      expect(sock.sets[1]['power'], isFalse);
    });

    test('kontroller referans kanalı gösterir (seçili en küçük kanal)', () async {
      container.read(channelSelectionProvider.notifier).toggle(1); // {2,3}
      await settle(20);
      expect(container.read(deviceProvider).effectType, EffectType.fire);
    });
  });

  group('ChannelSelector bileşeni', () {
    Map<int, ChannelState> channels() => {
          for (final j in _fourChannels()) (j['ch'] as int): ChannelState.tryParse(j)!,
        };

    Future<ChannelSelection> pump(WidgetTester t, ChannelSelection sel, void Function(int) onToggle) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChannelSelector(
            channels: channels(),
            selection: sel,
            onToggle: onToggle,
            onSelectAll: () {},
            onClear: () {},
          ),
        ),
      ));
      return sel;
    }

    testWidgets('dört kanal checkbox ile gösterilir; GPIO numarası gösterilmez', (t) async {
      await pump(t, const ChannelSelection(selected: {1, 3}, initialized: true), (_) {});
      for (var ch = 1; ch <= 4; ch++) {
        expect(find.byKey(Key('ch_checkbox_$ch')), findsOneWidget);
        expect(find.text('CH$ch'), findsOneWidget);
      }
      expect(find.textContaining('GPIO'), findsNothing);
      expect(t.widget<Checkbox>(find.byKey(const Key('ch_checkbox_1'))).value, isTrue);
      expect(t.widget<Checkbox>(find.byKey(const Key('ch_checkbox_2'))).value, isFalse);
      expect(t.widget<Checkbox>(find.byKey(const Key('ch_checkbox_4'))).onChanged, isNull, reason: 'kapalı kanal');
      expect(find.textContaining('CH1, CH3'), findsOneWidget);
    });

    testWidgets('dokunma seçimi değiştirir; kapalı kanala dokunma yok sayılır', (t) async {
      final taps = <int>[];
      await pump(t, const ChannelSelection(selected: {1}, initialized: true), taps.add);
      await t.tap(find.byKey(const Key('ch_select_2')));
      await t.tap(find.byKey(const Key('ch_checkbox_3')));
      await t.tap(find.byKey(const Key('ch_select_4')));
      expect(taps, [2, 3]);
    });

    testWidgets('boş seçimde uyarı gösterilir', (t) async {
      await pump(t, const ChannelSelection(selected: {}, initialized: true), (_) {});
      expect(find.textContaining('Kanal seçilmedi'), findsOneWidget);
    });
  });

  group('Windows ↔ iPhone ve firmware sözleşmesi', () {
    test('hazır renkler iPhone paneliyle aynı liste ve sırada', () {
      final page = File('../firmware/src/wled/control_page.h').readAsStringSync();
      final m = RegExp(r'var PRE=(\[\[.*?\]\]);').firstMatch(page);
      expect(m, isNotNull);
      final nums = RegExp(r'\d+').allMatches(m!.group(1)!).map((e) => int.parse(e.group(0)!)).toList();
      final web = [for (var i = 0; i < nums.length; i += 3) [nums[i], nums[i + 1], nums[i + 2]]];
      final win = [for (final p in kPresetColors) [p.color.r, p.color.g, p.color.b]];
      expect(web, win);
    });

    test('sabit GPIO eşlemesi config.h LED_CHANNEL_HW: CH1=18 CH2=19 CH3=22 CH4=23', () {
      final cfg = File('../firmware/include/config.h').readAsStringSync();
      final block = RegExp(r'LED_CHANNEL_HW\[MAX_CHANNELS\] = \{(.*?)\};', dotAll: true).firstMatch(cfg)!.group(1)!;
      final pins = RegExp(r'\{\s*(\d+)\s*,').allMatches(block).map((e) => int.parse(e.group(1)!)).toList();
      expect(pins, [18, 19, 22, 23]);
      // Pinler başka hiçbir kaynak dosyada sabit olarak yazılmaz (tek merkez)
      for (final f in Directory('../firmware/src').listSync(recursive: true).whereType<File>()) {
        expect(f.readAsStringSync().contains('_DEFAULT_GPIO'), isFalse, reason: f.path);
      }
    });

    test('arayüzde GPIO ayarı/numarası yok (Windows kaynakları)', () {
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        final code = f.readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
        expect(code.contains('GPIO'), isFalse, reason: f.path);
      }
    });
  });
}
