import 'package:flutter/material.dart';
import '../../../utils/file_type_utils.dart';

class FileTile extends StatelessWidget {
  final String name;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Callback for the trailing "⋯" icon. Connects the tile to [FileActionsSheet].
  final VoidCallback? onMoreTap;

  final bool selectionMode;
  final bool selected;

  const FileTile({
    super.key,
    required this.name,
    this.subtitle,
    required this.onTap,
    this.onLongPress,
    this.onMoreTap,
    this.selectionMode = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Semantics(
      label: 'File: $name${subtitle != null ? ", $subtitle" : ""}',
      button: true,
      child: Material(
        color: selected
            ? cs.primaryContainer.withOpacity(0.35)
            : Colors.transparent,
        child: ListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          leading: Icon(
            iconForFile(name),
            size: 20,
            color: colorForFile(name),
            semanticLabel: null, // covered by parent Semantics
          ),
          title: Text(
            name,
            style: Theme.of(context).textTheme.bodyMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: subtitle != null
              ? Text(
                  subtitle!,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                )
              : null,
          
          onTap: onTap,
          onLongPress: onLongPress,
        ),
      ),
    );
  }
}