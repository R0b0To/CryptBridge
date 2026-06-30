import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointycastle/digests/sha256.dart';

/// A beautiful 3×3 pattern lock widget drawn on a [CustomPainter].
///
/// Returns the selected pattern as a `List<int>` (dot indices 0-8) via
/// [onPatternComplete].  Dots are numbered left-to-right, top-to-bottom:
///
///     0  1  2
///     3  4  5
///     6  7  8
///
class PatternLockView extends StatefulWidget {
  /// Called when the user lifts their finger after connecting ≥1 dot.
  final ValueChanged<List<int>> onPatternComplete;

  /// Number of dots along each axis.
  final int gridSize;

  /// If true, the dots/lines are shown in the error colour after a wrong attempt.
  final bool showError;

  /// Whether the widget currently accepts touch input.
  final bool enabled;

  const PatternLockView({
    Key? key,
    required this.onPatternComplete,
    this.gridSize = 3,
    this.showError = false,
    this.enabled = true,
  }) : super(key: key);

  @override
  State<PatternLockView> createState() => _PatternLockViewState();
}

class _PatternLockViewState extends State<PatternLockView>
    with SingleTickerProviderStateMixin {
  final List<int> _selectedDots = [];
  Offset? _currentTouch;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PatternLockView old) {
    super.didUpdateWidget(old);
    if (widget.showError != old.showError && !widget.showError) {
      _selectedDots.clear();
      _currentTouch = null;
    }
  }

  // ── Layout helpers ──────────────────────────────────────────────────────────

  List<Offset> _dotCenters(Size size) {
    final n = widget.gridSize;
    final dx = size.width / n;
    final dy = size.height / n;
    return List.generate(n * n, (i) {
      final col = i % n;
      final row = i ~/ n;
      return Offset(dx * (col + 0.5), dy * (row + 0.5));
    });
  }

  int? _hitTest(Offset pos, Size size) {
    final centers = _dotCenters(size);
    final hitRadius = min(size.width, size.height) / widget.gridSize * 0.4;
    for (int i = 0; i < centers.length; i++) {
      if ((centers[i] - pos).distance <= hitRadius) return i;
    }
    return null;
  }

  // ── Touch handling ──────────────────────────────────────────────────────────

  void _onPanStart(DragStartDetails d) {
    if (!widget.enabled) return;
    final box = context.findRenderObject() as RenderBox;
    final pos = box.globalToLocal(d.globalPosition);
    setState(() {
      _selectedDots.clear();
      _currentTouch = pos;
    });
    _trySelect(pos, box.size);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (!widget.enabled) return;
    final box = context.findRenderObject() as RenderBox;
    final pos = box.globalToLocal(d.globalPosition);
    setState(() => _currentTouch = pos);
    _trySelect(pos, box.size);
  }

  void _onPanEnd(DragEndDetails _) {
    if (!widget.enabled) return;
    setState(() => _currentTouch = null);
    if (_selectedDots.isNotEmpty) {
      widget.onPatternComplete(List.unmodifiable(_selectedDots));
    }
  }

  void _trySelect(Offset pos, Size size) {
    final dot = _hitTest(pos, size);
    if (dot != null && !_selectedDots.contains(dot)) {
      _selectedDots.add(dot);
      HapticFeedback.lightImpact();
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (_, _) => GestureDetector(
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        child: CustomPaint(
          painter: _PatternPainter(
            gridSize: widget.gridSize,
            selected: _selectedDots,
            currentTouch: _currentTouch,
            colorScheme: Theme.of(context).colorScheme,
            showError: widget.showError,
            pulseScale: _pulseAnim.value,
          ),
          size: const Size(280, 280),
        ),
      ),
    );
  }
}

// ── Painter ───────────────────────────────────────────────────────────────────

class _PatternPainter extends CustomPainter {
  final int gridSize;
  final List<int> selected;
  final Offset? currentTouch;
  final ColorScheme colorScheme;
  final bool showError;
  final double pulseScale;

  _PatternPainter({
    required this.gridSize,
    required this.selected,
    this.currentTouch,
    required this.colorScheme,
    required this.showError,
    required this.pulseScale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = gridSize;
    final dx = size.width / n;
    final dy = size.height / n;
    final centers = List.generate(n * n, (i) {
      final col = i % n;
      final row = i ~/ n;
      return Offset(dx * (col + 0.5), dy * (row + 0.5));
    });

    final activeColor = showError ? colorScheme.error : colorScheme.primary;
    final inactiveColor = colorScheme.onSurfaceVariant.withValues(alpha: 0.35);

    // Lines
    if (selected.length > 1) {
      final linePaint = Paint()
        ..color = activeColor.withValues(alpha: 0.6)
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      final path = Path()
        ..moveTo(centers[selected[0]].dx, centers[selected[0]].dy);
      for (int i = 1; i < selected.length; i++) {
        path.lineTo(centers[selected[i]].dx, centers[selected[i]].dy);
      }
      canvas.drawPath(path, linePaint);
    }

    // Trailing line to finger
    if (selected.isNotEmpty && currentTouch != null) {
      final trailPaint = Paint()
        ..color = activeColor.withValues(alpha: 0.3)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(centers[selected.last], currentTouch!, trailPaint);
    }

    // Dots
    final dotRadius = min(dx, dy) * 0.12;
    for (int i = 0; i < centers.length; i++) {
      final isSelected = selected.contains(i);

      // Outer ring
      final ringPaint = Paint()
        ..color = isSelected ? activeColor : inactiveColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      final ringRadius = dotRadius * 2.2 * (isSelected ? 1.0 : pulseScale);
      canvas.drawCircle(centers[i], ringRadius, ringPaint);

      // Inner dot
      final dotPaint = Paint()
        ..color = isSelected ? activeColor : inactiveColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(centers[i], dotRadius, dotPaint);

      // Glow for selected dots
      if (isSelected) {
        final glowPaint = Paint()
          ..color = activeColor.withValues(alpha: 0.15)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(centers[i], dotRadius * 3.2, glowPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PatternPainter old) => true;
}

// ── Utility ───────────────────────────────────────────────────────────────────

/// Computes a SHA-256 hash of the pattern for secure storage.
///
/// The pattern is serialised as a dash-separated string of dot indices
/// (e.g. "0-1-4-7-8") and then hashed.
String hashPattern(List<int> pattern) {
  final input = pattern.join('-');
  final bytes = Uint8List.fromList(utf8.encode(input));
  final digest = SHA256Digest().process(bytes);
  return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
