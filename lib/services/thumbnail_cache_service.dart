import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:encrypt/encrypt.dart' as enc;

import '../models/mounted_container.dart';
import '../models/thumbnail_cache_mode.dart';
import '../utils/lru_cache.dart';
import 'vaultexplorer_api.dart';
import 'app_cache_encryption.dart';

/// Three-tier thumbnail cache.
///
/// Tier 1 — static in-memory [LruCache] ([_memoryCache])
///   Synchronous O(1). Survives widget dispose/recreate within a session.
///   120 entries × ~20 KB ≈ 2.4 MB maximum footprint.
///
/// Tier 2 — encrypted disk file (appCache) or container file (inContainer).
///   AES-GCM runs inline for small thumbnails (< [_computeThresholdBytes])
///   and is offloaded to a background isolate via [compute()] for larger data.
///   This prevents the UI thread from dropping frames when the gallery grid
///   stores a full-resolution fallback image (up to ~200 KB).
///
/// Tier 3 — full container read (handled by callers on a complete miss).
class ThumbnailCacheService {
  ThumbnailCacheService._();

  // ── Constants ──────────────────────────────────────────────────────────────
  static const inContainerDir = '.thumbcache';
  static const _gcmNonceSize  = 12;
  static const _gcmTagSize    = 16;

  /// Data above this size is encrypted/decrypted in a background isolate via
  /// [compute()] to avoid blocking the UI thread.
  /// Below this threshold the inline path (~0.3 ms) is cheaper than the
  /// isolate spawn overhead (~5–10 ms).
  static const _computeThresholdBytes = 100 * 1024; // 100 KB

  // ── Tier 1: static in-memory LRU ──────────────────────────────────────────
  static final _memoryCache = LruCache<String, Uint8List>(120);

  // ── AES key ────────────────────────────────────────────────────────────────
  static enc.Key? _cachedKey;
  static Future<enc.Key> getOrFetchKey() async =>
      _cachedKey ??= await AppCacheEncryption.getEncryptionKey();

  // ── App-cache directory — resolved once ───────────────────────────────────
  static String? _appCacheRoot;
  static Future<String> _thumbDir(int volId) async {
    _appCacheRoot ??= (await getApplicationCacheDirectory()).path;
    return '$_appCacheRoot/thumbs/$volId';
  }

  // ── Filename encoding ──────────────────────────────────────────────────────
  static String _encodeKey(String filePath) {
    final encoded = base64Url.encode(utf8.encode(filePath));
    return encoded.length > 180 ? encoded.substring(0, 180) : encoded;
  }

  // ── AES-GCM helpers ────────────────────────────────────────────────────────

  /// Decrypt [raw] inline (called when data is below [_computeThresholdBytes]).
  static Uint8List? _decryptInline(Uint8List raw, enc.Key key) {
    if (raw.length <= _gcmNonceSize + _gcmTagSize) return null;
    try {
      final iv         = enc.IV(raw.sublist(0, _gcmNonceSize));
      final ciphertext = enc.Encrypted(raw.sublist(_gcmNonceSize));
      return Uint8List.fromList(
        enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm))
            .decryptBytes(ciphertext, iv: iv),
      );
    } catch (_) {
      return null;
    }
  }

  /// Encrypt [data] inline (called when data is below [_computeThresholdBytes]).
  static Uint8List _encryptInline(Uint8List data, enc.Key key) {
    final iv        = enc.IV.fromSecureRandom(_gcmNonceSize);
    final encrypted =
        enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm)).encryptBytes(data, iv: iv);
    final out = Uint8List(_gcmNonceSize + encrypted.bytes.length);
    out.setRange(0, _gcmNonceSize, iv.bytes);
    out.setRange(_gcmNonceSize, out.length, encrypted.bytes);
    return out;
  }

  // ── Top-level functions for compute() ─────────────────────────────────────
  //
  // compute() cannot capture closures or instance members — the function must
  // be a static method or a top-level function.  We pass all required data as
  // a single record argument.

  static Uint8List? _decryptIsolate(_DecryptArgs args) {
    if (args.raw.length <= _gcmNonceSize + _gcmTagSize) return null;
    try {
      final key        = enc.Key(args.keyBytes);
      final iv         = enc.IV(args.raw.sublist(0, _gcmNonceSize));
      final ciphertext = enc.Encrypted(args.raw.sublist(_gcmNonceSize));
      return Uint8List.fromList(
        enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm))
            .decryptBytes(ciphertext, iv: iv),
      );
    } catch (_) {
      return null;
    }
  }

  static Uint8List _encryptIsolate(_EncryptArgs args) {
    final key       = enc.Key(args.keyBytes);
    final iv        = enc.IV.fromSecureRandom(_gcmNonceSize);
    final encrypted =
        enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm))
            .encryptBytes(args.data, iv: iv);
    final out = Uint8List(_gcmNonceSize + encrypted.bytes.length);
    out.setRange(0, _gcmNonceSize, iv.bytes);
    out.setRange(_gcmNonceSize, out.length, encrypted.bytes);
    return out;
  }

  // ── Dispatch helpers ───────────────────────────────────────────────────────

  /// Decrypt [raw] — inline for small data, background isolate for large data.
  static Future<Uint8List?> _decrypt(Uint8List raw, enc.Key key) async {
    if (raw.length < _computeThresholdBytes) {
      return _decryptInline(raw, key);
    }
    return compute(_decryptIsolate, _DecryptArgs(raw: raw, keyBytes: key.bytes));
  }

  /// Encrypt [data] — inline for small data, background isolate for large data.
  static Future<Uint8List> _encrypt(Uint8List data, enc.Key key) async {
    if (data.length < _computeThresholdBytes) {
      return _encryptInline(data, key);
    }
    return compute(_encryptIsolate, _EncryptArgs(data: data, keyBytes: key.bytes));
  }

  // ── Memory-tier public helpers ─────────────────────────────────────────────

  static String _memKey(MountedContainer container, String filePath) =>
      '${container.volId}:$filePath';

  /// Synchronous O(1) lookup into the in-memory tier.
  static Uint8List? getFromMemory(MountedContainer container, String filePath) =>
      _memoryCache[_memKey(container, filePath)];

  /// Writes directly to the in-memory tier.
  static void putInMemory(
      MountedContainer container, String filePath, Uint8List data) =>
      _memoryCache[_memKey(container, filePath)] = data;

  // ── Public: read ──────────────────────────────────────────────────────────

  static Future<Uint8List?> get({
    required MountedContainer container,
    required String filePath,
    required ThumbnailCacheMode mode,
  }) async {
    if (mode == ThumbnailCacheMode.disabled) return null;

    // Tier 1: memory.
    final mem = getFromMemory(container, filePath);
    if (mem != null) return mem;

    // Tier 2: disk / in-container.
    try {
      if (mode == ThumbnailCacheMode.appCache) {
        final dir  = await _thumbDir(container.volId);
        final file = File('$dir/${_encodeKey(filePath)}');

        final Uint8List raw;
        try {
          raw = await file.readAsBytes();
        } on PathNotFoundException {
          return null;
        } catch (_) {
          return null;
        }

        if (raw.length <= _gcmNonceSize + _gcmTagSize) return null;

        final key       = await getOrFetchKey();
        final decrypted = await _decrypt(raw, key);
        if (decrypted == null || decrypted.isEmpty) return null;

        putInMemory(container, filePath, decrypted);
        return decrypted;
      } else {
        // inContainer: stored unencrypted inside the FAT filesystem.
        final cachePath = '$inContainerDir/${_encodeKey(filePath)}';
        final size = await vaultExplorerApi.getFileSize(container, cachePath);
        if (size <= 0) return null;
        final bytes =
            await vaultExplorerApi.readFileChunk(container, cachePath, 0, size);
        if (bytes != null && bytes.isNotEmpty) {
          putInMemory(container, filePath, bytes);
        }
        return bytes;
      }
    } catch (e) {
      debugPrint('ThumbnailCacheService.get: $e');
      return null;
    }
  }

  // ── Public: write ─────────────────────────────────────────────────────────

  static Future<void> put({
    required MountedContainer container,
    required String filePath,
    required Uint8List data,
    required ThumbnailCacheMode mode,
  }) async {
    if (mode == ThumbnailCacheMode.disabled || data.isEmpty) return;

    putInMemory(container, filePath, data);

    try {
      if (mode == ThumbnailCacheMode.appCache) {
        final dirPath = await _thumbDir(container.volId);
        final dir     = Directory(dirPath);
        if (!await dir.exists()) await dir.create(recursive: true);

        final file      = File('$dirPath/${_encodeKey(filePath)}');
        final key       = await getOrFetchKey();
        final encrypted = await _encrypt(data, key);

        // Atomic write: temp file → rename.
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsBytes(encrypted, flush: true);
        await tmp.rename(file.path);
      } else {
        final cachePath = '$inContainerDir/${_encodeKey(filePath)}';
        final tmpPath   = '$cachePath.tmp';
        await vaultExplorerApi.createDirectory(container, inContainerDir);
        await vaultExplorerApi.deleteFile(container, tmpPath);
        final ok =
            await vaultExplorerApi.writeFileChunk(container, tmpPath, 0, data);
        if (ok) {
          await vaultExplorerApi.deleteFile(container, cachePath);
          await vaultExplorerApi.renameFile(container, tmpPath, cachePath);
        } else {
          await vaultExplorerApi.deleteFile(container, tmpPath);
          debugPrint('ThumbnailCacheService.put: inContainer write failed for $filePath');
        }
      }
    } catch (e) {
      debugPrint('ThumbnailCacheService.put: $e');
    }
  }

  // ── Cache management ───────────────────────────────────────────────────────

  static Future<int> appCacheBytesFor(MountedContainer container) async {
    try {
      final dir = Directory(await _thumbDir(container.volId));
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final e in dir.list()) {
        if (e is File) total += await e.length();
      }
      return total;
    } catch (_) { return 0; }
  }

  static Future<int> totalAppCacheBytes() async {
    try {
      _appCacheRoot ??= (await getApplicationCacheDirectory()).path;
      final dir = Directory('$_appCacheRoot/thumbs');
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final e in dir.list(recursive: true)) {
        if (e is File) total += await e.length();
      }
      return total;
    } catch (_) { return 0; }
  }

  static Future<void> clearAppCacheFor(MountedContainer container) async {
    try {
      final dir = Directory(await _thumbDir(container.volId));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    _memoryCache.clear();
  }

  static Future<void> clearAllAppCache() async {
    try {
      _appCacheRoot ??= (await getApplicationCacheDirectory()).path;
      final dir = Directory('$_appCacheRoot/thumbs');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    _memoryCache.clear();
  }

  static Future<void> pruneStaleAppCache(Set<int> activeVolIds) async {
    try {
      _appCacheRoot ??= (await getApplicationCacheDirectory()).path;
      final root = Directory('$_appCacheRoot/thumbs');
      if (!await root.exists()) return;
      await for (final e in root.list()) {
        if (e is! Directory) continue;
        final id = int.tryParse(e.path.split('/').last);
        if (id != null && !activeVolIds.contains(id)) {
          await e.delete(recursive: true);
        }
      }
    } catch (_) {}
  }
}

// ── compute() argument records ─────────────────────────────────────────────
//
// compute() requires serialisable arguments.  Plain classes with only
// Uint8List fields are safe to pass across isolate boundaries.

class _DecryptArgs {
  final Uint8List raw;
  final Uint8List keyBytes;
  const _DecryptArgs({required this.raw, required this.keyBytes});
}

class _EncryptArgs {
  final Uint8List data;
  final Uint8List keyBytes;
  const _EncryptArgs({required this.data, required this.keyBytes});
}