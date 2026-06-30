import 'package:flutter/material.dart';
import 'tile_selection_style.dart';

class DirectoryTile extends StatelessWidget {
  final String name;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// When true the tile renders in multi-select mode (checkbox trailing icon,
  /// selection-highlight background).
  final bool selectionMode;
  final bool selected;

  const DirectoryTile({
    Key? key,
    required this.name,
    this.subtitle,
    required this.onTap,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: TileSelectionStyle.selectedBackground(cs),
      contentPadding: TileSelectionStyle.contentPadding,
      leading: Icon(
        Icons.folder_rounded,
        size: 22,
        color: TileSelectionStyle.leadingIconColor(
          cs,
          selected: selected,
          unselectedColor: cs.secondary,
        ),
      ),
      title: Text(
        name,
        style: textTheme.bodyMedium?.copyWith(
          fontWeight: TileSelectionStyle.titleWeight(selected),
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            )
          : null, // Renders the modified date below the folder title
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}