import 'package:flutter/material.dart';
import '../../../models/file_operation.dart';
import 'file_operations_sheet.dart';
import 'dart:async';

/// Persistent transfer progress bar that sits at the bottom of the screen body.
///
/// ### Behaviour
/// - Hidden when there are no active or recent operations.
/// - Shows a single-line summary + indeterminate/determinate progress bar
///   for one active operation.
/// - Shows "N transfers · tap to view" when multiple operations exist.
/// - Tapping always opens [FileOperationsSheet].
/// - Completed operations stay visible for [_kLingerDuration] then auto-hide
///   unless there's a new active op.
///
/// ### Placement
/// Add this as the last child in the browser/dashboard body [Column], just
/// above the existing [_StatusBar] (which shows per-action feedback like
/// "Deleted 3 items"). The two bars serve different concerns and can coexist.
///
/// ```dart
/// Column(children: [
///   BreadcrumbBar(…),
///   _StatsBar(…),
///   …
///   Expanded(child: _buildBody(…)),
///   // ↓ Phase 2 addition
///   const OperationProgressBar(),
///   // ↓ Existing per-action status bar
///   if (_statusMessage != null) _StatusBar(…),
/// ])
/// ```
class OperationProgressBar extends StatefulWidget {
  const OperationProgressBar({super.key});

  @override
  State<OperationProgressBar> createState() => _OperationProgressBarState();
}

class _OperationProgressBarState extends State<OperationProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeCtrl;
  late final Animation<double> _fade;
  
  Timer? _hideTimer;
  static const _kLingerDuration = Duration(seconds: 4); // The missing constant

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fade = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    FileOperationService.instance.addListener(_onServiceChanged);
    _sync();
  }

  @override
  void dispose() {
    FileOperationService.instance.removeListener(_onServiceChanged);
    _hideTimer?.cancel(); // Clean up the timer
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _onServiceChanged() => _sync();

  void _sync() {
    final svc = FileOperationService.instance;
    final visible = svc.operations.isNotEmpty;

    // Always reset the timer when state changes
    _hideTimer?.cancel();

    if (visible) {
      _fadeCtrl.forward();
      
      // If there are no active operations left, handle cleanup
      if (svc.activeCount == 0) {
        // Optional: Check if there are any errors. If so, leave the bar open 
        // so the user notices the failure. They can manually dismiss it.
        final hasErrors = svc.operations.any((op) => 
            op.status == FileOperationStatus.failed ||
            op.status == FileOperationStatus.diskFull ||
            op.status == FileOperationStatus.completedWithErrors);

        if (!hasErrors) {
          // Auto-hide successfully completed operations
          _hideTimer = Timer(_kLingerDuration, () {
            svc.clearFinished();
          });
        }
      }
    } else {
      _fadeCtrl.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: ListenableBuilder(
        listenable: FileOperationService.instance,
        builder: (context, _) {
          final svc = FileOperationService.instance;
          final ops = svc.operations;
          if (ops.isEmpty) return const SizedBox.shrink();

          final active = svc.activeOperations;
          final hasActive = active.isNotEmpty;

          // Pick the representative operation to display inline.
          final primary = hasActive ? active.last : ops.last;

          return _ProgressBarSurface(
            primary: primary,
            totalOps: ops.length,
            hasActive: hasActive,
          );
        },
      ),
    );
  }
}

// ── Surface widget (keeps the outer FadeTransition clean) ─────────────────────

class _ProgressBarSurface extends StatelessWidget {
  final FileOperation primary;
  final int totalOps;
  final bool hasActive;

  const _ProgressBarSurface({
    required this.primary,
    required this.totalOps,
    required this.hasActive,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ListenableBuilder(
      listenable: primary,
      builder: (context, _) {
        final isError =
            primary.status == FileOperationStatus.failed ||
            primary.status == FileOperationStatus.diskFull ||
            primary.status == FileOperationStatus.completedWithErrors;

        final barColor = isError ? cs.error : cs.primary;
        final surfaceColor = isError
            ? cs.errorContainer.withValues(alpha: 0.6)
            : cs.surfaceContainerHigh;
        final textColor = isError ? cs.onErrorContainer : cs.onSurface;
        final subColor = isError
            ? cs.onErrorContainer.withValues(alpha: 0.7)
            : cs.onSurfaceVariant;

        final fraction = primary.progressFraction;
        final multiOp = totalOps > 1;

        // Label: multi-op gets a count badge; single op shows activity text.
        final label = multiOp
            ? '$totalOps transfers'
            : (hasActive && primary.currentActivity.isNotEmpty
                  ? primary.currentActivity
                  : primary.shortSummary);

        final sublabel = multiOp
            ? '${primary.shortSummary} · tap to view all'
            : (hasActive ? _progressText(primary) : primary.completionSummary);

        return GestureDetector(
          onTap: () => FileOperationsSheet.show(context),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            color: surfaceColor,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Progress track ─────────────────────────────────────────
                SizedBox(
                  height: 2,
                  child: hasActive
                      ? LinearProgressIndicator(
                          value: fraction,
                          backgroundColor: cs.surfaceContainerHighest,
                          color: barColor,
                          minHeight: 2,
                        )
                      : LinearProgressIndicator(
                          value: isError ? 1.0 : 1.0,
                          backgroundColor: cs.surfaceContainerHighest,
                          color: barColor,
                          minHeight: 2,
                        ),
                ),

                // ── Content row ────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 9,
                  ),
                  child: Row(
                    children: [
                      // Status indicator
                      _InlineStatusIcon(
                        op: primary,
                        cs: cs,
                        hasActive: hasActive,
                      ),
                      const SizedBox(width: 12),

                      // Text
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              label,
                              style: textTheme.labelLarge?.copyWith(
                                color: textColor,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (sublabel.isNotEmpty) ...[
                              const SizedBox(height: 1),
                              Text(
                                sublabel,
                                style: textTheme.bodySmall?.copyWith(
                                  color: subColor,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),

                      // Chevron
                     if (hasActive)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8.0),
                          child: Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: subColor,
                          ),
                        )
                      else
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 20),
                          color: subColor,
                          tooltip: 'Dismiss',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 40,
                          ),
                          onPressed: () {
                            // Instantly clear finished ops without opening the sheet
                            FileOperationService.instance.clearFinished();
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _progressText(FileOperation op) {
    final done = op.doneCount + op.skipCount + op.failCount;
    final total = op.totalCount;
    if (total == 0) return '';
    final pct = ((done / total) * 100).round();
    return '$done / $total  ($pct%)';
  }
}

// ── Inline status icon (no CircularProgressIndicator animation overhead) ──────

class _InlineStatusIcon extends StatelessWidget {
  final FileOperation op;
  final ColorScheme cs;
  final bool hasActive;
  const _InlineStatusIcon({
    required this.op,
    required this.cs,
    required this.hasActive,
  });

  @override
  Widget build(BuildContext context) {
    if (hasActive) {
      return SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          value: op.progressFraction,
          strokeWidth: 2,
          color: cs.primary,
          backgroundColor: cs.surfaceContainerHighest,
        ),
      );
    }
    switch (op.status) {
      case FileOperationStatus.completed:
        return Icon(Icons.check_circle_rounded, size: 16, color: cs.primary);
      case FileOperationStatus.completedWithErrors:
      case FileOperationStatus.failed:
      case FileOperationStatus.diskFull:
        return Icon(Icons.error_outline_rounded, size: 16, color: cs.error);
      case FileOperationStatus.cancelled:
        return Icon(
          Icons.cancel_outlined,
          size: 16,
          color: cs.onSurfaceVariant,
        );
      default:
        return Icon(
          Icons.swap_horiz_rounded,
          size: 16,
          color: cs.onSurfaceVariant,
        );
    }
  }
}
