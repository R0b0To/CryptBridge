import 'package:flutter/services.dart';

import '../models/mounted_container.dart';

/// Result type returned by [CryptBridgeApi.unlockContainer].
typedef UnlockResult = ({int volId, List<String> files});

/// Static wrapper around the native MethodChannel.
/// All communication with Kotlin/C++ goes through here.
class CryptBridgeApi {
  CryptBridgeApi._(); // not instantiable

  static const _channel = MethodChannel('com.example.cryptbridge/engine');

  /// Opens the system file picker and returns the chosen URI string, or null
  /// if the user cancelled.
  static Future<String?> pickContainer() =>
      _channel.invokeMethod<String>('pickContainer');

  /// Decrypts and mounts a container. Returns [UnlockResult] with the assigned
  /// volume slot and root file listing on success, or null on auth failure.
  /// Throws [PlatformException] on native errors.
  static Future<UnlockResult?> unlockContainer(
    String filePath,
    String password,
    int pim,
  ) async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
      'unlockContainer',
      {'filePath': filePath, 'password': password, 'pim': pim},
    );
    if (raw == null) return null;
    final volId = raw['volId'] as int;
    final files = (raw['files'] as List<Object?>).cast<String>();
    return (volId: volId, files: files);
  }

  /// Unmounts the container identified by [filePath] and scrubs its keys.
  /// Returns true if a mounted session was found and removed.
  static Future<bool> lockContainer(String filePath) async {
    final result = await _channel.invokeMethod<bool>(
      'lockContainer',
      {'filePath': filePath},
    );
    return result ?? false;
  }

  /// Decrypts a single [fileName] from [container] and writes it to [destPath].
  static Future<bool> decryptFile(
    MountedContainer container,
    String fileName,
    String destPath,
  ) async {
    final result = await _channel.invokeMethod<bool>(
      'decryptFile',
      {
        'filePath': container.uri,
        'password': container.password,
        'pim': container.pim,
        'fileName': fileName,
        'destPath': destPath,
      },
    );
    return result ?? false;
  }

  // ---------------------------------------------------------------------------
  // Future: subdirectory listing
  // ---------------------------------------------------------------------------
  // Uncomment once listDirectoryNative is implemented in C++ / Kotlin.
  //
  // static Future<List<String>?> listDirectory(
  //   MountedContainer container,
  //   String dirPath,
  // ) async {
  //   final raw = await _channel.invokeMethod<List<dynamic>>(
  //     'listDirectory',
  //     {
  //       'filePath': container.uri,
  //       'password': container.password,
  //       'pim': container.pim,
  //       'dirPath': dirPath,
  //     },
  //   );
  //   return raw?.cast<String>();
  // }
}
