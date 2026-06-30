import 'package:flutter/material.dart';
import 'pattern_lock_view.dart';

/// Bottom sheet that guides the user through setting up a pattern lock.
///
/// Flow:
///   1. Draw a pattern (≥ 4 dots).
///   2. Confirm by drawing the same pattern again.
///   3. Returns the SHA-256 hash of the confirmed pattern via [Navigator.pop].
///
/// The return value is `String?` — null if the user cancels.
class PatternSetupSheet extends StatefulWidget {
  const PatternSetupSheet({Key? key}) : super(key: key);

  @override
  State<PatternSetupSheet> createState() => _PatternSetupSheetState();
}

class _PatternSetupSheetState extends State<PatternSetupSheet> {
  _SetupStep _step = _SetupStep.draw;
  List<int>? _firstPattern;
  String? _error;
  bool _showError = false;
  int _resetKey = 0; // Force PatternLockView rebuild on reset.

  void _onPatternComplete(List<int> pattern) {
    if (pattern.length < 4) {
      setState(() {
        _error = 'Connect at least 4 dots';
        _showError = true;
      });
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted)
          setState(() {
            _showError = false;
            _resetKey++;
          });
      });
      return;
    }

    switch (_step) {
      case _SetupStep.draw:
        setState(() {
          _firstPattern = pattern;
          _step = _SetupStep.confirm;
          _error = null;
          _showError = false;
          _resetKey++;
        });
        break;

      case _SetupStep.confirm:
        final firstHash = hashPattern(_firstPattern!);
        final confirmHash = hashPattern(pattern);
        if (firstHash == confirmHash) {
          Navigator.pop(context, firstHash);
        } else {
          setState(() {
            _error = 'Patterns don\'t match — try again';
            _showError = true;
          });
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted) {
              setState(() {
                _step = _SetupStep.draw;
                _firstPattern = null;
                _showError = false;
                _error = null;
                _resetKey++;
              });
            }
          });
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final mq = MediaQuery.of(context);

    final title = _step == _SetupStep.draw
        ? 'Draw your unlock pattern'
        : 'Confirm your pattern';
    final subtitle = _showError
        ? (_error ?? '')
        : (_step == _SetupStep.draw
              ? 'Connect at least 4 dots'
              : 'Draw the same pattern again');

    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Header ──────────────────────────────────────────────
              Row(
                children: [
                  Icon(
                    Icons.pattern_rounded,
                    size: 20,
                    color: _showError ? cs.error : cs.primary,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    title,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: _showError ? cs.error : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  subtitle,
                  style: textTheme.bodySmall?.copyWith(
                    color: _showError ? cs.error : cs.onSurfaceVariant,
                    fontWeight: _showError ? FontWeight.bold : null,
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // ── Pattern grid ────────────────────────────────────────
              Center(
                child: PatternLockView(
                  key: ValueKey(_resetKey),
                  onPatternComplete: _onPatternComplete,
                  showError: _showError,
                ),
              ),

              const SizedBox(height: 20),

              // ── Cancel button ───────────────────────────────────────
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Cancel',
                  style: textTheme.labelLarge?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _SetupStep { draw, confirm }
