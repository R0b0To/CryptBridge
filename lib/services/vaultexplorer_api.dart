import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/mounted_container.dart';
import 'channel_methods.dart';

class VaultExplorerApi {
  const VaultExplorerApi();

  static const _channel = MethodChannel('com.aeidolon.vaultexplorer/engine');


  static final Set<int> _activeBatches = {};
  static final Set<int> _lockPending   = {};

  void beginBatch(int volId) {
    _activeBatches.add(volId);
  }

  void endBatch(int volId) {
    _activeBatches.remove(volId);
  }

  bool hasActiveBatch(int volId) => _activeBatches.contains(volId);

  /// Attempts to acquire the lock guard for [volId].
  ///
  /// Returns `true` if:
  /// - No batch is active for [volId], AND
  /// - No lock is already pending for [volId].
  ///
  /// If this returns `true` the caller MUST call [releaseLockGuard] after
  /// the lock operation completes (success or failure).

  bool acquireLockGuard(int volId) {
    if (_activeBatches.contains(volId) || _lockPending.contains(volId)) {
      return false;
    }
    _lockPending.add(volId);
    return true;
  }

  void releaseLockGuard(int volId) {
    _lockPending.remove(volId);
  }

  // ── Crypto ─────────────────────────────────────────────────────────────────

  /// PBKDF2-SHA512 via the C++ mbedTLS layer.
  ///
  /// Returns 64 raw bytes of derived key, or null on failure.
  /// [salt] must be non-empty (16 bytes recommended).
  Future<Uint8List?> hashPassword({
    required String password,
    required Uint8List salt,
    int iterations = 200000,
  }) async {
    assert(salt.isNotEmpty, 'salt must not be empty');
    final result = await _channel.invokeMethod<Uint8List>(
      ChannelMethods.hashPassword,
      {
        'password':   password,
        'salt':       salt,
        'iterations': iterations,
      },
    );
    return result;
  }

  // ── Container lifecycle ───────────────────────────────────────────────────

  Future<bool> createContainer({
    required String displayName,
    required int sizeBytes,
    required String password,
    required int pim,
    required String fileSystem,
  }) async {
    final bool? success = await _channel.invokeMethod<bool>(
      ChannelMethods.createContainer,
      {
        'displayName': displayName,
        'sizeBytes':   sizeBytes,
        'password':    password,
        'pim':         pim,
        'fileSystem':  fileSystem,
      },
    );
    return success ?? false;
  }

  Future<({String uri, String displayName})?> pickContainer() async {
    final raw = await _channel
        .invokeMethod<Map<Object?, Object?>>(ChannelMethods.pickContainer);
    if (raw == null) return null;
    return (
      uri: raw['uri'] as String,
      displayName: raw['displayName'] as String,
    );
  }

  Future<({int volId, List<String> files})?> unlockContainer(
    String filePath,
    String password,
    int pim, {
    String? displayName,
    bool documentProvider = false,
  }) async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      ChannelMethods.unlockContainer,
      {
        'filePath':         filePath,
        'password':         password,
        'pim':              pim,
        if (displayName != null) 'displayName': displayName,
        'documentProvider': documentProvider,
      },
    );
    if (raw == null) return null;
    final volId = raw['volId'] as int;
    final files = (raw['files'] as List<Object?>).cast<String>();
    return (volId: volId, files: files);
  }

  Future<bool> lockContainer(String filePath) async {
    final result = await _channel.invokeMethod<bool>(
      ChannelMethods.lockContainer,
      {'filePath': filePath},
    );
    return result ?? false;
  }

  // ── File I/O ──────────────────────────────────────────────────────────────

  Future<bool> openWithApp(MountedContainer container, String fileName) async {
    final result = await _channel.invokeMethod<bool>(
      ChannelMethods.openWithApp,
      {'filePath': container.uri, 'fileName': fileName},
    );
    return result ?? false;
  }

  Future<bool> decryptFile(
      MountedContainer container, String fileName, String destPath) async {
    final result = await _channel.invokeMethod<bool>(
      ChannelMethods.decryptFile,
      {
        'filePath': container.uri,
        'fileName': fileName,
        'destPath': destPath,
      },
    );
    return result ?? false;
  }

  Future<bool> exportFileToStorage(
      MountedContainer container, String sourcePath) async {
    final result = await _channel.invokeMethod<bool>(
      ChannelMethods.exportFileToStorage,
      {'filePath': container.uri, 'sourcePath': sourcePath},
    );
    return result ?? false;
  }

  Future<int> getFileSize(MountedContainer container, String fileName) async {
    final result = await _channel.invokeMethod<int>(
      ChannelMethods.getFileSize,
      {'filePath': container.uri, 'fileName': fileName},
    );
    return result ?? 0;
  }
  /// Returns the recursive byte total of all files inside [dirPath].
  ///
  /// This is a potentially slow operation for large directory trees; callers
  /// should invoke it on a background-triggered path (e.g. from
  /// [SelectionMixin.fetchFolderSizes]) rather than on every build cycle.
  ///
  /// Returns 0 if the container is not mounted or the directory is empty.
  Future<int> getFolderSize(MountedContainer container, String dirPath) async {
    final result = await _channel.invokeMethod<int>(
      ChannelMethods.getFolderSize,
      {'filePath': container.uri, 'dirPath': dirPath},
    );
    return result ?? 0;
  }

  Future<Uint8List?> readFileChunk(
      MountedContainer container, String fileName, int offset, int length) async {
    final result = await _channel.invokeMethod<Uint8List>(
      ChannelMethods.readFileChunk,
      {
        'filePath': container.uri,
        'fileName': fileName,
        'offset':   offset,
        'length':   length,
      },
    );
    return result;
  }

  /// Requests a scaled image thumbnail from the native Android JPEG pipeline.
  /// Returns null on failure — callers will display a standard file fallback.
  Future<Uint8List?> getImageThumbnail(
      MountedContainer container, String fileName, {int targetSize = 180}) async {
    try {
      final Uint8List? bytes = await _channel.invokeMethod<Uint8List>(
        'getImageThumbnail',
        {
          'filePath': container.uri,
          'fileName': fileName,
          'targetSize': targetSize,
        },
      );
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Triggers thumbnail generation and encryption entirely on native threads,
  /// bypassing Dart and saving directly to local App Cache [ThumbnailCacheMode.appCache].
  Future<void> generateAndCacheThumbnail({
    required MountedContainer container,
    required String filePath,
    required List<int> keyBytes,
  }) async {
    try {
      await _channel.invokeMethod<void>(
        'generateAndCacheThumbnail',
        {
          'filePath': container.uri,
          'fileName': filePath,
          'keyBytes': Uint8List.fromList(keyBytes),
        },
      );
    } catch (e) {
      debugPrint('Background thumbnail build request failed: $e');
    }
  }

  Future<List<String>?> listDirectory(
      MountedContainer container, String dirPath) async {
    final result = await _channel.invokeMethod<List<Object?>>(
      ChannelMethods.listDirectory,
      {'filePath': container.uri, 'dirPath': dirPath},
    );
    return result?.cast<String>();
  }

  Future<bool> createDirectory(
      MountedContainer container, String dirPath) async {
    final result = await _channel.invokeMethod<bool>(
      ChannelMethods.createDirectory,
      {'filePath': container.uri, 'dirPath': dirPath},
    );
    return result ?? false;
  }

  Future<bool> renameFile(
      MountedContainer container, String oldPath, String newPath) async {
    final result = await _channel.invokeMethod<bool>(
      ChannelMethods.renameFile,
      {
        'filePath': container.uri,
        'oldPath':  oldPath,
        'newPath':  newPath,
      },
    );
    return result ?? false;
  }

  Future<bool> writeFileChunk(
      MountedContainer container, String fileName, int offset, Uint8List data) async {
    final result = await _channel.invokeMethod<bool>(
      'writeFileChunk',
      {
        'filePath': container.uri,
        'fileName': fileName,
        'offset':   offset,
        'data':     data,
      },
    );
    return result ?? false;
  }

  Future<bool> deleteFile(MountedContainer container, String fileName) async {
    final result = await _channel.invokeMethod<bool>(
      ChannelMethods.deleteFile,
      {'filePath': container.uri, 'fileName': fileName},
    );
    return result ?? false;
  }

  Future<bool> writeBackFile(
      MountedContainer container, String fileName, String sourcePath) async {
    final result = await _channel.invokeMethod<bool>(
      ChannelMethods.writeBackFile,
      {
        'filePath':   container.uri,
        'fileName':   fileName,
        'sourcePath': sourcePath,
      },
    );
    return result ?? false;
  }

  Future<bool> createEmptyFile(
      MountedContainer container, String fileName) async {
    final tmpDir   = await getTemporaryDirectory();
    final tempFile = File(
        '${tmpDir.path}/cb_empty_${DateTime.now().microsecondsSinceEpoch}');
    try {
      await tempFile.create(recursive: true);
      return await writeBackFile(container, fileName, tempFile.path);
    } finally {
      if (await tempFile.exists()) await tempFile.delete();
    }
  }

  Future<List<int>?> getSpaceInfo(MountedContainer container) async {
    final result = await _channel.invokeMethod<List<Object?>>(
      ChannelMethods.getSpaceInfo,
      {'filePath': container.uri},
    );
    return result?.cast<int>();
  }

  Future<int> importFiles(MountedContainer container, String targetPath) async {
    final result = await _channel.invokeMethod<int>(
      ChannelMethods.importFile,
      {'filePath': container.uri, 'targetPath': targetPath},
    );
    return result ?? 0;
  }

  Future<int> exportSelectedToFolder(
      MountedContainer container, List<Map<String, dynamic>> items) async {
    final result = await _channel.invokeMethod<int>(
      ChannelMethods.exportFilesToFolder,
      {'filePath': container.uri, 'items': items},
    );
    return result ?? 0;
  }

  Future<int> importFolder(
      MountedContainer container, String targetPath) async {
    final result = await _channel.invokeMethod<int>(
      ChannelMethods.importFolder,
      {'filePath': container.uri, 'targetPath': targetPath},
    );
    return result ?? 0;
  }

  /// Requests a scaled video thumbnail from the native layer.
  /// Returns null on any error — callers should show a fallback icon.
  Future<Uint8List?> getVideoThumbnail(
      MountedContainer container, String fileName) async {
    try {
      final Uint8List? bytes = await _channel.invokeMethod<Uint8List>(
        ChannelMethods.getVideoThumbnail,
        {'filePath': container.uri, 'fileName': fileName},
      );
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<bool> setSecureScreen(bool enabled) async {
    try {
      final bool? success = await _channel.invokeMethod<bool>(
        ChannelMethods.setSecureScreen,
        {'enabled': enabled},
      );
      return success ?? false;
    } catch (_) {
      return false;
    }
  }
}

final vaultExplorerApi = VaultExplorerApi();