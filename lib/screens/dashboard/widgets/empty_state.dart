import 'package:flutter/material.dart';

class EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const EmptyState({Key? key, required this.onAdd}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Soft rounded M3 container for the key empty state illustration
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cs.surfaceContainer,
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Icon(
                Icons.lock_outline_rounded,
                size: 30,
                color: cs.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No containers',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Mount a VeraCrypt container to get started',
              style: textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: const Text('Mount Container'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(
                  0,
                  48,
                ), // Overrides global full-width setting to keep the layout compact
                padding: const EdgeInsets.symmetric(horizontal: 24),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
