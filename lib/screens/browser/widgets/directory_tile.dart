import 'package:flutter/material.dart';

class DirectoryTile extends StatelessWidget {
  final String name;
  final String? subtitle; // Added subtitle property
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// When true the tile renders in multi-select mode (checkbox trailing icon,
  /// selection-highlight background).
  final bool selectionMode;
  final bool selected;

  const DirectoryTile({
    Key? key,
    required this.name,
    this.subtitle, // Added subtitle parameter
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
      selectedTileColor: cs.primaryContainer.withValues(alpha:0.3),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(
        Icons.folder_rounded,
        size: 22,
        color: selected ? cs.primary : cs.secondary,
      ),
      title: Text(
        name, 
        style: textTheme.bodyMedium?.copyWith(
          fontWeight: selected ? FontWeight.w500 : FontWeight.normal,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            )
          : null, // Renders the modified date below the folder title
      trailing: selectionMode
          ? Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 20,
              color: selected ? cs.primary : cs.outline,
            )
          : Icon(
              Icons.chevron_right_rounded, 
              size: 20, 
              color: cs.onSurfaceVariant.withValues(alpha:0.7),
            ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}