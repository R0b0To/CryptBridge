import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'vaultexplorer_api.dart';

// ── Per-container configuration ───────────────────────────────────────────────

class ContainerConfig {
  // FIX: passwords are now stored in Android Keystore via flutter_secure_storage
  // instead of XOR-obfuscated JSON fields.  The key is namespaced to the
  // container URI so each container gets its own Keystore entry.
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final String uri;
  String label;
  bool rememberPassword;
  int autoCloseMins;
  bool documentProvider;

  ContainerConfig({
    required this.uri,
    required this.label,
    this.rememberPassword = false,
    this.autoCloseMins = 0,
    this.documentProvider = false,
  });

  // ── Secure storage helpers ────────────────────────────────────────────────

  String get _storageKey => 'vc_pw_${uri.hashCode}';

  /// Reads the stored plaintext password from Android Keystore.
  /// Returns null if no password is stored.
  Future<String?> getPassword() => _secure.read(key: _storageKey);

  /// Writes [plaintext] to Android Keystore.  Pass null or empty to delete.
  Future<void> setPassword(String? plaintext) async {
    if (plaintext == null || plaintext.isEmpty) {
      await _secure.delete(key: _storageKey);
    } else {
      await _secure.write(key: _storageKey, value: plaintext);
    }
  }

  /// Removes any stored password from Keystore (call on container removal).
  Future<void> clearPassword() => _secure.delete(key: _storageKey);

  // ── Serialisation ─────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'uri': uri,
        'label': label,
        'rememberPassword': rememberPassword,
        // Note: password is NOT stored here; it lives in Android Keystore.
        'autoCloseMins': autoCloseMins,
        'documentProvider': documentProvider,
      };

  factory ContainerConfig.fromJson(Map<String, dynamic> j) => ContainerConfig(
        uri: j['uri'] as String,
        label: j['label'] as String? ?? '',
        rememberPassword: j['rememberPassword'] as bool? ?? false,
        autoCloseMins: j['autoCloseMins'] as int? ?? 0,
        documentProvider: j['documentProvider'] as bool? ?? false,
      );
}

// ── Global app settings ───────────────────────────────────────────────────────

class AppSettings {
  bool useMasterPassword;
  bool masterPasswordIsFingerprint;

  /// Base-64 encoded 64-byte PBKDF2-SHA512 output.
  /// A value with length == 8 hex chars signals the legacy 32-bit hash and
  /// will be transparently upgraded on the next successful login.
  String? masterPasswordHash;

  /// Base-64 encoded 16-byte random salt used for [masterPasswordHash].
  /// Null only for the legacy 8-char hash format (no salt was used).
  String? masterPasswordSalt;

  bool defaultDocumentProvider;
  bool videoAutoPlay;

  AppSettings({
    this.useMasterPassword = false,
    this.masterPasswordIsFingerprint = false,
    this.masterPasswordHash,
    this.masterPasswordSalt,
    this.defaultDocumentProvider = false,
    this.videoAutoPlay = true,
  });

  Map<String, dynamic> toJson() => {
        'useMasterPassword': useMasterPassword,
        'masterPasswordIsFingerprint': masterPasswordIsFingerprint,
        'masterPasswordHash': masterPasswordHash,
        'masterPasswordSalt': masterPasswordSalt,
        'defaultDocumentProvider': defaultDocumentProvider,
        'videoAutoPlay': videoAutoPlay,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        useMasterPassword: j['useMasterPassword'] as bool? ?? false,
        masterPasswordIsFingerprint:
            j['masterPasswordIsFingerprint'] as bool? ?? false,
        masterPasswordHash: j['masterPasswordHash'] as String?,
        masterPasswordSalt: j['masterPasswordSalt'] as String?,
        defaultDocumentProvider: j['defaultDocumentProvider'] as bool? ??
            (j['mountAsDocumentProvider'] as bool? ?? false),
        videoAutoPlay: j['videoAutoPlay'] as bool? ?? true,
      );

  // ── Password verification ─────────────────────────────────────────────────

  /// True if the stored hash uses the old insecure 32-bit format and should
  /// be upgraded after the next successful login.
  bool get needsHashUpgrade =>
      masterPasswordHash != null &&
      masterPasswordSalt == null &&
      masterPasswordHash!.length == 8;

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
  /// Handles two cases:
  /// - Legacy (no salt): uses the old 32-bit rolling hash for one last check,
  ///   so returning users are not locked out.
  /// - Current: PBKDF2-SHA512 with stored salt, constant-time comparison.
  Future<bool> checkPassword(String candidate) async {
    if (masterPasswordHash == null) return false;

    if (needsHashUpgrade) {
      return _legacyCheckPassword(candidate);
    }

    if (masterPasswordSalt == null) return false;

    final saltBytes = base64Decode(masterPasswordSalt!);
    final hashBytes = await vaultExplorerApi.hashPassword(
      password: candidate,
      salt: saltBytes,
      iterations: 200000,
    );
    if (hashBytes == null) return false;

    final storedHash = base64Decode(masterPasswordHash!);
    return _secureEqual(hashBytes, storedHash);
  }

  // Constant-time byte comparison to prevent timing attacks.
  static bool _secureEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) result |= a[i] ^ b[i];
    return result == 0;
  }

  // ── Legacy hash (kept only for one-shot migration) ───────────────────────

  bool _legacyCheckPassword(String candidate) {
    var h = 0xdeadbeef;
    for (final c in candidate.codeUnits) {
      h = ((h << 5) + h + c) & 0xFFFFFFFF;
    }
    for (final c in candidate.codeUnits.toList().reversed) {
      h = ((h >> 3) ^ (h << 7) ^ c) & 0xFFFFFFFF;
    }
    final computed = h.toUnsigned(32).toRadixString(16).padLeft(8, '0');
    return computed == masterPasswordHash;
  }
}

// ── Legacy XOR helpers — kept only for migration on first load ────────────────

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

  static Future<File> get _containerConfigsFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/container_configs.json');
  }

  static Future<AppSettings> loadSettings() async {
    try {
      final file = await _settingsFile;
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        return AppSettings.fromJson(j);
      }
    } catch (_) {}
    return AppSettings();
  }

  static Future<void> saveSettings(AppSettings settings) async {
    try {
      final file = await _settingsFile;
      await file.writeAsString(jsonEncode(settings.toJson()));
    } catch (_) {}
  }

  static Future<Map<String, ContainerConfig>> loadContainerConfigs() async {
    try {
      final file = await _containerConfigsFile;
      if (await file.exists()) {
        final list = jsonDecode(await file.readAsString()) as List<dynamic>;
        final configs = <String, ContainerConfig>{};
        bool migrationNeeded = false;

        for (final item in list) {
          final j      = item as Map<String, dynamic>;
          final config = ContainerConfig.fromJson(j);
          configs[config.uri] = config;

          // One-time migration: if the old JSON had an obfuscated password,
          // move it to Keystore and drop the plaintext field from the file.
          final legacyField = j['obfuscatedPassword'] as String? ??
              j['encryptedPassword'] as String?;
          if (legacyField != null &&
              legacyField.isNotEmpty &&
              config.rememberPassword) {
            try {
              final dir = await getApplicationDocumentsDirectory();
              final key = _deriveLegacyKey(dir.path);
              final plain = _legacyDeobfuscate(legacyField, key) ?? legacyField;
              await config.setPassword(plain);
              migrationNeeded = true;
            } catch (_) {}
          }
        }

        if (migrationNeeded) {
          // Rewrite without the legacy password fields.
          await _saveConfigs(configs);
        }

        return configs;
      }
    } catch (_) {}
    return {};
  }

  static Future<void> _saveConfigs(Map<String, ContainerConfig> configs) async {
    final file = await _containerConfigsFile;
    await file.writeAsString(
        jsonEncode(configs.values.map((c) => c.toJson()).toList()));
  }

  static Future<void> saveContainerConfig(ContainerConfig config) async {
    try {
      final configs = await loadContainerConfigs();
      configs[config.uri] = config;
      await _saveConfigs(configs);
    } catch (_) {}
  }

  static Future<void> removeContainerConfig(String uri) async {
    try {
      final configs = await loadContainerConfigs();
      final removed = configs.remove(uri);
      // Clean up Keystore entry so we don't leave orphaned secrets.
      if (removed?.rememberPassword == true) {
        await removed!.clearPassword();
      }
      await _saveConfigs(configs);
    } catch (_) {}
  }

  static Future<ContainerConfig?> getContainerConfig(String uri) async {
    final configs = await loadContainerConfigs();
    return configs[uri];
  }
}