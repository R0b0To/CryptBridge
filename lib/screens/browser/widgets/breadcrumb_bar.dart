import 'package:flutter/material.dart';

import '../file_browser_screen.dart';

class BreadcrumbBar extends StatelessWidget {
  final List<PathSegment> stack;
  final ValueChanged<int> onTap;

  const BreadcrumbBar({Key? key, required this.stack, required this.onTap})
    : super(key: key);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      height: 40, // Expanded slightly to provide a better touch target area
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 1)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: stack.length,
        itemBuilder: (_, i) {
          final isLast = i == stack.length - 1;

          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLast)
                // The current directory is non-interactive to save redundant taps
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    stack[i].label,
                    style: textTheme.labelLarge?.copyWith(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else
                // Clickable historical directories
                InkWell(
                  onTap: () => onTap(i),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Text(
                      stack[i].label,
                      style: textTheme.labelLarge?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              if (!isLast)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Icon(
                    Icons.chevron_right_rounded, // Softer rounded chevron
                    size: 16,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
