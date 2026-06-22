import 'package:flutter/material.dart';

class DirectoryTile extends StatelessWidget {
  final String name;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// When true the tile renders in multi-select mode (checkbox trailing icon,
  /// selection-highlight background).
  final bool selectionMode;
  final bool selected;

  const DirectoryTile({
    Key? key,
    required this.name,
    required this.onTap,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      color: selected
          ? cs.primaryContainer.withOpacity(0.35)
          : Colors.transparent,
      child: ListTile(
        dense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        leading: const Icon(
          Icons.folder_outlined,
          size: 20,
          color: Color(0xFFFFA726),
        ),
        title: Text(name, style: Theme.of(context).textTheme.bodyMedium),
        trailing: selectionMode
            ? Icon(
                selected
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                size: 18,
                color: selected ? cs.primary : cs.outline,
              )
            : Icon(Icons.chevron_right, size: 16, color: cs.outline),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}