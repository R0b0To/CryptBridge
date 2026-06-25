import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/mounted_container.dart';

class VaultExplorerApi {
  const VaultExplorerApi();

  static const _channel = MethodChannel('com.aeidolon.vaultexplorer/engine');

  Future<bool> createContainer({
    required String displayName,
    required int sizeBytes,
    required String password,
    required int pim,
    required String fileSystem,
  }) async {
    final bool? success = await _channel.invokeMethod<bool>('createContainer', {
      'displayName': displayName,
      'sizeBytes': sizeBytes,
      'password': password,
      'pim': pim,
      'fileSystem': fileSystem,
    });
    return success ?? false;
  }

  Future<({String uri, String displayName})?> pickContainer() async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>('pickContainer');
    if (raw == null) return null;
    return (uri: raw['uri'] as String, displayName: raw['displayName'] as String);
  }

  Future<({int volId, List<String> files})?> unlockContainer(
    String filePath,
    String password,
    int pim, {
    String? displayName,
    bool documentProvider = false,
  }) async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>('unlockContainer', {
      'filePath': filePath,
      'password': password,
      'pim': pim,
      if (displayName != null) 'displayName': displayName,
      'documentProvider': documentProvider,
    });
    if (raw == null) return null;
    final volId = raw['volId'] as int;
    final files = (raw['files'] as List<Object?>).cast<String>();
    return (volId: volId, files: files);
  }

  Future<bool> lockContainer(String filePath) async {
    final result = await _channel.invokeMethod<bool>('lockContainer', {
      'filePath': filePath,
    });
    return result ?? false;
  }

  Future<bool> openWithApp(MountedContainer container, String fileName) async {
    final result = await _channel.invokeMethod<bool>('openWithApp', {
      'filePath': container.uri,
      'fileName': fileName,
    });
    return result ?? false;
  }

  Future<bool> decryptFile(
      MountedContainer container, String fileName, String destPath) async {
    final result = await _channel.invokeMethod<bool>('decryptFile', {
      'filePath': container.uri,
      'fileName': fileName,
      'destPath': destPath,
    });
    return result ?? false;
  }

  Future<bool> exportFileToStorage(
      MountedContainer container, String sourcePath) async {
    final result = await _channel.invokeMethod<bool>('exportFileToStorage', {
      'filePath': container.uri,
      'sourcePath': sourcePath,
    });
    return result ?? false;
  }

  Future<int> getFileSize(MountedContainer container, String fileName) async {
    final result = await _channel.invokeMethod<int>('getFileSize', {
      'filePath': container.uri,
      'fileName': fileName,
    });
    return result ?? 0;
  }

  Future<Uint8List?> readFileChunk(
      MountedContainer container, String fileName, int offset, int length) async {
    final result = await _channel.invokeMethod<Uint8List>('readFileChunk', {
      'filePath': container.uri,
      'fileName': fileName,
      'offset': offset,
      'length': length,
    });
    return result;
  }

  Future<List<String>?> listDirectory(
      MountedContainer container, String dirPath) async {
    final result = await _channel.invokeMethod<List<Object?>>('listDirectory', {
      'filePath': container.uri,
      'dirPath': dirPath,
    });
    return result?.cast<String>();
  }

  Future<bool> createDirectory(
      MountedContainer container, String dirPath) async {
    final result = await _channel.invokeMethod<bool>('createDirectory', {
      'filePath': container.uri,
      'dirPath': dirPath,
    });
    return result ?? false;
  }

  Future<bool> renameFile(
      MountedContainer container, String oldPath, String newPath) async {
    final result = await _channel.invokeMethod<bool>('renameFile', {
      'filePath': container.uri,
      'oldPath': oldPath,
      'newPath': newPath,
    });
    return result ?? false;
  }

  Future<bool> deleteFile(MountedContainer container, String fileName) async {
    final result = await _channel.invokeMethod<bool>('deleteFile', {
      'filePath': container.uri,
      'fileName': fileName,
    });
    return result ?? false;
  }

  Future<bool> writeBackFile(
      MountedContainer container, String fileName, String sourcePath) async {
    final result = await _channel.invokeMethod<bool>('writeBackFile', {
      'filePath': container.uri,
      'fileName': fileName,
      'sourcePath': sourcePath,
    });
    return result ?? false;
  }

  Future<bool> createEmptyFile(
      MountedContainer container, String fileName) async {
    final tmpDir = await getTemporaryDirectory();
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
    final result =
        await _channel.invokeMethod<List<Object?>>('getSpaceInfo', {
      'filePath': container.uri,
    });
    return result?.cast<int>();
  }

  Future<int> importFiles(MountedContainer container, String targetPath) async {
    final result = await _channel.invokeMethod<int>('importFile', {
      'filePath': container.uri,
      'targetPath': targetPath,
    });
    return result ?? 0;
  }

  Future<int> exportSelectedToFolder(
      MountedContainer container, List<Map<String, dynamic>> items) async {
    final result = await _channel.invokeMethod<int>('exportFilesToFolder', {
      'filePath': container.uri,
      'items': items,
    });
    return result ?? 0;
  }

  Future<int> importFolder(
      MountedContainer container, String targetPath) async {
    final result = await _channel.invokeMethod<int>('importFolder', {
      'filePath': container.uri,
      'targetPath': targetPath,
    });
    return result ?? 0;
  }

  /// Extracts multiple video frames from memory over JNI and returns them
  /// as compressed JPEGs to be animated smoothly in grid items.
  Future<Uint8List?> getVideoThumbnail(MountedContainer container, String fileName) async {
    try {
     final Uint8List? bytes = await _channel.invokeMethod<Uint8List>('getVideoThumbnail', {
        'filePath': container.uri,
        'fileName': fileName,
      });
      return bytes;
    } catch (e) {
      _channel.setMethodCallHandler(null);
      return null;
    }
  }
}

final vaultExplorerApi = VaultExplorerApi();