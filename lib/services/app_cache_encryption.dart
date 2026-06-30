import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:encrypt/encrypt.dart' as enc;

class AppCacheEncryption {
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _kCacheKey = 'app_cache_aes_key';

  static enc.Key? _cachedKey;

  /// Retrieves the persistent symmetric key, creating it if it doesn't exist.
  static Future<enc.Key> getEncryptionKey() async {
    if (_cachedKey != null) return _cachedKey!;

    final base64Key = await _secure.read(key: _kCacheKey);
    if (base64Key != null) {
      _cachedKey = enc.Key.fromBase64(base64Key);
      return _cachedKey!;
    }

    // Generate a fresh cryptographically secure 256-bit key
    final freshKey = enc.Key.fromSecureRandom(32);
    await _secure.write(key: _kCacheKey, value: freshKey.base64);
    _cachedKey = freshKey;
    return freshKey;
  }
}
