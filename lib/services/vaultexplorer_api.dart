
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/mounted_container.dart';

class vaultexplorerApi {
  static const _channel = MethodChannel('com.aeidolon.vaultexplorer/engine');

  static Future<({String uri, String displayName})?> pickContainer() async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>('pickContainer');
    if (raw == null) return null;
    final uri         = raw['uri']         as String;
    final displayName = raw['displayName'] as String;
    return (uri: uri, displayName: displayName);
  }

  static Future<({int volId, List<String> files})?> unlockContainer(
    String filePath,
    String password,
    int pim, {
    String? displayName,
  }) async {
    final raw =
        await _channel.invokeMethod<Map<Object?, Object?>>('unlockContainer', {
      'filePath': filePath,
      'password': password,
      'pim': pim,
      if (displayName != null) 'displayName': displayName,
    });
    if (raw == null) return null;
    final volId = raw['volId'] as int;
    final files = (raw['files'] as List<Object?>).cast<String>();
    return (volId: volId, files: files);
  }

  static Future<bool> lockContainer(String filePath) async {
    final result = await _channel.invokeMethod<bool>('lockContainer', {
      'filePath': filePath,
    });
    return result ?? false;
  }

  static Future<bool> openWithApp(
      MountedContainer container, String fileName) async {
    final result = await _channel.invokeMethod<bool>('openWithApp', {
      'filePath': container.uri,
      'fileName': fileName,
    });
    return result ?? false;
  }

  static Future<bool> decryptFile(
    MountedContainer container,
    String fileName,
    String destPath,
  ) async {
    final result = await _channel.invokeMethod<bool>('decryptFile', {
      'filePath': container.uri,
      'password': container.password,
      'pim': container.pim,
      'fileName': fileName,
      'destPath': destPath,
    });
    return result ?? false;
  }

  static Future<bool> importFile(
      MountedContainer container, String targetPath) async {
    final result = await _channel.invokeMethod<bool>('importFile', {
      'filePath': container.uri,
      'password': container.password,
      'pim': container.pim,
      'targetPath': targetPath,
    });
    return result ?? false;
  }

  static Future<bool> exportFileToStorage(
      MountedContainer container, String sourcePath) async {
    final result = await _channel.invokeMethod<bool>('exportFileToStorage', {
      'filePath': container.uri,
      'password': container.password,
      'pim': container.pim,
      'sourcePath': sourcePath,
    });
    return result ?? false;
  }

  static Future<int> getFileSize(
      MountedContainer container, String fileName) async {
    final result = await _channel.invokeMethod<int>('getFileSize', {
      'filePath': container.uri,
      'password': container.password,
      'pim': container.pim,
      'fileName': fileName,
    });
    return result ?? 0;
  }

  static Future<Uint8List?> readFileChunk(
    MountedContainer container,
    String fileName,
    int offset,
    int length,
  ) async {
    final result = await _channel.invokeMethod<Uint8List>('readFileChunk', {
      'filePath': container.uri,
      'password': container.password,
      'pim': container.pim,
      'fileName': fileName,
      'offset': offset,
      'length': length,
    });
    return result;
  }

  static Future<List<String>?> listDirectory(
      MountedContainer container, String dirPath) async {
    final result =
        await _channel.invokeMethod<List<Object?>>('listDirectory', {
      'filePath': container.uri,
      'password': container.password,
      'pim': container.pim,
      'dirPath': dirPath,
    });
    return result?.cast<String>();
  }

  static Future<bool> createDirectory(
      MountedContainer container, String dirPath) async {
    final result = await _channel.invokeMethod<bool>('createDirectory', {
      'filePath': container.uri,
      'password': container.password,
      'pim': container.pim,
      'dirPath': dirPath,
    });
    return result ?? false;
  }

  static Future<bool> renameFile(
    MountedContainer container,
    String oldPath,
    String newPath,
  ) async {
    final result = await _channel.invokeMethod<bool>('renameFile', {
      'filePath': container.uri,
      'password': container.password,
      'pim': container.pim,
      'oldPath': oldPath,
      'newPath': newPath,
    });
    return result ?? false;
  }

  static Future<bool> deleteFile(
      MountedContainer container, String fileName) async {
    final result = await _channel.invokeMethod<bool>('deleteFile', {
      'filePath': container.uri,
      'password': container.password,
      'pim': container.pim,
      'fileName': fileName,
    });
    return result ?? false;
  }

  static Future<bool> writeBackFile(
    MountedContainer container,
    String fileName,
    String sourcePath,
  ) async {
    final result = await _channel.invokeMethod<bool>('writeBackFile', {
      'filePath': container.uri,
      'password': container.password,
      'pim': container.pim,
      'fileName': fileName,
      'sourcePath': sourcePath,
    });
    return result ?? false;
  }

  static Future<bool> createEmptyFile(
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

  static Future<List<int>?> getSpaceInfo(MountedContainer container) async {
    final result =
        await _channel.invokeMethod<List<Object?>>('getSpaceInfo', {
      'filePath': container.uri,
      'password': container.password,
      'pim': container.pim,
    });
    return result?.cast<int>();
  }
}