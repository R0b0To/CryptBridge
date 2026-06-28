import 'package:flutter/material.dart';

/// App bar shown while the user has one or more items selected.
class SelectionAppBar extends StatelessWidget implements PreferredSizeWidget {
  final int selectedCount;
  final String selectionLabel; // Custom size/calculating label
  final bool singleSelected;
  final bool singleFileSelected;

  final VoidCallback onClose;
  final VoidCallback onSelectAll;
  final VoidCallback onRename;
  final VoidCallback onCopy;
  final VoidCallback onCut;
  final VoidCallback onExport;
  final VoidCallback onDelete;
  final VoidCallback onOpenWithApp;

  const SelectionAppBar({
    Key? key,
    required this.selectedCount,
    required this.selectionLabel,
    required this.singleSelected,
    required this.singleFileSelected,
    required this.onClose,
    required this.onSelectAll,
    required this.onRename,
    required this.onCopy,
    required this.onCut,
    required this.onExport,
    required this.onDelete,
    required this.onOpenWithApp,
  }) : super(key: key);

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return AppBar(
      backgroundColor: cs.surfaceContainer, // Matches contextual CAB styling
      foregroundColor: cs.onSurface,
      elevation: 0,
      shape: Border(
        bottom: BorderSide(color: cs.outlineVariant),
      ),
      leading: IconButton(
        icon: const Icon(Icons.close_rounded),
        tooltip: 'Clear selection',
        onPressed: onClose,
      ),
      titleSpacing: 0,
      title: PopupMenuButton<String>(
        tooltip: 'Selection options',
        offset: const Offset(0, 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(100), // Perfect pill shape
                ),
                child: Text(
                  '$selectedCount',
                  style: textTheme.labelLarge?.copyWith(
                    color: cs.onPrimaryContainer, // Clean high-contrast text on deep container blue
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  selectionLabel,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.arrow_drop_down_rounded, color: cs.onSurface, size: 22),
            ],
          ),
        ),
        onSelected: (value) {
          if (value == 'select_all') onSelectAll();
          if (value == 'clear') onClose();
        },
        itemBuilder: (context) => [
          const PopupMenuItem<String>(
            value: 'select_all',
            child: Text('Select All'),
          ),
          const PopupMenuItem<String>(
            value: 'clear',
            child: Text('Clear Selection'),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: Icon(Icons.delete_outline_rounded, color: cs.error),
          tooltip: 'Delete',
          onPressed: onDelete,
        ),
        IconButton(
          icon: const Icon(Icons.copy_rounded),
          tooltip: 'Copy',
          onPressed: onCopy,
        ),
        IconButton(
          icon: const Icon(Icons.cut_rounded),
          tooltip: 'Move',
          onPressed: onCut,
        ),
        if (singleSelected)
          IconButton(
            icon: const Icon(Icons.drive_file_rename_outline_rounded),
            tooltip: 'Rename',
            onPressed: onRename,
          ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded),
          tooltip: 'More options',
          onSelected: (value) {
            if (value == 'export') onExport();
            if (value == 'open_with_app') onOpenWithApp();
          },
          itemBuilder: (context) => [
            PopupMenuItem<String>(
              value: 'export',
              child: Row(
                children: [
                  Icon(Icons.drive_folder_upload_rounded,
                      color: cs.onSurfaceVariant, size: 18),
                  const SizedBox(width: 12),
                  const Text('Export to device'),
                ],
              ),
            ),
            if (singleFileSelected)
              PopupMenuItem<String>(
                value: 'open_with_app',
                child: Row(
                  children: [
                    Icon(Icons.open_in_new_rounded,
                        color: cs.onSurfaceVariant, size: 18),
                    const SizedBox(width: 12),
                    const Text('Open with App'),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}