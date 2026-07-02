import 'package:flutter/material.dart';

/// Non-blocking floating banner shown when the clipboard has pending items.
///
/// Designed as a floating pill to avoid shifting the main layout when items 
/// are added to or removed from the clipboard. Sits overlaid at the bottom center.
class ClipboardBanner extends StatelessWidget {
  final bool isCutOperation;
  final int itemCount;
  final String? sourceLabel;
  final VoidCallback onCancel;
  final VoidCallback onPaste;

  const ClipboardBanner({
    super.key,
    required this.isCutOperation,
    required this.itemCount,
    this.sourceLabel,
    required this.onCancel,
    required this.onPaste,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final verb = isCutOperation ? 'Moving' : 'Copying';
    final fromSuffix = sourceLabel != null ? ' from "$sourceLabel"' : '';
    final titleText =
        '$verb $itemCount item${itemCount == 1 ? '' : 's'}$fromSuffix';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: cs.primaryContainer,
        elevation: 6,
        shadowColor: cs.shadow.withValues(alpha: 0.4),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPaste,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min, // Shrink-wrap to content
              children: [
                Icon(
                  isCutOperation ? Icons.cut_rounded : Icons.copy_rounded,
                  size: 20,
                  color: cs.onPrimaryContainer,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    titleText,
                    style: textTheme.labelLarge?.copyWith(
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onPaste,
                  style: TextButton.styleFrom(
                    foregroundColor: cs.onPrimaryContainer,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  child: const Text('Paste'),
                ),
                Container(
                  width: 1,
                  height: 20,
                  color: cs.onPrimaryContainer.withValues(alpha: 0.2),
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                ),
                IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: cs.onPrimaryContainer,
                  ),
                  tooltip: 'Cancel',
                  onPressed: onCancel,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}