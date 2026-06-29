import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Inline copies of the classes under test.
//
// Replace with direct imports once the project package is wired up:
//   import 'package:vaultexplorer/services/cross_container_clipboard.dart';
//   import 'package:vaultexplorer/screens/browser/file_browser_screen.dart'
//       show makeUniqueName;   // already tested in utils_test.dart
// ---------------------------------------------------------------------------

// ── CrossContainerClipboard ──────────────────────────────────────────────────

class CrossContainerClipboard {
  CrossContainerClipboard._();
  static final instance = CrossContainerClipboard._();

  int? sourceVolId;
  String? sourceDisplayName;
  bool isCutOperation = false;
  List<Map<String, dynamic>> items = [];

  bool get hasItems => items.isNotEmpty;

  bool isFromVolume(int volId) => sourceVolId == volId;

  void set({
    required int volId,
    required String displayName,
    required bool cut,
    required List<Map<String, dynamic>> clipItems,
  }) {
    sourceVolId       = volId;
    sourceDisplayName = displayName;
    isCutOperation    = cut;
    items             = List.from(clipItems);
  }

  void clear() {
    sourceVolId       = null;
    sourceDisplayName = null;
    isCutOperation    = false;
    items             = [];
  }

  String get summary {
    if (!hasItems) return '';
    final verb = isCutOperation ? 'Moving' : 'Copying';
    final from = sourceDisplayName ?? '?';
    return '$verb ${items.length} item(s) from "$from"';
  }
}

// ── makeUniqueName (from file_browser_screen.dart) ───────────────────────────

String makeUniqueName(String fileName, Set<String> existingNames) {
  if (!existingNames.contains(fileName.toLowerCase())) return fileName;
  final dotIdx = fileName.lastIndexOf('.');
  final name   = dotIdx != -1 ? fileName.substring(0, dotIdx) : fileName;
  final ext    = dotIdx != -1 ? fileName.substring(dotIdx) : '';
  for (int i = 1; i < 9999; i++) {
    final candidate = '$name ($i)$ext';
    if (!existingNames.contains(candidate.toLowerCase())) return candidate;
  }
  return '$fileName-${DateTime.now().millisecondsSinceEpoch}';
}

// ── _ConflictResolution (from file_browser_screen.dart) ──────────────────────

enum ConflictResolution { skip, overwrite, keepBoth }

// ---------------------------------------------------------------------------
// Pure helper that encodes the paste conflict logic tested below.
//
// The real implementation lives in _FileBrowserScreenState._paste(), which
// is tightly coupled to async widget state and cannot be unit-tested directly.
// This pure function extracts the decision-making kernel so it *can* be tested.
//
// Once the codebase is structured as a library, this should be the actual
// implementation; the widget calls it rather than inlining the logic.
// ---------------------------------------------------------------------------

/// Returns the final destination path for a paste operation given:
///   [srcPath]         — the source FAT path
///   [destDir]         — the current destination directory path (may be empty)
///   [existingNames]   — lower-cased names already present in [destDir]
///   [resolution]      — how to handle a conflict if one is detected
///
/// Returns null when [resolution] is [ConflictResolution.skip] and a conflict
/// exists (caller should skip this item).
String? resolveDestPath({
  required String srcPath,
  required String destDir,
  required Set<String> existingNames,
  required ConflictResolution resolution,
}) {
  final fileName = srcPath.split('/').last;
  final baseDest = destDir.isEmpty ? fileName : '$destDir/$fileName';

  final hasConflict = existingNames.contains(fileName.toLowerCase());
  if (!hasConflict) return baseDest;

  switch (resolution) {
    case ConflictResolution.skip:
      return null;
    case ConflictResolution.overwrite:
      return baseDest;
    case ConflictResolution.keepBoth:
      final uniqueName = makeUniqueName(fileName, existingNames);
      return destDir.isEmpty ? uniqueName : '$destDir/$uniqueName';
  }
}

/// Returns true when a same-container move would make a path a descendant of
/// itself (e.g. moving /a/b into /a/b/sub).  Mirrors the guard in _paste().
bool isSelfDescendantMove({
  required String srcPath,
  required String destPath,
  required bool isDir,
}) {
  if (srcPath == destPath) return true;
  if (isDir && destPath.startsWith('$srcPath/')) return true;
  return false;
}

// ===========================================================================
// Tests
// ===========================================================================

void main() {
  // Re-initialise the singleton before each test so state does not leak
  // between tests (the singleton pattern means the same instance is shared).
  setUp(() => CrossContainerClipboard.instance.clear());

  // ── CrossContainerClipboard: basic state management ──────────────────────

  group('CrossContainerClipboard — basic state', () {
    test('starts empty', () {
      final clip = CrossContainerClipboard.instance;
      expect(clip.hasItems, isFalse);
      expect(clip.sourceVolId, isNull);
      expect(clip.isCutOperation, isFalse);
      expect(clip.items, isEmpty);
    });

    test('set() populates all fields', () {
      final clip = CrossContainerClipboard.instance;
      clip.set(
        volId: 2,
        displayName: 'Work Vault',
        cut: true,
        clipItems: [
          {'path': 'docs/report.pdf', 'isDir': false, 'size': 1024},
        ],
      );

      expect(clip.hasItems, isTrue);
      expect(clip.sourceVolId, 2);
      expect(clip.sourceDisplayName, 'Work Vault');
      expect(clip.isCutOperation, isTrue);
      expect(clip.items.length, 1);
      expect(clip.items.first['path'], 'docs/report.pdf');
    });

    test('clear() resets all fields', () {
      final clip = CrossContainerClipboard.instance;
      clip.set(
        volId: 1,
        displayName: 'Personal',
        cut: false,
        clipItems: [{'path': 'photo.jpg', 'isDir': false}],
      );

      clip.clear();

      expect(clip.hasItems, isFalse);
      expect(clip.sourceVolId, isNull);
      expect(clip.sourceDisplayName, isNull);
      expect(clip.isCutOperation, isFalse);
      expect(clip.items, isEmpty);
    });
  });

  // ── CrossContainerClipboard: isFromVolume ─────────────────────────────────

  group('CrossContainerClipboard — isFromVolume', () {
    test('returns true when volId matches source', () {
      CrossContainerClipboard.instance.set(
          volId: 3, displayName: 'X', cut: false, clipItems: []);
      expect(CrossContainerClipboard.instance.isFromVolume(3), isTrue);
    });

    test('returns false for a different volId', () {
      CrossContainerClipboard.instance.set(
          volId: 3, displayName: 'X', cut: false, clipItems: []);
      expect(CrossContainerClipboard.instance.isFromVolume(5), isFalse);
    });

    test('returns false after clear()', () {
      CrossContainerClipboard.instance.set(
          volId: 3, displayName: 'X', cut: false, clipItems: []);
      CrossContainerClipboard.instance.clear();
      // sourceVolId is null; isFromVolume(3) should not throw
      expect(CrossContainerClipboard.instance.isFromVolume(3), isFalse);
    });
  });

  // ── CrossContainerClipboard: summary ─────────────────────────────────────

  group('CrossContainerClipboard — summary', () {
    test('empty clipboard returns empty string', () {
      expect(CrossContainerClipboard.instance.summary, '');
    });

    test('copy summary uses "Copying"', () {
      CrossContainerClipboard.instance.set(
        volId: 1,
        displayName: 'My Vault',
        cut: false,
        clipItems: [
          {'path': 'a.txt', 'isDir': false},
          {'path': 'b.txt', 'isDir': false},
        ],
      );
      expect(CrossContainerClipboard.instance.summary,
          'Copying 2 item(s) from "My Vault"');
    });

    test('cut summary uses "Moving"', () {
      CrossContainerClipboard.instance.set(
        volId: 1,
        displayName: 'Archive',
        cut: true,
        clipItems: [{'path': 'folder', 'isDir': true}],
      );
      expect(CrossContainerClipboard.instance.summary,
          'Moving 1 item(s) from "Archive"');
    });

    test('summary uses "?" when displayName is null', () {
      // Force null display name by manipulating the internal state directly.
      final clip = CrossContainerClipboard.instance;
      clip.set(
          volId: 1,
          displayName: 'temp',
          cut: false,
          clipItems: [{'path': 'x', 'isDir': false}]);
      clip.sourceDisplayName = null; // simulate edge case
      expect(clip.summary, 'Copying 1 item(s) from "?"');
    });
  });

  // ── CrossContainerClipboard: items are deep-copied ────────────────────────

  group('CrossContainerClipboard — items isolation', () {
    test('mutating the original list after set() does not affect clipboard', () {
      final original = <Map<String, dynamic>>[
        {'path': 'file.txt', 'isDir': false}
      ];
      CrossContainerClipboard.instance.set(
          volId: 1, displayName: 'V', cut: false, clipItems: original);

      original.add({'path': 'other.txt', 'isDir': false});

      expect(CrossContainerClipboard.instance.items.length, 1);
    });
  });

  // ── resolveDestPath ───────────────────────────────────────────────────────

  group('resolveDestPath — no conflict', () {
    test('returns dest path when no conflict', () {
      expect(
        resolveDestPath(
          srcPath: 'photos/IMG_001.jpg',
          destDir: 'backup',
          existingNames: {'other.jpg'},
          resolution: ConflictResolution.skip,
        ),
        'backup/IMG_001.jpg',
      );
    });

    test('works with empty destDir (root paste)', () {
      expect(
        resolveDestPath(
          srcPath: 'report.pdf',
          destDir: '',
          existingNames: {},
          resolution: ConflictResolution.overwrite,
        ),
        'report.pdf',
      );
    });
  });

  group('resolveDestPath — skip resolution', () {
    test('returns null when conflict and skip', () {
      expect(
        resolveDestPath(
          srcPath: 'docs/report.pdf',
          destDir: 'archive',
          existingNames: {'report.pdf'},
          resolution: ConflictResolution.skip,
        ),
        isNull,
      );
    });

    test('returns path when no conflict even with skip resolution', () {
      expect(
        resolveDestPath(
          srcPath: 'docs/new.pdf',
          destDir: 'archive',
          existingNames: {'other.pdf'},
          resolution: ConflictResolution.skip,
        ),
        'archive/new.pdf',
      );
    });
  });

  group('resolveDestPath — overwrite resolution', () {
    test('returns the original dest path (overwrite in place)', () {
      expect(
        resolveDestPath(
          srcPath: 'data/file.txt',
          destDir: 'backup',
          existingNames: {'file.txt'},
          resolution: ConflictResolution.overwrite,
        ),
        'backup/file.txt',
      );
    });
  });

  group('resolveDestPath — keepBoth resolution', () {
    test('appends (1) on first conflict', () {
      expect(
        resolveDestPath(
          srcPath: 'docs/report.pdf',
          destDir: 'archive',
          existingNames: {'report.pdf'},
          resolution: ConflictResolution.keepBoth,
        ),
        'archive/report (1).pdf',
      );
    });

    test('increments until unique', () {
      expect(
        resolveDestPath(
          srcPath: 'docs/report.pdf',
          destDir: 'archive',
          existingNames: {'report.pdf', 'report (1).pdf', 'report (2).pdf'},
          resolution: ConflictResolution.keepBoth,
        ),
        'archive/report (3).pdf',
      );
    });

    test('works with empty destDir (root paste)', () {
      expect(
        resolveDestPath(
          srcPath: 'photo.jpg',
          destDir: '',
          existingNames: {'photo.jpg'},
          resolution: ConflictResolution.keepBoth,
        ),
        'photo (1).jpg',
      );
    });

    test('conflict detection is case-insensitive', () {
      expect(
        resolveDestPath(
          srcPath: 'Report.PDF',
          destDir: 'out',
          existingNames: {'report.pdf'},
          resolution: ConflictResolution.keepBoth,
        ),
        'out/Report (1).PDF',
      );
    });
  });

  // ── isSelfDescendantMove ──────────────────────────────────────────────────

  group('isSelfDescendantMove', () {
    test('same path is a self-move', () {
      expect(
        isSelfDescendantMove(
            srcPath: 'docs', destPath: 'docs', isDir: true),
        isTrue,
      );
    });

    test('moving directory into itself is a descendant move', () {
      expect(
        isSelfDescendantMove(
            srcPath: 'docs', destPath: 'docs/sub', isDir: true),
        isTrue,
      );
    });

    test('moving file into a subdirectory of itself is not blocked', () {
      // Files can't contain directories, so this is a valid move.
      expect(
        isSelfDescendantMove(
            srcPath: 'docs/file.txt',
            destPath: 'docs/file.txt/sub', // nonsensical but tested for safety
            isDir: false),
        isFalse,
      );
    });

    test('moving to a sibling directory is valid', () {
      expect(
        isSelfDescendantMove(
            srcPath: 'docs', destPath: 'archive/docs', isDir: true),
        isFalse,
      );
    });

    test('path prefix match requires slash separator', () {
      // "docs2" should NOT be considered a descendant of "docs"
      expect(
        isSelfDescendantMove(
            srcPath: 'docs', destPath: 'docs2', isDir: true),
        isFalse,
      );
    });

    test('file moving to different path is valid', () {
      expect(
        isSelfDescendantMove(
            srcPath: 'images/photo.jpg',
            destPath: 'backup/photo.jpg',
            isDir: false),
        isFalse,
      );
    });
  });
}