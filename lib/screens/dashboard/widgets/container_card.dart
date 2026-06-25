import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../models/mounted_container.dart';
import '../../../services/vaultexplorer_api.dart';
import '../../../utils/format_utils.dart';
import '../../browser/file_browser_screen.dart';

class ContainerCard extends StatelessWidget {
  final MountedContainer container;
  final ValueChanged<int> onLocked;
  final VoidCallback onReturn;

  /// Called when the card is long-pressed → opens configuration sheet.
  final VoidCallback? onLongPress;

  const ContainerCard({
    super.key,
    required this.container,
    required this.onLocked,
    required this.onReturn,
    this.onLongPress,
  });

  Color _storageColor(double usedFraction, ColorScheme cs) {
    if (usedFraction > 0.90) return cs.error;
    if (usedFraction > 0.70) return cs.secondary;
    return cs.primary;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fileCount =
        container.rootFiles.where((f) => !f.startsWith('[DIR]')).length;
    final dirCount =
        container.rootFiles.where((f) => f.startsWith('[DIR]')).length;

    final usedBytes = container.totalSpace - container.freeSpace;
    final usedFraction = container.totalSpace > 0
        ? (usedBytes / container.totalSpace).clamp(0.0, 1.0)
        : 0.0;
    final barColor = _storageColor(usedFraction, cs);
    final hasSpaceData = container.totalSpace > 0;

    return Semantics(
      label: 'Container ${container.displayName}, '
          '${hasSpaceData ? "${formatBytes(container.freeSpace)} free" : "locked"}',
      button: true,
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      FileBrowserScreen(container: container)),
            );
            onReturn();
          },
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header ──────────────────────────────────────────────
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.folder_zip_outlined,
                          size: 20, color: cs.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            container.displayName,
                            style: Theme.of(context).textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            hasSpaceData
                                ? '${formatBytes(container.freeSpace)} free'
                                    ' of ${formatBytes(container.totalSpace)}'
                                : 'Vol ${container.volId} • mounted',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    _LockButton(
                        container: container, onLocked: onLocked),
                  ],
                ),

                // ── Storage bar ─────────────────────────────────────────
                if (hasSpaceData) ...[
                  const SizedBox(height: 10),
                  Semantics(
                    label: '${(usedFraction * 100).round()}% used',
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: usedFraction,
                        minHeight: 4,
                        backgroundColor: cs.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation<Color>(barColor),
                      ),
                    ),
                  ),
                ],


              ],
            ),
          ),
        ),
      ),
    );
  }
}


class _LockButton extends StatefulWidget {
  final MountedContainer container;
  final ValueChanged<int> onLocked;
  const _LockButton({required this.container, required this.onLocked});

  @override
  State<_LockButton> createState() => _LockButtonState();
}

class _LockButtonState extends State<_LockButton> {
  bool _loading = false;

  Future<void> _lock() async {
    HapticFeedback.mediumImpact();
    setState(() => _loading = true);
    try {
      await vaultExplorerApi.lockContainer(widget.container.uri);
      widget.onLocked(widget.container.volId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lock failed: ${e.runtimeType}')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Lock ${widget.container.displayName}',
      button: true,
      child: IconButton(
        onPressed: _loading ? null : _lock,
        tooltip: 'Lock container',
        icon: _loading
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: cs.error),
              )
            : Icon(Icons.lock_outline, size: 20, color: cs.error),
      ),
    );
  }
}

// ── Saved Container Card ──────────────────────────────────────────────────────

class SavedContainerCard extends StatelessWidget {
  final String name;
  final String uri;
  final VoidCallback onUnlock;
  final VoidCallback onForget;

  /// Called when the card is long-pressed → opens configuration sheet.
  final VoidCallback? onLongPress;

  const SavedContainerCard({
    super.key,
    required this.name,
    required this.uri,
    required this.onUnlock,
    required this.onForget,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Semantics(
      label: 'Locked container $name. Tap to unlock.',
      button: true,
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onUnlock,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.folder_zip_outlined,
                      size: 20, color: cs.outline),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: Theme.of(context).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Row(children: [
                        Icon(Icons.lock, size: 11, color: cs.outline),
                        const SizedBox(width: 4),
                        Text('Locked',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: cs.outline)),
                      ]),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onUnlock,
                  tooltip: 'Unlock container',
                  icon:
                      Icon(Icons.lock_open_outlined, color: cs.primary),
                ),
                IconButton(
                  onPressed: onForget,
                  tooltip: 'Remove from dashboard',
                  icon: Icon(Icons.close, color: cs.outline, size: 18),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}