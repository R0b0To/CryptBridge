import 'package:flutter/material.dart';

/// Non-blocking banner shown when the clipboard has pending items.
///
/// ### Why this replaces [ClipboardAppBar]
/// The old [ClipboardAppBar] fully replaced the screen's [AppBar], which
/// meant the "+" menu (New Folder / New File / Import) and search were
/// unreachable while a paste was staged. That directly blocked the
/// "create files while pasting" requirement at the UI level — even though
/// [FileOperationService] never actually held a lock preventing it.
///
/// This banner sits as a slim strip *inside the body*, directly below
/// [BreadcrumbBar]. The normal [AppBar] stays mounted underneath at all
/// times, so every existing action remains one tap away.
///
/// ### Placement
/// ```dart
/// body: Column(children: [
///   BreadcrumbBar(...),
///   if (_clip.hasItems)
///     ClipboardBanner(
///       isCutOperation: _clip.isCutOperation,
///       itemCount: _clip.items.length,
///       sourceLabel: fromHere ? null : _clip.sourceDisplayName,
///       onCancel: () => setState(() => _clip.clear()),
///       onPaste: _paste,
///     ),
///   _StatsBar(...),
///   ...
/// ])
/// ```
///
/// Unlike [ClipboardAppBar], there is no `onBack` parameter — back navigation
/// is handled entirely by the still-visible [AppBar], so this widget owns
/// strictly less responsibility than what it replaces.
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

    return Material(
      color: cs.primaryContainer,
      child: InkWell(
        onTap: onPaste,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              Icon(
                isCutOperation ? Icons.cut_rounded : Icons.copy_rounded,
                size: 18,
                color: cs.onPrimaryContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
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
                child: const Text('Paste here'),
              ),
              IconButton(
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
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
    );
  }
}
