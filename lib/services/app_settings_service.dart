import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'vaultexplorer_api.dart';
import 'container_repository.dart';

export 'container_repository.dart' show ContainerRepository, ContainerRecord;

// ── Secure storage instance ───────────────────────────────────────────────────

const _secure = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

// Keystore keys for master password material.
const _kMasterHash = 'vc_master_hash_v2';
const _kMasterSalt = 'vc_master_salt_v2';

// ── Global app settings ───────────────────────────────────────────────────────

class AppSettings {
  bool useMasterPassword;
  bool masterPasswordIsFingerprint;
  bool defaultDocumentProvider;
  bool videoAutoPlay;

  String? _masterPasswordHash;
  String? _masterPasswordSalt;

  AppSettings({
    this.useMasterPassword = false,
    this.masterPasswordIsFingerprint = false,
    this.defaultDocumentProvider = false,
    this.videoAutoPlay = true,
    String? masterPasswordHash,
    String? masterPasswordSalt,
  })  : _masterPasswordHash = masterPasswordHash,
        _masterPasswordSalt = masterPasswordSalt;

  // Read-only accessors — callers must not store these; use Keystore directly.
  String? get masterPasswordHash => _masterPasswordHash;
  String? get masterPasswordSalt => _masterPasswordSalt;

  // Used internally by AppSettingsService after a successful hash derivation.
  void _setHashMaterial(String hash, String salt) {
    _masterPasswordHash = hash;
    _masterPasswordSalt = salt;
  }

  void _clearHashMaterial() {
    _masterPasswordHash = null;
    _masterPasswordSalt = null;
  }

  bool get needsHashUpgrade =>
      _masterPasswordHash != null &&
      (_masterPasswordSalt == null || _masterPasswordSalt!.isEmpty) &&
      _masterPasswordHash!.length == 8;

  /// Serialises only non-secret preferences to JSON.
  /// Hash material is intentionally excluded.
  Map<String, dynamic> toJson() => {
        'useMasterPassword': useMasterPassword,
        'masterPasswordIsFingerprint': masterPasswordIsFingerprint,
        'defaultDocumentProvider': defaultDocumentProvider,
        'videoAutoPlay': videoAutoPlay,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        useMasterPassword: j['useMasterPassword'] as bool? ?? false,
        masterPasswordIsFingerprint:
            j['masterPasswordIsFingerprint'] as bool? ?? false,
        defaultDocumentProvider: j['defaultDocumentProvider'] as bool? ??
            j['mountAsDocumentProvider'] as bool? ?? false,
        videoAutoPlay: j['videoAutoPlay'] as bool? ?? true,
        // Hash material is NOT loaded here — AppSettingsService.loadSettings
        // reads it separately from Keystore.
      );

  // ── Password verification ─────────────────────────────────────────────────

  static Future<(String hash, String salt)> derivePasswordHash(
      String plaintext) async {
    final saltBytes = Uint8List(16);
    final rng = Random.secure();
    for (int i = 0; i < 16; i++) {
      saltBytes[i] = rng.nextInt(256);
    }

    final hashBytes = await vaultExplorerApi.hashPassword(
      password: plaintext,
      salt: saltBytes,
      iterations: 200000,
    );
    if (hashBytes == null || hashBytes.isEmpty) {
      throw StateError('PBKDF2 derivation failed');
    }
    return (base64Encode(hashBytes), base64Encode(saltBytes));
  }

  /// Verifies [candidate] against the stored hash using PBKDF2-SHA512.
  Future<bool> checkPassword(String candidate) async {
    if (_masterPasswordHash == null) return false;

    if (_masterPasswordSalt == null || _masterPasswordSalt!.isEmpty) {
      return false;
    }

    final saltBytes = base64Decode(_masterPasswordSalt!);
    final hashBytes = await vaultExplorerApi.hashPassword(
      password: candidate,
      salt: saltBytes,
      iterations: 200000,
    );
    if (hashBytes == null) return false;

    final storedHash = base64Decode(_masterPasswordHash!);
    return _secureEqual(hashBytes, storedHash);
  }

  // Constant-time byte comparison to prevent timing attacks.
  static bool _secureEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) result |= a[i] ^ b[i];
    return result == 0;
  }
}


// ── Persistence service ───────────────────────────────────────────────────────

class AppSettingsService {
  static Future<File> get _settingsFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/app_settings.json');
  }

  static Future<AppSettings> loadSettings() async {
    AppSettings settings;
    try {
      final file = await _settingsFile;
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        settings = AppSettings.fromJson(raw);
      } else {
        settings = AppSettings();
      }
    } catch (_) {
      settings = AppSettings();
    }

    // Populate in-memory hash material from Keystore.
    if (settings.useMasterPassword) {
      final hash = await _secure.read(key: _kMasterHash);
      final salt = await _secure.read(key: _kMasterSalt) ?? '';
      if (hash != null) {
        settings._setHashMaterial(hash, salt);
      }
    }

    return settings;
  }

  /// Saves non-secret preferences to JSON.
  /// Hash material is written to Keystore separately via [saveMasterPassword].
  static Future<void> saveSettings(AppSettings settings) async {
    try {
      final file = await _settingsFile;
      await file.writeAsString(jsonEncode(settings.toJson()));
    } catch (_) {}
  }

  /// Writes master-password hash + salt to Android Keystore.
  static Future<void> saveMasterPassword(
      AppSettings settings, String hash, String salt) async {
    settings._setHashMaterial(hash, salt);
    await _secure.write(key: _kMasterHash, value: hash);
    await _secure.write(key: _kMasterSalt, value: salt);
    await saveSettings(settings);
  }

  /// Removes master-password hash + salt from Keystore and resets settings.
  static Future<void> clearMasterPassword(AppSettings settings) async {
    settings._clearHashMaterial();
    await _secure.delete(key: _kMasterHash);
    await _secure.delete(key: _kMasterSalt);
    await saveSettings(settings);
  }


}