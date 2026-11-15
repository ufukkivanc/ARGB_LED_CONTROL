import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:argb_controller/services/device_discovery.dart';
import 'package:argb_controller/services/token_store.dart';
import 'package:argb_controller/state/connection_controller.dart';

// ── Kalıcı (gizli olmayan) ayarlar ────────────────────────────────────────
// Token ve Wi-Fi şifresi BURADA saklanmaz. Yalnızca mod, cihaz adresleri ve
// tercihler tutulur. Depolama kullanılamazsa (test/ön izleme) sessizce yok sayılır.

class KnownDevice {
  final String id;
  final String name;
  final String host;
  final int port;
  const KnownDevice({required this.id, required this.name, required this.host, this.port = 80});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'host': host, 'port': port};

  static KnownDevice? tryParse(dynamic j) {
    if (j is! Map || j['id'] is! String || j['host'] is! String) return null;
    return KnownDevice(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? 'ESP32 ARGB',
      host: j['host'] as String,
      port: (j['port'] as num?)?.toInt() ?? 80,
    );
  }

  FoundDevice toFound() => FoundDevice(id: id, name: name, host: host, port: port);
}

class SettingsStorage {
  static const _kMode = 'app_mode';
  static const _kDevices = 'known_devices';
  static const _kLast = 'last_device_id';
  static const _kWebPersist = 'web_persist_tokens';

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  Future<AppMode> loadMode() async {
    final p = await _prefs();
    return p?.getString(_kMode) == 'device' ? AppMode.device : AppMode.simulation;
  }

  Future<void> saveMode(AppMode m) async {
    final p = await _prefs();
    await p?.setString(_kMode, m == AppMode.device ? 'device' : 'simulation');
  }

  Future<List<KnownDevice>> loadDevices() async {
    final p = await _prefs();
    final raw = p?.getString(_kDevices);
    if (raw == null) return [];
    try {
      final l = jsonDecode(raw);
      if (l is! List) return [];
      return l.map(KnownDevice.tryParse).whereType<KnownDevice>().toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveDevices(List<KnownDevice> d) async {
    final p = await _prefs();
    await p?.setString(_kDevices, jsonEncode(d.map((e) => e.toJson()).toList()));
  }

  Future<String?> loadLastDeviceId() async => (await _prefs())?.getString(_kLast);

  Future<void> saveLastDeviceId(String? id) async {
    final p = await _prefs();
    if (id == null) {
      await p?.remove(_kLast);
    } else {
      await p?.setString(_kLast, id);
    }
  }

  Future<bool> loadWebPersist() async => (await _prefs())?.getBool(_kWebPersist) ?? false;

  Future<void> saveWebPersist(bool v) async {
    final p = await _prefs();
    await p?.setBool(_kWebPersist, v);
  }
}

final settingsStorageProvider = Provider<SettingsStorage>((ref) => SettingsStorage());

class AppModeNotifier extends StateNotifier<AppMode> {
  AppModeNotifier(this._storage) : super(AppMode.simulation) {
    _load();
  }
  final SettingsStorage _storage;

  Future<void> _load() async {
    final m = await _storage.loadMode();
    if (mounted) state = m;
  }

  Future<void> set(AppMode m) async {
    state = m;
    await _storage.saveMode(m);
  }
}

final appModeProvider = StateNotifierProvider<AppModeNotifier, AppMode>(
  (ref) => AppModeNotifier(ref.read(settingsStorageProvider)),
);

class KnownDevicesNotifier extends StateNotifier<List<KnownDevice>> {
  KnownDevicesNotifier(this._storage) : super(const []) {
    _load();
  }
  final SettingsStorage _storage;

  Future<void> _load() async {
    final d = await _storage.loadDevices();
    if (mounted) state = d;
  }

  Future<void> upsert(KnownDevice d) async {
    state = [...state.where((e) => e.id != d.id), d];
    await _storage.saveDevices(state);
  }

  Future<void> remove(String id) async {
    state = state.where((e) => e.id != id).toList();
    await _storage.saveDevices(state);
  }
}

final knownDevicesProvider = StateNotifierProvider<KnownDevicesNotifier, List<KnownDevice>>(
  (ref) => KnownDevicesNotifier(ref.read(settingsStorageProvider)),
);

/// Flutter Web: token'ı tarayıcı depolamasında kalıcı tutmak (GÜVENLİ DEĞİL). Varsayılan: kapalı.
class WebPersistNotifier extends StateNotifier<bool> {
  WebPersistNotifier(this._storage) : super(false) {
    _load();
  }
  final SettingsStorage _storage;
  Future<void> _load() async {
    final v = await _storage.loadWebPersist();
    if (mounted) state = v;
  }

  Future<void> set(bool v) async {
    state = v;
    await _storage.saveWebPersist(v);
  }
}

final webPersistProvider = StateNotifierProvider<WebPersistNotifier, bool>(
  (ref) => WebPersistNotifier(ref.read(settingsStorageProvider)),
);

final tokenStoreProvider = Provider<TokenStore>((ref) {
  final persist = ref.watch(webPersistProvider);
  return SecureTokenStore(allowWebPersistence: persist);
});

final discoveryProvider = Provider<DeviceDiscovery>((ref) => DeviceDiscovery());

final connectionProvider =
    StateNotifierProvider<DeviceConnectionController, DeviceConnection>((ref) {
  return DeviceConnectionController(
    tokens: ref.watch(tokenStoreProvider),
    discovery: ref.read(discoveryProvider),
  );
});

/// Seçili LED kanalı (1..4) — yalnızca cihaz modunda anlamlıdır.
final selectedChannelProvider = StateProvider<int>((ref) => 1);
