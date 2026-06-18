import 'package:flutter/material.dart';

import '../file_browser_screen.dart';

class BreadcrumbBar extends StatelessWidget {
  final List<PathSegment> stack;
  final ValueChanged<int> onTap;

  const BreadcrumbBar({
    Key? key,
    required this.stack,
    required this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      height: 38,
      color: cs.surface,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: stack.length,
        itemBuilder: (_, i) {
          final isLast = i == stack.length - 1;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () => onTap(i),
                child: Text(
                  stack[i].label,
                  style: TextStyle(
                    color: isLast ? cs.onSurface : cs.primary,
                    fontSize: 12,
                    fontWeight:
                        isLast ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
              if (!isLast)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child:
                      Icon(Icons.chevron_right, size: 14, color: cs.outline),
                ),
            ],
          );
        },
      ),
    );
  }
}
