import 'package:flutter/material.dart';
import '../../../utils/file_type_utils.dart';
import '../../../utils/format_utils.dart';
import '../../../utils/raw_entry.dart';

/// Stateless renderer for a flat columned list of directory entries.
class FileListView extends StatelessWidget {
  final List<String> dirs;
  final List<String> files;
  final bool isSelectionMode;
  final Set<String> selectedItems;

  final ValueChanged<String> onDirTap;
  final ValueChanged<String> onFileTap;
  final ValueChanged<String> onItemLongPress;

  /// Called when the trailing "⋯" icon on a file tile is tapped.
  /// (Retained for call-site compatibility; no longer rendered on FileTile)
  final ValueChanged<String>? onFileLongMenu;

  const FileListView({
    super.key,
    required this.dirs,
    required this.files,
    required this.isSelectionMode,
    required this.selectedItems,
    required this.onDirTap,
    required this.onFileTap,
    required this.onItemLongPress,
    this.onFileLongMenu,
  });

  // Standard 3-letter month abbreviations to ensure unambiguous identification
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  /// Formats the date column dynamically:
  ///   - Current Day: Shows "HH:MM" (e.g., 18:29).
  ///   - Current Year: Shows "Month Day" (e.g., Jun 28).
  ///   - Different Year: Shows "Month Day, Year" (e.g., Jun 28, 2025).
  String _formatDateColumn(int secs) {
    if (secs <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(secs * 1000);
    final now = DateTime.now();

    final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;

    if (isToday) {
      final hr = dt.hour.toString().padLeft(2, '0');
      final min = dt.minute.toString().padLeft(2, '0');
      return '$hr:$min';
    }

    final monthAbbr = _months[dt.month - 1];
    final isCurrentYear = dt.year == now.year;

    if (isCurrentYear) {
      return '$monthAbbr ${dt.day}';
    } else {
      return '$monthAbbr ${dt.day}, ${dt.year}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = dirs.length + files.length;
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      children: [
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: total,
            itemBuilder: (_, index) {
              final isDir = index < dirs.length;
              final rawItem = isDir ? dirs[index] : files[index - dirs.length];
              final isSelected = selectedItems.contains(rawItem);

              final entry = RawEntry.parse(rawItem);
              final dateStr = _formatDateColumn(entry.modifiedSecs);
              final sizeStr = isDir ? '—' : formatBytes(entry.sizeBytes);

              return InkWell(
                onTap: () => isDir ? onDirTap(rawItem) : onFileTap(rawItem),
                onLongPress: () => onItemLongPress(rawItem),
                child: Container(
                  color: isSelected
                      ? cs.primaryContainer.withValues(alpha: 0.3)
                      : Colors.transparent,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      // File Type / Folder Icon
                      Icon(
                        isDir ? Icons.folder_rounded : iconForFile(entry.name),
                        size: 22,
                        color: isSelected
                            ? cs.primary
                            : (isDir ? cs.secondary : colorForFile(entry.name)),
                      ),
                      const SizedBox(width: 16),

                      // Name Column
                      Expanded(
                        flex: 5,
                        child: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyMedium?.copyWith(
                            fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
                          ),
                        ),
                      ),

                      // Date Column
                      SizedBox(
                        width: 90,
                        child: Text(
                          dateStr,
                          textAlign: TextAlign.right,
                          style: textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),

                      // Size Column
                      SizedBox(
                        width: 80,
                        child: Text(
                          sizeStr,
                          textAlign: TextAlign.right,
                          style: textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),

                      // Action Icon or Checkbox
                      if (isSelectionMode) ...[
                        const SizedBox(width: 16),
                        Icon(
                          isSelected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 20,
                          color: isSelected ? cs.primary : cs.outline,
                        ),
                      ] else if (isDir) ...[
                        const SizedBox(width: 16),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 20,
                          color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}