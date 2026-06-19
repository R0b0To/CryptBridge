import 'package:flutter/material.dart';
import '../../../models/mounted_container.dart';
import '../../../services/vaultexplorer_api.dart';
import '../../browser/file_browser_screen.dart';

class ContainerCard extends StatelessWidget {
  final MountedContainer container;
  final ValueChanged<int> onLocked;

  const ContainerCard({
    Key? key,
    required this.container,
    required this.onLocked,
  }) : super(key: key);

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    double size = bytes.toDouble();
    int idx = 0;
    while (size >= 1024 && idx < suffixes.length - 1) {
      size /= 1024;
      idx++;
    }
    return '${size.toStringAsFixed(size < 10 ? 1 : 0)} ${suffixes[idx]}';
  }

  Color _storageColor(double usedFraction, ColorScheme cs) {
    if (usedFraction > 0.90) return cs.error;
    if (usedFraction > 0.70) return const Color(0xFFFFA726); // amber
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

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => FileBrowserScreen(container: container),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header row ──────────────────────────────────────────────
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(Icons.lock_open,
                        size: 18, color: cs.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          container.displayName,
                          style:
                              Theme.of(context).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hasSpaceData
                              ? 'Vol ${container.volId} · '
                                  '${_formatBytes(container.freeSpace)} free '
                                  'of ${_formatBytes(container.totalSpace)}'
                              : 'Volume ${container.volId}',
                          style:
                              Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  _LockButton(
                      container: container, onLocked: onLocked),
                ],
              ),

              // ── Storage usage bar ────────────────────────────────────────
              if (hasSpaceData) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: usedFraction,
                    minHeight: 3,
                    backgroundColor: cs.surfaceVariant,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(barColor),
                  ),
                ),
              ],

              const SizedBox(height: 14),
              const Divider(),
              const SizedBox(height: 12),

              // ── Stat row ─────────────────────────────────────────────────
              Row(
                children: [
                  _StatChip(
                    icon: Icons.insert_drive_file_outlined,
                    label:
                        '$fileCount file${fileCount != 1 ? 's' : ''}',
                  ),
                  const SizedBox(width: 10),
                  _StatChip(
                    icon: Icons.folder_outlined,
                    label:
                        '$dirCount folder${dirCount != 1 ? 's' : ''}',
                  ),
                  const Spacer(),
                  Text(
                    'Browse →',
                    style: TextStyle(
                      color: cs.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
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

// ── Stat chip ─────────────────────────────────────────────────────────────────

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _StatChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: cs.outline),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
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
    setState(() => _loading = true);
    try {
      await vaultexplorerApi.lockContainer(widget.container.uri);
      widget.onLocked(widget.container.volId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lock failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: _loading ? null : _lock,
      tooltip: 'Lock container',
      icon: _loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              Icons.lock_outline,
              size: 20,
              color: Theme.of(context).colorScheme.error,
            ),
    );
  }
}