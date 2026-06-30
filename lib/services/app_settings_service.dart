import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import '../models/thumbnail_cache_mode.dart';
import 'container_repository.dart';

export 'container_repository.dart' show ContainerRepository, ContainerRecord;

// ── Secure storage instance ───────────────────────────────────────────────────

const _secure = FlutterSecureStorage(
  aOptions: AndroidOptions(),
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
  bool blockScreenshots;

  /// App-wide default thumbnail cache mode, applied to every container whose
  /// [ContainerRecord.thumbnailCacheMode] is null.
  ThumbnailCacheMode defaultThumbnailCacheMode;

  String? _masterPasswordHash;
  String? _masterPasswordSalt;

  AppSettings({
    this.useMasterPassword = false,
    this.masterPasswordIsFingerprint = false,
    this.defaultDocumentProvider = false,
    this.videoAutoPlay = true,
    this.blockScreenshots = false,
    this.defaultThumbnailCacheMode = ThumbnailCacheMode.disabled,
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
        'blockScreenshots': blockScreenshots,
        'defaultThumbnailCacheMode': defaultThumbnailCacheMode.toJson(),
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
      useMasterPassword: j['useMasterPassword'] as bool? ?? false,
      masterPasswordIsFingerprint:
          j['masterPasswordIsFingerprint'] as bool? ?? false,
      defaultDocumentProvider: j['defaultDocumentProvider'] as bool? ??
          j['mountAsDocumentProvider'] as bool? ?? false,
      videoAutoPlay: j['videoAutoPlay'] as bool? ?? true,
      blockScreenshots: j['blockScreenshots'] as bool? ?? false,

      // Resolve nullable parsed mode and default to appCache if null
      defaultThumbnailCacheMode: ThumbnailCacheMode.fromJson(
          j['defaultThumbnailCacheMode'] as String?) ?? ThumbnailCacheMode.appCache,
    );
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