import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:isolate'; // Required for Isolate.run

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:encrypt/encrypt.dart' as enc;

import '../models/mounted_container.dart';
import '../models/thumbnail_cache_mode.dart';
import 'vaultexplorer_api.dart';
import 'app_cache_encryption.dart';

class ThumbnailCacheService {
  ThumbnailCacheService._();

  static const inContainerDir = '.thumbcache';
  static const int _gcmNonceSize = 12;

  // ── OPTIMIZATION 1: In-Memory Key Cache ─────────────────────────────────────
  static enc.Key? _cachedKey;

  /// Retrieves the key once from secure storage, then caches it in volatile memory.
  static Future<enc.Key> _getOrFetchKey() async {
    if (_cachedKey != null) return _cachedKey!;
    final key = await AppCacheEncryption.getEncryptionKey();
    _cachedKey = key;
    return key;
  }

  // ── OPTIMIZATION 2: Background Cryptography ─────────────────────────────────
  
  /// Decrypts AES-GCM bytes on a background isolate to keep the UI smooth.
  static Future<Uint8List> _decryptBackground(
    Uint8List rawBytes,
    enc.Key key,
  ) async {
    return await Isolate.run(() {
      final nonce = enc.IV(Uint8List.fromList(rawBytes.sublist(0, _gcmNonceSize)));
      final ciphertext = enc.Encrypted(
          Uint8List.fromList(rawBytes.sublist(_gcmNonceSize)));

      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
      final decrypted = encrypter.decryptBytes(ciphertext, iv: nonce);
      return Uint8List.fromList(decrypted);
    });
  }
/// Retrieves or loads the key from secure storage, keeping it cached in memory.
  static Future<enc.Key> getOrFetchKey() async {
    if (_cachedKey != null) return _cachedKey!;
    final key = await AppCacheEncryption.getEncryptionKey();
    _cachedKey = key;
    return key;
  }
  /// Encrypts bytes with AES-GCM on a background isolate.
  static Future<Uint8List> _encryptBackground(
    Uint8List data,
    enc.Key key,
  ) async {
    return await Isolate.run(() {
      final nonce = enc.IV.fromSecureRandom(_gcmNonceSize);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
      final encrypted = encrypter.encryptBytes(data, iv: nonce);

      // Layout: [12-byte nonce][GCM ciphertext+tag]
      final outputBytes = BytesBuilder(copy: false)
        ..add(nonce.bytes)
        ..add(encrypted.bytes);

      return outputBytes.takeBytes();
    });
  }

  static String _encodeKey(String filePath) {
    final encoded = base64Url.encode(utf8.encode(filePath));
    return encoded.length > 180 ? encoded.substring(0, 180) : encoded;
  }

  static Future<Directory> _appDir(MountedContainer container) async {
    final root = await getApplicationCacheDirectory();
    final dir = Directory('${root.path}/thumbs/${container.volId}');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _appFile(
      MountedContainer container, String filePath) async {
    final dir = await _appDir(container);
    return File('${dir.path}/${_encodeKey(filePath)}');
  }

  static String _inContainerPath(String filePath) =>
      '$inContainerDir/${_encodeKey(filePath)}';

  // ── Public read ───────────────────────────────────────────────────────────

  static Future<Uint8List?> get({
    required MountedContainer container,
    required String filePath,
    required ThumbnailCacheMode mode,
  }) async {
    if (mode == ThumbnailCacheMode.disabled) return null;
    try {
      if (mode == ThumbnailCacheMode.appCache) {
        final file = await _appFile(container, filePath);
        if (!await file.exists()) return null;

        final rawBytes = await file.readAsBytes();

        if (rawBytes.length <= _gcmNonceSize + 16) return null;

        // Fetching the cached key avoids repeating expensive native platform calls.
        final key = await _getOrFetchKey();

        // Performs pure-Dart decryption safely in a background thread.
        final decryptedBytes = await _decryptBackground(rawBytes, key);

        return decryptedBytes;
      } else {
        final cachePath = _inContainerPath(filePath);
        final size = await vaultExplorerApi.getFileSize(container, cachePath);
        if (size > 0) {
          return await vaultExplorerApi.readFileChunk(
              container, cachePath, 0, size);
        }
      }
    } catch (e) {
      debugPrint('ThumbnailCacheService.get: cache miss due to error: $e');
    }
    return null;
  }

  // ── Public write ──────────────────────────────────────────────────────────

  static Future<void> put({
    required MountedContainer container,
    required String filePath,
    required Uint8List data,
    required ThumbnailCacheMode mode,
  }) async {
    if (mode == ThumbnailCacheMode.disabled || data.isEmpty) return;
    try {
      if (mode == ThumbnailCacheMode.appCache) {
        final file = await _appFile(container, filePath);

        final key  = await _getOrFetchKey();

        // Encrypts in the background to ensure writing doesn't pause the UI.
        final outputBytes = await _encryptBackground(data, key);

        final tmpFile = File('${file.path}.tmp');
        await tmpFile.writeAsBytes(outputBytes, flush: true);
        await tmpFile.rename(file.path);

      } else {
        final cachePath    = _inContainerPath(filePath);
        final tmpCachePath = '$cachePath.tmp';

        await vaultExplorerApi.createDirectory(container, inContainerDir);

        await vaultExplorerApi.deleteFile(container, tmpCachePath);
        final writeOk = await vaultExplorerApi.writeFileChunk(
            container, tmpCachePath, 0, data);

        if (writeOk) {
          await vaultExplorerApi.deleteFile(container, cachePath);
          await vaultExplorerApi.renameFile(container, tmpCachePath, cachePath);
        } else {
          await vaultExplorerApi.deleteFile(container, tmpCachePath);
          debugPrint('ThumbnailCacheService.put: inContainer write failed for $filePath');
        }
      }
    } catch (e) {
      debugPrint('ThumbnailCacheService.put: non-fatal error: $e');
    }
  }

  // ── Cache introspection & management ──────────────────────────────────────

  static Future<int> appCacheBytesFor(MountedContainer container) async {
    try {
      final dir = await _appDir(container);
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) total += await entity.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static Future<int> totalAppCacheBytes() async {
    try {
      final root = await getApplicationCacheDirectory();
      final dir = Directory('${root.path}/thumbs');
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) total += await entity.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> clearAppCacheFor(MountedContainer container) async {
    try {
      final dir = await _appDir(container);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  static Future<void> clearAllAppCache() async {
    try {
      final root = await getApplicationCacheDirectory();
      final dir = Directory('${root.path}/thumbs');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  static Future<void> pruneStaleAppCache(Set<int> activeVolIds) async {
    try {
      final root = await getApplicationCacheDirectory();
      final thumbs = Directory('${root.path}/thumbs');
      if (!await thumbs.exists()) return;
      await for (final entity in thumbs.list()) {
        if (entity is! Directory) continue;
        final volId = int.tryParse(entity.path.split('/').last);
        if (volId != null && !activeVolIds.contains(volId)) {
          await entity.delete(recursive: true);
        }
      }
    } catch (_) {}
  }
}