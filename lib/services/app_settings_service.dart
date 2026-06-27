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

  /// True if the stored hash uses the old insecure 32-bit format.
  bool get needsHashUpgrade =>
      _masterPasswordHash != null &&
      _masterPasswordSalt == null &&
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

  /// Derives a new PBKDF2-SHA512 hash + random salt.
  /// Returns (base64Hash, base64Salt).
  static Future<(String hash, String salt)> derivePasswordHash(
      String plaintext) async {
    final saltBytes = Uint8List(16);
    final rng = Random.secure();
    for (int i = 0; i < 16; i++) saltBytes[i] = rng.nextInt(256);

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
  ///
  /// PERF-05 fix: legacy check is now dispatched via [compute] so it
  /// never blocks the UI isolate.
  Future<bool> checkPassword(String candidate) async {
    if (_masterPasswordHash == null) return false;

    if (needsHashUpgrade) {
      return compute(_legacyCheckIsolate,
          _LegacyCheckParams(_masterPasswordHash!, candidate));
    }

    if (_masterPasswordSalt == null) return false;

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

// ── Legacy hash helpers — isolate-safe, kept only for one-shot migration ─────

class _LegacyCheckParams {
  final String storedHash;
  final String candidate;
  const _LegacyCheckParams(this.storedHash, this.candidate);
}

/// Top-level function so [compute] can spawn it in a separate isolate.
bool _legacyCheckIsolate(_LegacyCheckParams params) {
  var h = 0xdeadbeef;
  for (final c in params.candidate.codeUnits) {
    h = ((h << 5) + h + c) & 0xFFFFFFFF;
  }
  for (final c in params.candidate.codeUnits.toList().reversed) {
    h = ((h >> 3) ^ (h << 7) ^ c) & 0xFFFFFFFF;
  }
  final computed = h.toUnsigned(32).toRadixString(16).padLeft(8, '0');
  return computed == params.storedHash;
}

// ── Legacy XOR helpers — kept only for ContainerRepository migration ──────────

String _deriveLegacyKey(String seed) {
  var h = 0x9e3779b9;
  for (final c in seed.codeUnits) {
    h = ((h << 5) ^ (h >> 2) ^ c) & 0xFFFFFFFF;
  }
  final bytes = List<int>.generate(32, (i) {
    var v = (h ^ (i * 0x6c62272e)) & 0xFF;
    h = ((h << 3) ^ h ^ v) & 0xFFFFFFFF;
    return v;
  });
  return base64Encode(bytes);
}

String? _legacyDeobfuscate(String? cipherB64, String keyB64) {
  if (cipherB64 == null || cipherB64.isEmpty) return null;
  try {
    final keyBytes = base64Decode(keyB64);
    final ctBytes  = base64Decode(cipherB64);
    final out = List<int>.generate(
        ctBytes.length, (i) => ctBytes[i] ^ keyBytes[i % keyBytes.length]);
    return utf8.decode(out);
  } catch (_) {
    return null;
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

        final legacyHash = raw.remove('masterPasswordHash') as String?;
        final legacySalt = raw.remove('masterPasswordSalt') as String?;

        settings = AppSettings.fromJson(raw);

        if (legacyHash != null) {
          // Write to Keystore only if not already there.
          final existing = await _secure.read(key: _kMasterHash);
          if (existing == null) {
            await _secure.write(key: _kMasterHash, value: legacyHash);
            if (legacySalt != null) {
              await _secure.write(key: _kMasterSalt, value: legacySalt);
            }
          }
          // Rewrite without the legacy fields.
          await file.writeAsString(jsonEncode(settings.toJson()));
        }
      } else {
        settings = AppSettings();
      }
    } catch (_) {
      settings = AppSettings();
    }

    // Populate in-memory hash material from Keystore.
    if (settings.useMasterPassword) {
      final hash = await _secure.read(key: _kMasterHash);
      final salt = await _secure.read(key: _kMasterSalt);
      if (hash != null) {
        settings._setHashMaterial(hash, salt ?? '');
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

  // ── Legacy container config loading — used only for one-time migration ────

  static Future<void> migrateLegacyContainerData() async {
    final repo = ContainerRepository.instance;
    final newFile = File(
        '${(await getApplicationDocumentsDirectory()).path}/containers_v2.json');
    if (await newFile.exists()) return;

    final savedList   = await _loadLegacySaved();
    final configList  = await _loadLegacyConfigs();
    await repo.migrateFromLegacy(
        savedList: savedList, configList: configList);

    // Migrate legacy obfuscated passwords to Keystore.
    final dir = await getApplicationDocumentsDirectory();
    final key = _deriveLegacyKey(dir.path);
    for (final cfg in configList) {
      final uri         = cfg['uri'] as String? ?? '';
      final remember    = cfg['rememberPassword'] as bool? ?? false;
      if (!remember || uri.isEmpty) continue;

      final legacyField = cfg['obfuscatedPassword'] as String? ??
          cfg['encryptedPassword'] as String?;
      if (legacyField == null || legacyField.isEmpty) continue;

      // BUG-05 fix: only store if deobfuscation actually succeeds.
      final plain = _legacyDeobfuscate(legacyField, key);
      if (plain != null && plain.isNotEmpty) {
        final record = (await repo.loadAll())[uri];
        if (record != null) {
          await repo.save(record.copyWith(
            rememberPassword: true,
            pendingPassword: plain,
          ));
        }
      }
      // If deobfuscation fails we simply don't migrate — the user will be
      // prompted for their password on next unlock, which is safe.
    }
  }

  static Future<List<Map<String, String>>> _loadLegacySaved() async {
    try {
      final dir  = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/saved_containers.json');
      if (!await file.exists()) return [];
      final list = jsonDecode(await file.readAsString()) as List<dynamic>;
      return list
          .map((item) => {
                'uri':  item['uri']  as String,
                'name': item['name'] as String,
              })
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> _loadLegacyConfigs() async {
    try {
      final dir  = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/container_configs.json');
      if (!await file.exists()) return [];
      return (jsonDecode(await file.readAsString()) as List<dynamic>)
          .cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }
}