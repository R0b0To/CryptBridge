import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../models/mounted_container.dart';
import '../../../services/vaultexplorer_api.dart';
import '../../../utils/format_utils.dart';

// ── Mounted container card ────────────────────────────────────────────────────

class ContainerCard extends StatelessWidget {
  final MountedContainer container;
  final ValueChanged<int> onLocked;
  final VoidCallback onReturn;
  final VoidCallback? onLongPress;
  final VoidCallback onBrowse;

  const ContainerCard({
    super.key,
    required this.container,
    required this.onLocked,
    required this.onReturn,
    required this.onBrowse,
    this.onLongPress,
  });

  Color _barColor(double fraction, ColorScheme cs) {
    if (fraction > 0.90) return cs.error;
    if (fraction > 0.70) return cs.secondary;
    return cs.primary;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final usedBytes = container.totalSpace - container.freeSpace;
    final usedFraction = container.totalSpace > 0
        ? (usedBytes / container.totalSpace).clamp(0.0, 1.0)
        : 0.0;
    final hasSpace = container.totalSpace > 0;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onBrowse,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.folder_zip_outlined,
                      size: 20,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          container.displayName,
                          style: textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hasSpace
                              ? '${formatBytes(container.freeSpace)} free'
                                    ' of ${formatBytes(container.totalSpace)}'
                              : 'Vol ${container.volId} · mounted',
                          style: textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  _LockButton(container: container, onLocked: onLocked),
                ],
              ),
              if (hasSpace) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(100),
                  child: LinearProgressIndicator(
                    value: usedFraction,
                    minHeight: 4,
                    backgroundColor: cs.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _barColor(usedFraction, cs),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(Icons.arrow_forward, size: 14, color: cs.primary),
                  const SizedBox(width: 6),
                  Text(
                    'Browse',
                    style: textTheme.labelLarge?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (onLongPress != null)
                    Text(
                      'Hold to configure',
                      style: textTheme.bodySmall?.copyWith(
                        fontSize: 10,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Lock button ───────────────────────────────────────────────────────────────

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
    if (!vaultExplorerApi.acquireLockGuard(widget.container.volId)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'An operation is in progress. Please wait before locking.',
            ),
          ),
        );
      }
      return;
    }

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
      vaultExplorerApi.releaseLockGuard(widget.container.volId);
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: _loading ? null : _lock,
      tooltip: 'Lock container',
      icon: _loading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: cs.error),
            )
          : Icon(Icons.lock_outline, size: 20, color: cs.error),
    );
  }
}

// ── Saved (locked) container card ─────────────────────────────────────────────

class SavedContainerCard extends StatelessWidget {
  final String name;
  final String uri;
  final VoidCallback onUnlock;
  final VoidCallback? onLongPress;
  final VoidCallback onForget;

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
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onUnlock,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.folder_zip_outlined,
                  size: 20,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.lock, size: 12, color: cs.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text(
                          'Locked',
                          style: textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.lock_open_outlined, color: cs.primary),
            ],
          ),
        ),
      ),
    );
  }
}
