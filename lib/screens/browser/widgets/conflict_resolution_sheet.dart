import 'package:flutter/material.dart';
import '../../../models/clipboard_item.dart';
import '../../../models/file_operation.dart';

/// A name collision discovered during the pre-paste scan.
@immutable
class ConflictEntry {
  final ClipboardItem item;
  final bool destIsDir;

  const ConflictEntry({required this.item, required this.destIsDir});
}

/// Single bottom sheet that resolves every name conflict for a paste in one
/// pass, instead of one [AlertDialog] per colliding file.
///
/// ### Why this replaces the old per-file dialog loop
/// The previous implementation in `FileBrowserScreen._paste()` awaited a
/// dialog for every conflict serially, blocking the paste before
/// [FileOperationService.enqueue] was ever called. For a folder with a dozen
/// collisions that meant a dozen sequential modal interruptions.
///
/// This sheet shows the whole list at once. The user can:
///   - Set a resolution per item (skip / overwrite / keep both), or
///   - Tap one of the three "Apply to all" chips to resolve everything at once.
///
/// Returns a [ConflictPlan] (lowercased-name → [ConflictResolution]) ready to
/// pass straight into [FileOperationService.enqueue], or `null` if the user
/// cancelled the whole paste.
class ConflictResolutionSheet extends StatefulWidget {
  final List<ConflictEntry> conflicts;

  const ConflictResolutionSheet({super.key, required this.conflicts});

  /// Shows the sheet and returns the resolved [ConflictPlan], or `null` if
  /// the user dismissed it / tapped Cancel.
  static Future<ConflictPlan?> show(
    BuildContext context, {
    required List<ConflictEntry> conflicts,
  }) {
    return showModalBottomSheet<ConflictPlan>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => ConflictResolutionSheet(conflicts: conflicts),
    );
  }

  @override
  State<ConflictResolutionSheet> createState() =>
      _ConflictResolutionSheetState();
}

class _ConflictResolutionSheetState extends State<ConflictResolutionSheet> {
  late final Map<String, ConflictResolution> _resolutions;

  @override
  void initState() {
    super.initState();
    // Default every item to "keep both" — the safest non-destructive choice.
    _resolutions = {
      for (final c in widget.conflicts)
        c.item.name.toLowerCase(): ConflictResolution.keepBoth,
    };
  }

  void _applyToAll(ConflictResolution resolution) {
    setState(() {
      for (final key in _resolutions.keys) {
        _resolutions[key] = resolution;
      }
    });
  }

  void _setOne(String key, ConflictResolution resolution) {
    setState(() => _resolutions[key] = resolution);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final count = widget.conflicts.length;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: count > 4 ? 0.65 : 0.45,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Column(
          children: [
            Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // ── Header ───────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 20, color: cs.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '$count item${count == 1 ? '' : 's'} already exist',
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'Choose what happens to each item, or apply one choice to all.',
                style: textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),

            // ── Apply-to-all row ─────────────────────────────────────────────
            if (count > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _ApplyAllChip(
                        label: 'Skip all',
                        icon: Icons.block_rounded,
                        onTap: () => _applyToAll(ConflictResolution.skip),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ApplyAllChip(
                        label: 'Overwrite all',
                        icon: Icons.find_replace_rounded,
                        isDestructive: true,
                        onTap: () => _applyToAll(ConflictResolution.overwrite),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ApplyAllChip(
                        label: 'Keep both',
                        icon: Icons.content_copy_rounded,
                        onTap: () => _applyToAll(ConflictResolution.keepBoth),
                      ),
                    ),
                  ],
                ),
              ),

            const Divider(height: 1),

            // ── Per-item list ────────────────────────────────────────────────
            Expanded(
              child: ListView.separated(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: widget.conflicts.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, indent: 56),
                itemBuilder: (_, i) {
                  final conflict = widget.conflicts[i];
                  final key = conflict.item.name.toLowerCase();
                  return _ConflictRow(
                    conflict: conflict,
                    resolution: _resolutions[key]!,
                    onChanged: (r) => _setOne(key, r),
                  );
                },
              ),
            ),

            const Divider(height: 1),

            // ── Actions ──────────────────────────────────────────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                12 + MediaQuery.of(context).padding.bottom,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, null),
                      child: const Text('Cancel paste'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, Map.of(_resolutions)),
                      child: const Text('Continue'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── Apply-to-all chip ──────────────────────────────────────────────────────────

class _ApplyAllChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isDestructive;
  final VoidCallback onTap;

  const _ApplyAllChip({
    required this.label,
    required this.icon,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = isDestructive ? cs.error : cs.onSurfaceVariant;

    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Per-item conflict row ──────────────────────────────────────────────────────

class _ConflictRow extends StatelessWidget {
  final ConflictEntry conflict;
  final ConflictResolution resolution;
  final ValueChanged<ConflictResolution> onChanged;

  const _ConflictRow({
    required this.conflict,
    required this.resolution,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final item = conflict.item;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            item.isDir
                ? Icons.folder_rounded
                : Icons.insert_drive_file_outlined,
            size: 20,
            color: item.isDir ? cs.secondary : cs.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              item.name,
              style: textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          DropdownButtonHideUnderline(
            child: DropdownButton<ConflictResolution>(
              value: resolution,
              isDense: true,
              borderRadius: BorderRadius.circular(8),
              style: textTheme.bodySmall?.copyWith(color: cs.onSurface),
              items: [
                DropdownMenuItem(
                  value: ConflictResolution.skip,
                  child: const Text('Skip'),
                ),
                DropdownMenuItem(
                  value: ConflictResolution.overwrite,
                  child: Text(
                    conflict.destIsDir ? 'Overwrite folder' : 'Overwrite',
                    style: TextStyle(color: cs.error),
                  ),
                ),
                DropdownMenuItem(
                  value: ConflictResolution.keepBoth,
                  child: const Text('Keep both'),
                ),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}
