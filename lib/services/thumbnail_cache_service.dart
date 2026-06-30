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
///
/// Tier 3 — full container read (handled by callers on a complete miss).
///
/// ### Cache isolation across container lock/unlock cycles
///
/// Memory keys include [MountedContainer.mountedAt] so that a different
/// container mounted into the same volume slot always gets a fresh key —
/// stale entries from the previous session are never served and are evicted
/// naturally by LRU.
///
/// Disk cache directories are keyed by the container's URI (base64-encoded)
/// rather than by volId, so two different container files that happen to share
/// a slot at different times never collide on disk.
class ThumbnailCacheService {
  ThumbnailCacheService._();

  // ── Constants ──────────────────────────────────────────────────────────────
  static const inContainerDir = '.thumbcache';
  static const _gcmNonceSize = 12;
  static const _gcmTagSize = 16;

  /// Data above this size is encrypted/decrypted in a background isolate via
  /// [compute()] to avoid blocking the UI thread.
  static const _computeThresholdBytes = 100 * 1024; // 100 KB

  // ── Tier 1: static in-memory LRU ──────────────────────────────────────────
  static final _memoryCache = LruCache<String, Uint8List>(120);

  // ── AES key ────────────────────────────────────────────────────────────────
  static enc.Key? _cachedKey;
  static Future<enc.Key> getOrFetchKey() async =>
      _cachedKey ??= await AppCacheEncryption.getEncryptionKey();

  // ── App-cache directory — resolved once ───────────────────────────────────
  //
  // Keyed by the container's URI (base64-encoded and truncated to 180 chars)
  // rather than by volId. Two different container files that happen to occupy
  // the same volume slot at different times therefore never share a disk
  // directory, eliminating stale thumbnail cross-contamination.
  static String? _appCacheRoot;

  static Future<String> _thumbDir(MountedContainer container) async {
    _appCacheRoot ??= (await getApplicationCacheDirectory()).path;
    return '$_appCacheRoot/thumbs/${_encodeKey(container.uri)}';
  }

  // ── Filename / key encoding ────────────────────────────────────────────────
  static String _encodeKey(String value) {
    final encoded = base64Url.encode(utf8.encode(value));
    return encoded.length > 180 ? encoded.substring(0, 180) : encoded;
  }

  // ── Memory-tier key ───────────────────────────────────────────────────────
  //
  // Includes mountedAt so that a new session for the same volId always
  // generates a distinct key, preventing stale bytes from a previous container
  // from being served without a disk/API round-trip.
  static String _memKey(MountedContainer container, String filePath) =>
      '${container.volId}:${container.mountedAt.millisecondsSinceEpoch}:$filePath';

  // ── AES-GCM helpers ────────────────────────────────────────────────────────

  static Uint8List? _decryptInline(Uint8List raw, enc.Key key) {
    if (raw.length <= _gcmNonceSize + _gcmTagSize) return null;
    try {
      final iv = enc.IV(raw.sublist(0, _gcmNonceSize));
      final ciphertext = enc.Encrypted(raw.sublist(_gcmNonceSize));
      return Uint8List.fromList(
        enc.Encrypter(
          enc.AES(key, mode: enc.AESMode.gcm),
        ).decryptBytes(ciphertext, iv: iv),
      );
    } catch (_) {
      return null;
    }
  }

  static Uint8List _encryptInline(Uint8List data, enc.Key key) {
    final iv = enc.IV.fromSecureRandom(_gcmNonceSize);
    final encrypted = enc.Encrypter(
      enc.AES(key, mode: enc.AESMode.gcm),
    ).encryptBytes(data, iv: iv);
    final out = Uint8List(_gcmNonceSize + encrypted.bytes.length);
    out.setRange(0, _gcmNonceSize, iv.bytes);
    out.setRange(_gcmNonceSize, out.length, encrypted.bytes);
    return out;
  }

  // ── Top-level functions for compute() ─────────────────────────────────────

  static Uint8List? _decryptIsolate(_DecryptArgs args) {
    if (args.raw.length <= _gcmNonceSize + _gcmTagSize) return null;
    try {
      final key = enc.Key(args.keyBytes);
      final iv = enc.IV(args.raw.sublist(0, _gcmNonceSize));
      final ciphertext = enc.Encrypted(args.raw.sublist(_gcmNonceSize));
      return Uint8List.fromList(
        enc.Encrypter(
          enc.AES(key, mode: enc.AESMode.gcm),
        ).decryptBytes(ciphertext, iv: iv),
      );
    } catch (_) {
      return null;
    }
  }

  static Uint8List _encryptIsolate(_EncryptArgs args) {
    final key = enc.Key(args.keyBytes);
    final iv = enc.IV.fromSecureRandom(_gcmNonceSize);
    final encrypted = enc.Encrypter(
      enc.AES(key, mode: enc.AESMode.gcm),
    ).encryptBytes(args.data, iv: iv);
    final out = Uint8List(_gcmNonceSize + encrypted.bytes.length);
    out.setRange(0, _gcmNonceSize, iv.bytes);
    out.setRange(_gcmNonceSize, out.length, encrypted.bytes);
    return out;
  }

  // ── Dispatch helpers ───────────────────────────────────────────────────────

  static Future<Uint8List?> _decrypt(Uint8List raw, enc.Key key) async {
    if (raw.length < _computeThresholdBytes) {
      return _decryptInline(raw, key);
    }
    return compute(
      _decryptIsolate,
      _DecryptArgs(raw: raw, keyBytes: key.bytes),
    );
  }

  static Future<Uint8List> _encrypt(Uint8List data, enc.Key key) async {
    if (data.length < _computeThresholdBytes) {
      return _encryptInline(data, key);
    }
    return compute(
      _encryptIsolate,
      _EncryptArgs(data: data, keyBytes: key.bytes),
    );
  }

  // ── Memory-tier public helpers ─────────────────────────────────────────────

  /// Synchronous O(1) lookup into the in-memory tier.
  static Uint8List? getFromMemory(
    MountedContainer container,
    String filePath,
  ) => _memoryCache[_memKey(container, filePath)];

  /// Writes directly to the in-memory tier.
  static void putInMemory(
    MountedContainer container,
    String filePath,
    Uint8List data,
  ) => _memoryCache[_memKey(container, filePath)] = data;

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
        final dir = await _thumbDir(container);
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

        final key = await getOrFetchKey();
        final decrypted = await _decrypt(raw, key);
        if (decrypted == null || decrypted.isEmpty) return null;

        putInMemory(container, filePath, decrypted);
        return decrypted;
      } else {
        final cachePath = '$inContainerDir/${_encodeKey(filePath)}';
        final size = await vaultExplorerApi.getFileSize(container, cachePath);
        if (size <= 0) return null;
        final bytes = await vaultExplorerApi.readFileChunk(
          container,
          cachePath,
          0,
          size,
        );
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
        final dirPath = await _thumbDir(container);
        final dir = Directory(dirPath);
        if (!await dir.exists()) await dir.create(recursive: true);

        final file = File('$dirPath/${_encodeKey(filePath)}');
        final key = await getOrFetchKey();
        final encrypted = await _encrypt(data, key);

        // Atomic write: temp file → rename.
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsBytes(encrypted, flush: true);
        await tmp.rename(file.path);
      } else {
        final cachePath = '$inContainerDir/${_encodeKey(filePath)}';
        final tmpPath = '$cachePath.tmp';
        await vaultExplorerApi.createDirectory(container, inContainerDir);
        await vaultExplorerApi.deleteFile(container, tmpPath);
        final ok = await vaultExplorerApi.writeFileChunk(
          container,
          tmpPath,
          0,
          data,
        );
        if (ok) {
          await vaultExplorerApi.deleteFile(container, cachePath);
          await vaultExplorerApi.renameFile(container, tmpPath, cachePath);
        } else {
          await vaultExplorerApi.deleteFile(container, tmpPath);
          debugPrint(
            'ThumbnailCacheService.put: inContainer write failed for $filePath',
          );
        }
      }
    } catch (e) {
      debugPrint('ThumbnailCacheService.put: $e');
    }
  }

  // ── Cache management ───────────────────────────────────────────────────────

  static Future<int> appCacheBytesFor(MountedContainer container) async {
    try {
      final dir = Directory(await _thumbDir(container));
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final e in dir.list()) {
        if (e is File) total += await e.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
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
    } catch (_) {
      return 0;
    }
  }

  static Future<void> clearAppCacheFor(MountedContainer container) async {
    try {
      final dir = Directory(await _thumbDir(container));
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

  /// Deletes on-disk thumbnail directories for containers whose URIs are not
  /// in [activeContainerUris]. Call this on app start or after a bulk lock.
  ///
  /// Signature changed from `Set<int> activeVolIds` to `Set<String> activeContainerUris`
  /// because disk directories are now keyed by encoded URI, not volId.
  static Future<void> pruneStaleAppCache(
    Set<String> activeContainerUris,
  ) async {
    try {
      _appCacheRoot ??= (await getApplicationCacheDirectory()).path;
      final root = Directory('$_appCacheRoot/thumbs');
      if (!await root.exists()) return;
      final activeKeys = activeContainerUris.map(_encodeKey).toSet();
      await for (final e in root.list()) {
        if (e is! Directory) continue;
        final dirName = e.path.split('/').last;
        if (!activeKeys.contains(dirName)) {
          await e.delete(recursive: true);
        }
      }
    } catch (_) {}
  }
}

// ── compute() argument records ─────────────────────────────────────────────

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
