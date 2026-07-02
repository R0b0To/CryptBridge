import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../models/mounted_container.dart';
import '../../../services/vaultexplorer_api.dart';
import '../../../utils/format_utils.dart';

// ── Base Container Card (Internal) ──────────────────────────────────────────

class _BaseContainerCard extends StatelessWidget {
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final IconData icon;
  final Color iconColor;
  final Color iconBackgroundColor;
  final String title;
  final Widget subtitle;
  final Widget trailingAction;
  final Widget? bottomContent;

  const _BaseContainerCard({
    required this.onTap,
    this.onLongPress,
    required this.icon,
    required this.iconColor,
    required this.iconBackgroundColor,
    required this.title,
    required this.subtitle,
    required this.trailingAction,
    this.bottomContent,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: iconBackgroundColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, size: 24, color: iconColor),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        subtitle,
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  trailingAction,
                ],
              ),
              if (bottomContent != null) ...[
                const SizedBox(height: 16),
                bottomContent!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Mounted container card ────────────────────────────────────────────────────

class ContainerCard extends StatelessWidget {
  final MountedContainer container;
  final ValueChanged<int> onLocked;
  final VoidCallback? onLongPress;
  final VoidCallback onBrowse;

  const ContainerCard({
    super.key,
    required this.container,
    required this.onLocked,
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

    return _BaseContainerCard(
      onTap: onBrowse,
      onLongPress: onLongPress,
      icon: Icons.folder_zip_outlined,
      iconColor: cs.onPrimaryContainer,
      iconBackgroundColor: cs.primaryContainer,
      title: container.displayName,
      subtitle: Row(
        children: [
          // STATUS: Currently Unlocked/Mounted
          Icon(Icons.lock_open, size: 14, color: cs.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              hasSpace
                  ? '${formatBytes(container.freeSpace)} free of ${formatBytes(container.totalSpace)}'
                  : 'Vol ${container.volId} · Mounted',
              style: textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      // ACTION: Tap to Lock
      trailingAction: _LockButton(container: container, onLocked: onLocked),
      bottomContent: hasSpace
          ? ClipRRect(
              borderRadius: BorderRadius.circular(100),
              child: LinearProgressIndicator(
                value: usedFraction,
                minHeight: 4,
                backgroundColor: cs.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(
                  _barColor(usedFraction, cs),
                ),
              ),
            )
          : null,
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
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: cs.error,
              ),
            )
          // ACTION ICON: Represents what happens when tapped (it locks)
          : Icon(Icons.lock_outline, size: 24, color: cs.error),
    );
  }
}

// ── Saved (locked) container card ─────────────────────────────────────────────

class SavedContainerCard extends StatelessWidget {
  final String name;
  final String uri;
  final VoidCallback onUnlock;
  final VoidCallback? onLongPress;

  const SavedContainerCard({
    super.key,
    required this.name,
    required this.uri,
    required this.onUnlock,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return _BaseContainerCard(
      onTap: onUnlock,
      onLongPress: onLongPress,
      icon: Icons.folder_zip_outlined,
      iconColor: cs.onSurfaceVariant,
      iconBackgroundColor: cs.surfaceContainerHighest,
      title: name,
      subtitle: Row(
        children: [
          // STATUS: Currently Locked
          Icon(Icons.lock, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            'Locked',
            style: textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
      // ACTION ICON: Represents what happens when tapped (it unlocks)
      trailingAction: IconButton(
        icon: Icon(Icons.lock_open_outlined, color: cs.primary),
        tooltip: 'Unlock container',
        onPressed: onUnlock,
      ),
    );
  }
}