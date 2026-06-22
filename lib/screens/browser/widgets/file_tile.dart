import 'package:flutter/material.dart';
import '../../../utils/file_type_utils.dart';

class FileTile extends StatelessWidget {
  final String name;

  /// Optional second-line label (e.g. formatted file size).
  final String? subtitle;

  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// When true the tile renders in multi-select mode (checkbox trailing icon,
  /// selection-highlight background).
  final bool selectionMode;
  final bool selected;

  const FileTile({
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

    return Container(
      color: selected
          ? cs.primaryContainer.withOpacity(0.35)
          : Colors.transparent,
      child: ListTile(
        dense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        leading: Icon(iconForFile(name), size: 20, color: colorForFile(name)),
        title: Text(name, style: Theme.of(context).textTheme.bodyMedium),
        subtitle: subtitle != null
            ? Text(subtitle!,
                style:
                    const TextStyle(fontSize: 11, color: Colors.grey))
            : null,
        trailing: selectionMode
            ? Icon(
                selected
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                size: 18,
                color: selected ? cs.primary : cs.outline,
              )
            : Icon(Icons.more_horiz, size: 16, color: cs.outline),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}