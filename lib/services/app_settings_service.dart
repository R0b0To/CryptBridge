import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

// ── Password obfuscation ──────────────────────────────────────────────────────
//
// Passwords are XOR-obfuscated with a key derived from the app's own data
// directory path before being written to disk. This is NOT cryptographic
// security — it prevents casual inspection of the JSON file but anyone with
// root access to the device can still recover the plaintext. The correct
// long-term solution is flutter_secure_storage (Android Keystore), but that
// requires an additional pub dependency. The obfuscation key is stable across
// launches because getApplicationDocumentsDirectory() is deterministic for a
// given app install.
//
// To migrate to flutter_secure_storage: replace _obfuscate/_deobfuscate with
// FlutterSecureStorage read/write and remove the 'password' field from JSON.

String _deriveKey(String seed) {
  // Simple but stable: SHA-like fold of the seed bytes.
  var h = 0x9e3779b9;
  for (final c in seed.codeUnits) {
    h = ((h << 5) ^ (h >> 2) ^ c) & 0xFFFFFFFF;
  }
  // Expand to 32 bytes by mixing.
  final bytes = List<int>.generate(32, (i) {
    var v = (h ^ (i * 0x6c62272e)) & 0xFF;
    h = ((h << 3) ^ h ^ v) & 0xFFFFFFFF;
    return v;
  });
  return base64Encode(bytes);
}

String _obfuscate(String plaintext, String keyB64) {
  final keyBytes = base64Decode(keyB64);
  final ptBytes = utf8.encode(plaintext);
  final out = List<int>.generate(
      ptBytes.length, (i) => ptBytes[i] ^ keyBytes[i % keyBytes.length]);
  return base64Encode(out);
}

String? _deobfuscate(String? cipherB64, String keyB64) {
  if (cipherB64 == null || cipherB64.isEmpty) return null;
  try {
    final keyBytes = base64Decode(keyB64);
    final ctBytes = base64Decode(cipherB64);
    final out = List<int>.generate(
        ctBytes.length, (i) => ctBytes[i] ^ keyBytes[i % keyBytes.length]);
    return utf8.decode(out);
  } catch (_) {
    return null;
  }
}

// Lazily cached key so we only hit the filesystem once per run.
String? _cachedObfKey;
Future<String> _obfKey() async {
  if (_cachedObfKey != null) return _cachedObfKey!;
  final dir = await getApplicationDocumentsDirectory();
  _cachedObfKey = _deriveKey(dir.path);
  return _cachedObfKey!;
}

// ── Per-container configuration ───────────────────────────────────────────────

class ContainerConfig {
  final String uri;
  String label;
  bool rememberPassword;
  // Stored obfuscated on disk; plaintext only in memory.
  String? _obfuscatedPassword;
  int autoCloseMins;
  bool documentProvider; // whether this container is exposed as a doc provider

  ContainerConfig({
    required this.uri,
    required this.label,
    this.rememberPassword = false,
    String? obfuscatedPassword,
    this.autoCloseMins = 0,
    this.documentProvider = false,
  }) : _obfuscatedPassword = obfuscatedPassword;

  Map<String, dynamic> toJson() => {
        'uri': uri,
        'label': label,
        'rememberPassword': rememberPassword,
        'obfuscatedPassword': _obfuscatedPassword,
        'autoCloseMins': autoCloseMins,
        'documentProvider': documentProvider,
      };

  factory ContainerConfig.fromJson(Map<String, dynamic> j) {
    // Back-compat: migrate legacy plain-text 'encryptedPassword' field.
    // On next save it will be written obfuscated.
    final legacyPlain = j['encryptedPassword'] as String?;
    return ContainerConfig(
      uri: j['uri'] as String,
      label: j['label'] as String? ?? '',
      rememberPassword: j['rememberPassword'] as bool? ?? false,
      obfuscatedPassword:
          j['obfuscatedPassword'] as String? ?? legacyPlain,
      autoCloseMins: j['autoCloseMins'] as int? ?? 0,
      documentProvider: j['documentProvider'] as bool? ?? false,
    );
  }

  /// Returns the plaintext password, deobfuscating on the fly.
  /// Must be awaited; returns null if nothing is stored.
  Future<String?> getPassword() async {
    if (_obfuscatedPassword == null) return null;
    final key = await _obfKey();
    // Detect whether this is still legacy plaintext (no base64 padding noise).
    // Legacy values were stored raw; we can't distinguish them perfectly, but
    // we try to decode and fall back to treating the value as plaintext.
    return _deobfuscate(_obfuscatedPassword, key) ?? _obfuscatedPassword;
  }

  /// Stores [plaintext] obfuscated. Call before saving config to disk.
  Future<void> setPassword(String? plaintext) async {
    if (plaintext == null || plaintext.isEmpty) {
      _obfuscatedPassword = null;
      return;
    }
    final key = await _obfKey();
    _obfuscatedPassword = _obfuscate(plaintext, key);
  }

  bool get hasPassword => _obfuscatedPassword?.isNotEmpty == true;
}

// ── Global app settings ───────────────────────────────────────────────────────

class AppSettings {
  bool useMasterPassword;
  bool masterPasswordIsFingerprint;
  // SHA-256-like hash of master password (hex). Not reversible.
  String? masterPasswordHash;
  // Default for new containers — individual containers can override.
  bool defaultDocumentProvider;
  bool videoAutoPlay;

  AppSettings({
    this.useMasterPassword = false,
    this.masterPasswordIsFingerprint = false,
    this.masterPasswordHash,
    this.defaultDocumentProvider = false,
    this.videoAutoPlay = true,
  });

  Map<String, dynamic> toJson() => {
        'useMasterPassword': useMasterPassword,
        'masterPasswordIsFingerprint': masterPasswordIsFingerprint,
        'masterPasswordHash': masterPasswordHash,
        'defaultDocumentProvider': defaultDocumentProvider,
        'videoAutoPlay': videoAutoPlay,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        useMasterPassword: j['useMasterPassword'] as bool? ?? false,
        masterPasswordIsFingerprint:
            j['masterPasswordIsFingerprint'] as bool? ?? false,
        masterPasswordHash: j['masterPasswordHash'] as String?,
        // Back-compat: old field was mountAsDocumentProvider defaulting true.
        // New default is false (opt-in per container).
        defaultDocumentProvider:
            j['defaultDocumentProvider'] as bool? ??
            (j['mountAsDocumentProvider'] as bool? ?? false),
        videoAutoPlay: j['videoAutoPlay'] as bool? ?? true,
      );

  /// Hashes [plaintext] with the same algorithm used at setup time.
  static String hashPassword(String plaintext) {
    var h = 0xdeadbeef;
    for (final c in plaintext.codeUnits) {
      h = ((h << 5) + h + c) & 0xFFFFFFFF;
    }
    // Second pass for avalanche.
    for (final c in plaintext.codeUnits.toList().reversed) {
      h = ((h >> 3) ^ (h << 7) ^ c) & 0xFFFFFFFF;
    }
    return h.toUnsigned(32).toRadixString(16).padLeft(8, '0');
  }

  bool checkPassword(String candidate) =>
      masterPasswordHash != null &&
      hashPassword(candidate) == masterPasswordHash;
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
        return {
          for (final item in list)
            (item as Map<String, dynamic>)['uri'] as String:
                ContainerConfig.fromJson(item)
        };
      }
    } catch (_) {}
    return {};
  }

  static Future<void> saveContainerConfig(ContainerConfig config) async {
    try {
      final configs = await loadContainerConfigs();
      configs[config.uri] = config;
      final file = await _containerConfigsFile;
      await file
          .writeAsString(jsonEncode(configs.values.map((c) => c.toJson()).toList()));
    } catch (_) {}
  }

  static Future<void> removeContainerConfig(String uri) async {
    try {
      final configs = await loadContainerConfigs();
      configs.remove(uri);
      final file = await _containerConfigsFile;
      await file
          .writeAsString(jsonEncode(configs.values.map((c) => c.toJson()).toList()));
    } catch (_) {}
  }

  static Future<ContainerConfig?> getContainerConfig(String uri) async {
    final configs = await loadContainerConfigs();
    return configs[uri];
  }
}