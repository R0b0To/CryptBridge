import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Unified repository for per-container state.
///
/// Replaces the split between [SavedContainerService] (saved_containers.json)
/// and [AppSettingsService] container config handling (container_configs.json).
///
/// Lifecycle: [add] → [update] → [remove] atomically handles all three
/// backing stores: the JSON index, the config JSON, and Android Keystore.
///

class ContainerRepository {
  ContainerRepository._();
  static final ContainerRepository instance = ContainerRepository._();

  // ── Backing stores ────────────────────────────────────────────────────────

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // In-memory cache — loaded once on first access, written-through on every mutation.
  Map<String, ContainerRecord>? _cache;

  static Future<File> get _dataFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/containers_v2.json');
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// Loads all containers. Subsequent calls return the in-memory cache.
  Future<Map<String, ContainerRecord>> loadAll() async {
    if (_cache != null) return Map.unmodifiable(_cache!);
    await _hydrate();
    return Map.unmodifiable(_cache!);
  }

  /// Inserts or fully replaces a container record.
  Future<void> save(ContainerRecord record) async {
    await _ensureLoaded();
    _cache![record.uri] = record;
    if (record.rememberPassword && record.pendingPassword != null) {
      await _secure.write(
        key: _keystoreKey(record.uri),
        value: record.pendingPassword,
      );
    } else if (!record.rememberPassword) {
      await _secure.delete(key: _keystoreKey(record.uri));
    }
    await _persist();
  }

  /// Completely removes a container — JSON entry, config, and Keystore entry.
  Future<void> remove(String uri) async {
    await _ensureLoaded();
    _cache!.remove(uri);
    // Always attempt Keystore deletion — even if rememberPassword was false,
    // a stale entry might exist from a previous state.
    await _secure.delete(key: _keystoreKey(uri));
    await _persist();
  }

  /// Reads the stored password for [uri] from Android Keystore.
  Future<String?> getPassword(String uri) =>
      _secure.read(key: _keystoreKey(uri));

  /// Invalidates the in-memory cache, forcing a reload on next access.
  void invalidate() => _cache = null;

  // ── Migration ─────────────────────────────────────────────────────────────

  /// One-time migration from the legacy split-file format.
  /// Safe to call repeatedly — is a no-op if already migrated.
  Future<void> migrateFromLegacy({
    required List<Map<String, String>> savedList,
    required List<Map<String, dynamic>> configList,
  }) async {
    final targetFile = await _dataFile;
    if (await targetFile.exists()) return; // already migrated

    await _ensureLoaded();
    for (final saved in savedList) {
      final uri  = saved['uri']  ?? '';
      final name = saved['name'] ?? '';
      if (uri.isEmpty) continue;

      final cfgJson = configList.cast<Map<String, dynamic>?>().firstWhere(
            (j) => j?['uri'] == uri,
            orElse: () => null,
          );

      _cache![uri] = ContainerRecord(
        uri: uri,
        label: cfgJson?['label'] as String? ?? name,
        rememberPassword: cfgJson?['rememberPassword'] as bool? ?? false,
        autoCloseMins: cfgJson?['autoCloseMins'] as int? ?? 0,
        documentProvider: cfgJson?['documentProvider'] as bool? ??
            cfgJson?['mountAsDocumentProvider'] as bool? ?? false,
      );
    }
    await _persist();
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  static String _keystoreKey(String uri) {
    final encoded = base64Url.encode(utf8.encode(uri));
    final trimmed = encoded.length > 180 ? encoded.substring(0, 180) : encoded;
    return 'vc2_pw_$trimmed';
  }

  Future<void> _ensureLoaded() async {
    if (_cache == null) await _hydrate();
  }

  Future<void> _hydrate() async {
    _cache = {};
    try {
      final file = await _dataFile;
      if (!await file.exists()) return;
      final list = jsonDecode(await file.readAsString()) as List<dynamic>;
      for (final item in list) {
        final r = ContainerRecord.fromJson(item as Map<String, dynamic>);
        _cache![r.uri] = r;
      }
    } catch (_) {
      _cache = {};
    }
  }

  Future<void> _persist() async {
    try {
      final file = await _dataFile;
      final list = _cache!.values.map((r) => r.toJson()).toList();
      await file.writeAsString(jsonEncode(list));
    } catch (_) {}
  }
}

// ── ContainerRecord ───────────────────────────────────────────────────────────

/// Unified model for a saved container entry.
///
/// [pendingPassword] is transient — it is written to Keystore during [save]
/// and is never serialised to the JSON file.
class ContainerRecord {
  final String uri;
  final String label;
  final bool rememberPassword;
  final int autoCloseMins;
  final bool documentProvider;

  /// Only populated when the caller wants to update the stored password.
  /// Not persisted to JSON.
  final String? pendingPassword;

  const ContainerRecord({
    required this.uri,
    required this.label,
    this.rememberPassword = false,
    this.autoCloseMins = 0,
    this.documentProvider = false,
    this.pendingPassword,
  });

  ContainerRecord copyWith({
    String? label,
    bool? rememberPassword,
    int? autoCloseMins,
    bool? documentProvider,
    String? pendingPassword,
  }) {
    return ContainerRecord(
      uri: uri,
      label: label ?? this.label,
      rememberPassword: rememberPassword ?? this.rememberPassword,
      autoCloseMins: autoCloseMins ?? this.autoCloseMins,
      documentProvider: documentProvider ?? this.documentProvider,
      pendingPassword: pendingPassword,
    );
  }

  Map<String, dynamic> toJson() => {
        'uri': uri,
        'label': label,
        'rememberPassword': rememberPassword,
        'autoCloseMins': autoCloseMins,
        'documentProvider': documentProvider,
        // pendingPassword is intentionally NOT serialised.
      };

  factory ContainerRecord.fromJson(Map<String, dynamic> j) => ContainerRecord(
        uri: j['uri'] as String,
        label: j['label'] as String? ?? '',
        rememberPassword: j['rememberPassword'] as bool? ?? false,
        autoCloseMins: j['autoCloseMins'] as int? ?? 0,
        documentProvider: j['documentProvider'] as bool? ??
            j['mountAsDocumentProvider'] as bool? ?? false,
      );
}