import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Cihaz token'larının saklanması.
///
/// - Android: Keystore destekli EncryptedSharedPreferences, iOS: Keychain.
/// - Flutter Web: platformda güvenli kalıcı saklama YOKTUR. Varsayılan olarak token
///   yalnızca bellekte (sekme/oturum süresince) tutulur. Kullanıcı açıkça izin verirse
///   (geliştirme amaçlı) tarayıcı depolamasına yazılır — bu GÜVENLİ DEĞİLDİR.
abstract class TokenStore {
  Future<String?> read(String deviceId);
  Future<void> write(String deviceId, String token);
  Future<void> delete(String deviceId);

  /// Token kalıcı olarak saklanıyor mu (kullanıcıya bilgi göstermek için).
  bool get isPersistent;
}

/// Yalnızca bellekte (uygulama kapanınca silinir).
class MemoryTokenStore implements TokenStore {
  final Map<String, String> _tokens = {};

  @override
  bool get isPersistent => false;

  @override
  Future<String?> read(String deviceId) async => _tokens[deviceId];

  @override
  Future<void> write(String deviceId, String token) async => _tokens[deviceId] = token;

  @override
  Future<void> delete(String deviceId) async => _tokens.remove(deviceId);
}

/// Platformun güvenli deposu (mobil) — Web'de [allowWebPersistence] açık değilse belleğe düşer.
class SecureTokenStore implements TokenStore {
  SecureTokenStore({this.allowWebPersistence = false, FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final bool allowWebPersistence;
  final FlutterSecureStorage _storage;
  final MemoryTokenStore _memory = MemoryTokenStore();

  bool get _useMemory => kIsWeb && !allowWebPersistence;

  @override
  bool get isPersistent => !_useMemory;

  String _key(String id) => 'argb_token_$id';

  @override
  Future<String?> read(String deviceId) async {
    if (_useMemory) return _memory.read(deviceId);
    try {
      return await _storage.read(key: _key(deviceId));
    } catch (_) {
      return _memory.read(deviceId);
    }
  }

  @override
  Future<void> write(String deviceId, String token) async {
    if (_useMemory) return _memory.write(deviceId, token);
    try {
      await _storage.write(key: _key(deviceId), value: token);
    } catch (_) {
      await _memory.write(deviceId, token);
    }
  }

  @override
  Future<void> delete(String deviceId) async {
    await _memory.delete(deviceId);
    if (_useMemory) return;
    try {
      await _storage.delete(key: _key(deviceId));
    } catch (_) {}
  }
}
