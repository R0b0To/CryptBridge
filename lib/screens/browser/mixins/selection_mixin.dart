import 'package:flutter/material.dart';
import '../../../models/mounted_container.dart';
import '../../../services/vaultexplorer_api.dart';
import '../../../utils/format_utils.dart';
import '../../../utils/raw_entry.dart';

/// Manages item-selection mode.  Mix into any [State] that needs a multi-select
/// UI — the mixin owns [isSelectionMode] and [selectedItems] so the host class
/// doesn't have to declare them.
///
/// New in this revision:
///  • Per-type counts ([selectedFileCount], [selectedFolderCount]).
///  • Total file-byte sum ([selectedFileBytes]) derived from the wire format.
///  • Lazy async folder-size resolution via [fetchFolderSizes]; resolved sizes
///    accumulate in [_resolvedFolderSizes] so a second tap is instant.
///  • [selectionSummary] — a ready-to-display label for the app-bar/bottom-bar.
mixin SelectionMixin<T extends StatefulWidget> on State<T> {
  bool isSelectionMode = false;

  /// Raw wire strings exactly as returned by [listDirectoryNative].
  /// Format: "name|size|ts"  /  "[DIR] name|0|ts"
  final Set<String> selectedItems = {};

  // ── Folder-size resolution ─────────────────────────────────────────────────

  /// Cache of { dirName → recursive byte total }.
  /// Populated lazily by [fetchFolderSizes]; cleared on [exitSelectionMode].
  final Map<String, int> _resolvedFolderSizes = {};

  /// Prevents concurrent [fetchFolderSizes] calls from overlapping.
  bool _fetchingFolderSizes = false;

  // ── Selection mutations ────────────────────────────────────────────────────

  void toggleSelectItem(String item) {
    setState(() {
      if (selectedItems.contains(item)) {
        selectedItems.remove(item);
        if (selectedItems.isEmpty) isSelectionMode = false;
      } else {
        selectedItems.add(item);
      }
    });
  }

  void exitSelectionMode() {
    setState(() {
      isSelectionMode = false;
      selectedItems.clear();
      _resolvedFolderSizes.clear();
    });
  }

  // ── Counts ─────────────────────────────────────────────────────────────────

  /// Number of selected non-directory items.
  int get selectedFileCount =>
      selectedItems.where((r) => !r.startsWith('[DIR] ')).length;

  /// Number of selected directory items.
  int get selectedFolderCount =>
      selectedItems.where((r) => r.startsWith('[DIR] ')).length;

  // ── Size helpers ───────────────────────────────────────────────────────────

  /// Byte sum of all selected *files*.
  /// Directories are always 0 here; use [selectedTotalBytes] once folder
  /// sizes have been resolved by [fetchFolderSizes].
  int get selectedFileBytes {
    int sum = 0;
    for (final raw in selectedItems) {
      final e = RawEntry.parse(raw);
      if (!e.isDir) sum += e.sizeBytes;
    }
    return sum;
  }

  /// Byte sum of selected files PLUS any folder sizes already resolved.
  /// Folders that are still pending contribute 0.
  int get selectedTotalBytes {
    int sum = selectedFileBytes;
    for (final raw in selectedItems) {
      final e = RawEntry.parse(raw);
      if (e.isDir) sum += _resolvedFolderSizes[e.name] ?? 0;
    }
    return sum;
  }

  /// True while at least one selected folder has not yet been sized.
  bool get hasPendingFolderSizes {
    for (final raw in selectedItems) {
      final e = RawEntry.parse(raw);
      if (e.isDir && !_resolvedFolderSizes.containsKey(e.name)) return true;
    }
    return false;
  }

  // ── Display label ──────────────────────────────────────────────────────────

  /// Ready-to-display summary for the selection action-bar.
  ///
  /// Examples:
  ///   "3 files · 42.3 MB"
  ///   "1 file · 800 KB + 2 folders · 1.2 GB"
  ///   "2 folders (calculating…)"
  ///   "1 file · 200 KB + 1 folder (calculating…)"
  String get selectionSummary {
    final fc       = selectedFolderCount;
    final fileSize = selectedFileBytes;
    final total    = selectedTotalBytes;

    // ── file part ─────────────────────────────────────────────────────────
    final fileCount = selectedFileCount;
    final filePart  = fileCount > 0
        ? '$fileCount ${fileCount == 1 ? 'file' : 'files'}'
          '${fileSize > 0 ? ' · ${formatBytes(fileSize)}' : ''}'
        : '';

    if (fc == 0) return filePart;

    // ── folder part ───────────────────────────────────────────────────────
    final folderLabel = '$fc ${fc == 1 ? 'folder' : 'folders'}';

    final String folderSizePart;
    if (hasPendingFolderSizes) {
      folderSizePart = '(calculating…)';
    } else {
      final resolvedBytes = total - fileSize;
      folderSizePart = resolvedBytes > 0 ? '· ${formatBytes(resolvedBytes)}' : '';
    }

    final folderPart = '$folderLabel $folderSizePart'.trim();

    if (filePart.isEmpty) return folderPart;
    return '$filePart + $folderPart';
  }

  // ── Async folder-size resolution ───────────────────────────────────────────

  /// Fetches the recursive byte total for every selected directory whose size
  /// has not yet been resolved.
  ///
  /// Call this from the host screen whenever [selectedItems] changes and
  /// [selectedFolderCount] > 0:
  ///
  /// ```dart
  /// void toggleSelectItem(String item) {
  ///   super.toggleSelectItem(item);
  ///   if (selectedFolderCount > 0) {
  ///     fetchFolderSizes(widget.container, currentDirPath);
  ///   }
  /// }
  /// ```
  ///
  /// Each resolved size triggers a [setState] so the label updates
  /// progressively as sizes arrive, rather than waiting for all of them.
  ///
  /// The method is re-entrant-safe: concurrent calls are serialised via the
  /// [_fetchingFolderSizes] guard; newly selected folders discovered after the
  /// guard is set are picked up on the next call.
  Future<void> fetchFolderSizes(
    MountedContainer container,
    String currentDirPath,
  ) async {
    if (_fetchingFolderSizes) return;
    _fetchingFolderSizes = true;

    try {
      // Collect all directories that still need sizing.
      final pending = selectedItems
          .where((r) => r.startsWith('[DIR] '))
          .map(RawEntry.parse)
          .where((e) => !_resolvedFolderSizes.containsKey(e.name))
          .toList(growable: false);

      for (final e in pending) {
        if (!mounted) return;

        final fatPath = currentDirPath.isEmpty
            ? e.name
            : '$currentDirPath/${e.name}';

        final size =
            await vaultExplorerApi.getFolderSize(container, fatPath);

        if (!mounted) return;

        setState(() => _resolvedFolderSizes[e.name] = size);
      }
    } finally {
      _fetchingFolderSizes = false;
    }
  }
}