import 'package:flutter/material.dart';

class FileActionsSheet extends StatelessWidget {
  final String fileName;
  final VoidCallback onExport;

  const FileActionsSheet({
    Key? key,
    required this.fileName,
    required this.onExport,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toUpperCase()
        : 'FILE';

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // File info header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: cs.surfaceVariant,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: cs.outline),
                  ),
                  child: Text(
                    ext,
                    style: TextStyle(
                      color: cs.primary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    fileName,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 8),

            // Actions
            _ActionItem(
              icon: Icons.download_outlined,
              label: 'Export to Downloads',
              subtitle: 'Decrypt and save to /storage/emulated/0/Download',
              onTap: onExport,
            ),
            const SizedBox(height: 4),
            const _ActionItem(
              icon: Icons.share_outlined,
              label: 'Export & Share',
              subtitle: 'Coming soon',
              onTap: null,
            ),
            const SizedBox(height: 4),
            _ActionItem(
              icon: Icons.delete_outline,
              label: 'Delete from container',
              subtitle: 'Coming soon',
              onTap: null,
              color: cs.error,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback? onTap;
  final Color? color;

  const _ActionItem({
    Key? key,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
    this.color,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final effectiveColor = color ?? cs.onSurface;
    final disabled = onTap == null;

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
      leading: Icon(
        icon,
        size: 20,
        color: disabled ? cs.outline : effectiveColor,
      ),
      title: Text(
        label,
        style: TextStyle(
          color: disabled ? cs.outline : effectiveColor,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: disabled ? cs.outline.withOpacity(0.6) : cs.outline,
          fontSize: 11,
        ),
      ),
      onTap: onTap,
    );
  }
}