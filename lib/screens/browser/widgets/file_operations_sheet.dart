import 'package:flutter/material.dart';
import '../../../models/file_operation.dart';

/// Full bottom sheet for all in-flight and recent file operations.
///
/// Open it with:
/// ```dart
/// FileOperationsSheet.show(context);
/// ```
///
/// The sheet listens to [FileOperationService] for the top-level list and to
/// each [FileOperation] for per-row progress. No state is stored here —
/// everything is derived from the service.
class FileOperationsSheet extends StatelessWidget {
  const FileOperationsSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const FileOperationsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs        = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.25,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return ListenableBuilder(
          listenable: FileOperationService.instance,
          builder: (context, _) {
            final ops = FileOperationService.instance.operations.reversed.toList();
            final hasActive =
                FileOperationService.instance.activeCount > 0;

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 8, 12),
                  child: Row(
                    children: [
                      Icon(Icons.swap_horiz_rounded,
                          size: 20, color: cs.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          hasActive ? 'Transfers in progress' : 'Recent transfers',
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (!hasActive)
                        TextButton(
                          onPressed: () {
                            FileOperationService.instance.clearFinished();
                            Navigator.pop(context);
                          },
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Clear all'),
                        ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),

                const Divider(height: 1),

                // ── Operation list ───────────────────────────────────────────
                Expanded(
                  child: ops.isEmpty
                      ? _EmptyState(cs: cs, textTheme: textTheme)
                      : ListView.separated(
                          controller: scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: ops.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1, indent: 20),
                          itemBuilder: (_, i) =>
                              _OperationRow(op: ops[i]),
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final ColorScheme cs;
  final TextTheme textTheme;
  const _EmptyState({required this.cs, required this.textTheme});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline_rounded,
                size: 40, color: cs.outline),
            const SizedBox(height: 12),
            Text('No recent transfers',
                style: textTheme.bodyMedium
                    ?.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
      );
}

// ── Single operation row ──────────────────────────────────────────────────────

class _OperationRow extends StatelessWidget {
  final FileOperation op;
  const _OperationRow({required this.op});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: op,
      builder: (context, _) {
        final cs        = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;

        final isActive = op.status == FileOperationStatus.pending ||
            op.status == FileOperationStatus.running;
        final isError  = op.status == FileOperationStatus.failed ||
            op.status == FileOperationStatus.diskFull ||
            op.status == FileOperationStatus.completedWithErrors;
        final isDone   = op.status == FileOperationStatus.completed;
        final isCancelled = op.status == FileOperationStatus.cancelled;

        final statusColor = isError
            ? cs.error
            : isDone
                ? cs.primary
                : isCancelled
                    ? cs.onSurfaceVariant
                    : cs.onSurface;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Top row: icon + title + cancel ────────────────────────────
              Row(
                children: [
                  _StatusIcon(op: op, cs: cs),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          op.shortSummary,
                          style: textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: statusColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _routeLabel(op),
                          style: textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (isActive)
                    IconButton(
                      icon: Icon(Icons.close_rounded,
                          size: 18, color: cs.onSurfaceVariant),
                      tooltip: 'Cancel',
                      onPressed: op.requestCancel,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 32, minHeight: 32),
                    ),
                ],
              ),

              const SizedBox(height: 10),

              // ── Progress bar ───────────────────────────────────────────────
              if (isActive) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: op.progressFraction,
                    minHeight: 3,
                    backgroundColor: cs.surfaceContainerHighest,
                    color: cs.primary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  op.currentActivity.isNotEmpty
                      ? op.currentActivity
                      : op.shortSummary,
                  style: textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],

              // ── Completion summary ─────────────────────────────────────────
              if (!isActive && !isCancelled) ...[
                if (isError && op.errorSummary != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 14, color: cs.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          op.errorSummary!,
                          style: textTheme.bodySmall
                              ?.copyWith(color: cs.error),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  const SizedBox(height: 4),
                  Text(
                    op.completionSummary,
                    style: textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ],

              if (isCancelled) ...[
                const SizedBox(height: 4),
                Text(
                  'Cancelled',
                  style: textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],

              // ── Per-item detail (errors only, collapsed by default) ────────
              if (!isActive && op.failCount > 0)
                _FailedItemsDetail(op: op, cs: cs, textTheme: textTheme),
            ],
          ),
        );
      },
    );
  }

  String _routeLabel(FileOperation op) {
    if (op.isCrossContainer) {
      return '${op.sourceDisplayName} → ${op.destDisplayName}';
    }
    final dest = op.destDirPath.isEmpty ? 'Root' : op.destDirPath;
    return op.isCut ? 'Move to $dest' : 'Copy to $dest';
  }
}

// ── Status icon ───────────────────────────────────────────────────────────────

class _StatusIcon extends StatelessWidget {
  final FileOperation op;
  final ColorScheme cs;
  const _StatusIcon({required this.op, required this.cs});

  @override
  Widget build(BuildContext context) {
    switch (op.status) {
      case FileOperationStatus.pending:
      case FileOperationStatus.running:
        return SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: op.progressFraction,
            color: cs.primary,
            backgroundColor: cs.surfaceContainerHighest,
          ),
        );
      case FileOperationStatus.completed:
        return Icon(Icons.check_circle_rounded, size: 18, color: cs.primary);
      case FileOperationStatus.completedWithErrors:
        return Icon(Icons.warning_amber_rounded, size: 18, color: cs.error);
      case FileOperationStatus.failed:
      case FileOperationStatus.diskFull:
        return Icon(Icons.error_outline_rounded, size: 18, color: cs.error);
      case FileOperationStatus.cancelled:
        return Icon(Icons.cancel_outlined, size: 18, color: cs.onSurfaceVariant);
    }
  }
}

// ── Failed items detail (expandable) ─────────────────────────────────────────

class _FailedItemsDetail extends StatefulWidget {
  final FileOperation op;
  final ColorScheme cs;
  final TextTheme textTheme;
  const _FailedItemsDetail(
      {required this.op, required this.cs, required this.textTheme});

  @override
  State<_FailedItemsDetail> createState() => _FailedItemsDetailState();
}

class _FailedItemsDetailState extends State<_FailedItemsDetail> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final failed = widget.op.itemStatuses
        .where((s) => s.result == FileItemResult.failed)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Row(
            children: [
              Icon(
                _expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: widget.cs.error,
              ),
              const SizedBox(width: 4),
              Text(
                '${failed.length} item${failed.length == 1 ? '' : 's'} failed',
                style: widget.textTheme.bodySmall
                    ?.copyWith(color: widget.cs.error),
              ),
            ],
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 6),
          ...failed.map((s) => Padding(
                padding: const EdgeInsets.only(left: 20, bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.subdirectory_arrow_right_rounded,
                        size: 12, color: widget.cs.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        s.item.name +
                            (s.errorMessage != null
                                ? ' — ${s.errorMessage}'
                                : ''),
                        style: widget.textTheme.bodySmall?.copyWith(
                          color: widget.cs.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ],
    );
  }
}