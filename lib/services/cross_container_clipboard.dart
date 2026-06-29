import 'package:flutter/foundation.dart';
import '../models/clipboard_item.dart';

/// Singleton that holds clipboard items which survive navigation between
/// containers and back to the dashboard.
///
/// Extends [ChangeNotifier] so any widget can rebuild automatically when the
/// clipboard changes (set, clear, or item list mutation).
///
/// ### What changed from the old version
/// - `items` is now `List<ClipboardItem>` instead of `List<Map<String,dynamic>>`.
///   Every callsite that built `{'path': …, 'isDir': …, 'size': …}` maps now
///   constructs a `ClipboardItem(path: …, isDir: …, sizeBytes: …)` instead.
/// - `sourceVolId` and `sourceDisplayName` are unchanged — we deliberately
///   store only identity scalars, not a full `MountedContainer`, to avoid
///   keeping the container alive in memory after it is locked.
class CrossContainerClipboard extends ChangeNotifier {
  CrossContainerClipboard._();
  static final instance = CrossContainerClipboard._();

  // ── State ─────────────────────────────────────────────────────────────────

  int? sourceVolId;
  String? sourceDisplayName;
  bool isCutOperation = false;

  /// Typed item list. Previously `List<Map<String, dynamic>>`.
  List<ClipboardItem> items = const [];

  // ── Queries ───────────────────────────────────────────────────────────────

  bool get hasItems => items.isNotEmpty;

  /// True when the clipboard was populated from [volId].
  bool isFromVolume(int volId) => sourceVolId == volId;

  // ── Mutations ─────────────────────────────────────────────────────────────

  /// Populates the clipboard and notifies all listeners.
  void set({
    required int volId,
    required String displayName,
    required bool cut,
    required List<ClipboardItem> clipItems,
  }) {
    sourceVolId       = volId;
    sourceDisplayName = displayName;
    isCutOperation    = cut;
    items             = List.unmodifiable(clipItems);
    notifyListeners();
  }

  /// Clears the clipboard and notifies all listeners.
  void clear() {
    sourceVolId       = null;
    sourceDisplayName = null;
    isCutOperation    = false;
    items             = const [];
    notifyListeners();
  }

  // ── Display ───────────────────────────────────────────────────────────────

  /// Short human-readable summary for status strips and banners.
  String get summary {
    if (!hasItems) return '';
    final verb = isCutOperation ? 'Moving' : 'Copying';
    final from = sourceDisplayName ?? '?';
    return '$verb ${items.length} item(s) from "$from"';
  }
}