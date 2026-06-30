import 'package:flutter/material.dart';
import '../../../utils/file_type_utils.dart';
import 'tile_selection_style.dart';

class FileTile extends StatelessWidget {
  final String name;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  final bool selectionMode;
  final bool selected;

  const FileTile({
    super.key,
    required this.name,
    this.subtitle,
    required this.onTap,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Semantics(
      label: 'File: $name${subtitle != null ? ", $subtitle" : ""}',
      button: true,
      selected: selected,
      child: ListTile(
        dense: true,
        selected: selected,
        selectedTileColor: TileSelectionStyle.selectedBackground(cs),
        contentPadding: TileSelectionStyle.contentPadding,
        leading: Icon(
          iconForFile(name),
          size: 22,
          color: TileSelectionStyle.leadingIconColor(
            cs,
            selected: selected,
            unselectedColor: colorForFile(name),
          ),
          semanticLabel: null, // covered by parent Semantics
        ),
        title: Text(
          name,
          style: textTheme.bodyMedium?.copyWith(
            fontWeight: TileSelectionStyle.titleWeight(selected),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: subtitle != null
            ? Text(
                subtitle!,
                style: textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              )
            : null,
        // Files have no chevron when not in selection mode — they open
        // directly rather than navigating into a sub-view.
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}
