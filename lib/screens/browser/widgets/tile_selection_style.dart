import 'package:flutter/material.dart';

/// Single source of truth for the selection-mode visual language shared by
/// every row-style list tile in the file browser ([FileTile], [DirectoryTile]).
///
/// ### Why this exists
/// [FileTile] and [DirectoryTile] previously each hard-coded the same five
/// decisions independently:
///   - selected background tint (`cs.primaryContainer.withValues(alpha:0.3)`)
///   - trailing check / unchecked-circle icon + size + color
///   - selected title font weight
///   - content padding
///   - `dense: true`
///
/// A change to any of these (e.g. swapping the check icon, adjusting the
/// tint alpha) required editing both files identically, with no compiler
/// error if one was missed. This class centralises those decisions.
///
/// [FileGridView]'s `_GridCell` intentionally does NOT use this — the grid
/// uses a different visual language (full-cell tint + corner badge,
/// appropriate for a card-style cell rather than a row), so sharing here
/// would be a false abstraction across two genuinely different layouts.
abstract final class TileSelectionStyle {
  /// Background tint applied to a selected [ListTile] via `selectedTileColor`.
  static Color selectedBackground(ColorScheme cs) =>
      cs.primaryContainer.withValues(alpha: 0.3);

  /// Standard content padding shared by both row tiles.
  static const contentPadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 4,
  );

  /// Title [FontWeight] — slightly bolder when selected so the row reads as
  /// "active" without changing size or color.
  static FontWeight titleWeight(bool selected) =>
      selected ? FontWeight.w500 : FontWeight.normal;

  /// Leading icon color: primary when selected, otherwise [unselectedColor]
  /// (the tile's own type-specific color — e.g. a folder's secondary tint or
  /// a file's extension-based color).
  static Color leadingIconColor(
    ColorScheme cs, {
    required bool selected,
    required Color unselectedColor,
  }) => selected ? cs.primary : unselectedColor;
}

/// The trailing checkbox-style indicator shown on a row tile while
/// [selectionMode] is active.
///
/// Renders a filled check circle when [selected], an empty outline circle
/// otherwise. Both [FileTile] and [DirectoryTile] render this identically;
/// extracting it means the indicator can only ever look one way across the
/// whole list view.
class TileSelectionIndicator extends StatelessWidget {
  final bool selected;

  const TileSelectionIndicator({super.key, required this.selected});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Icon(
      selected
          ? Icons.check_circle_rounded
          : Icons.radio_button_unchecked_rounded,
      size: 20,
      color: selected ? cs.primary : cs.outline,
    );
  }
}
