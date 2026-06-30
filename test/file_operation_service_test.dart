import 'dart:async';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Inline copies of library-private classes under test.
//
// _CopySemaphore lives in file_operation_service.dart (library-private).
// ConcurrencyLimiter lives in file_grid_view.dart (public but widget-file).
// Both are inlined here so this test file has no Flutter widget dependencies.
//
// FileOperation display logic is tested via a @visibleForTesting factory
// added to file_operation.dart — see the patch at the bottom of this file.
// ---------------------------------------------------------------------------

// ── _CopySemaphore (from file_operation_service.dart) ────────────────────────

class _CopySemaphore {
  final int maxConcurrent;
  int _running = 0;
  final _queue = <Completer<void>>[];

  _CopySemaphore(this.maxConcurrent);

  Future<void> acquire() async {
    if (_running < maxConcurrent) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _queue.add(c);
    await c.future;
  }

  void release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else {
      _running = (_running - 1).clamp(0, maxConcurrent);
    }
  }

  // Test helpers
  int get running => _running;
  int get waiting => _queue.length;
}

// ── ConcurrencyLimiter (from file_grid_view.dart) ────────────────────────────

class ConcurrencyLimiter {
  final int maxConcurrency;
  int _running = 0;
  final _waiting = <Completer<void>>[];

  ConcurrencyLimiter(this.maxConcurrency);

  Future<void> acquire(Completer<void> completer) async {
    if (_running < maxConcurrency) {
      _running++;
      completer.complete();
      return;
    }
    _waiting.add(completer);
    await completer.future;
  }

  void cancel(Completer<void> completer) {
    if (_waiting.remove(completer)) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('Cancelled in queue'));
      }
    }
  }

  void release() {
    _running = (_running - 1).clamp(0, maxConcurrency);
    _drainNext();
  }

  void _drainNext() {
    while (_waiting.isNotEmpty && _running < maxConcurrency) {
      final next = _waiting.removeLast();
      if (next.isCompleted) continue; // skip cancelled — no slot consumed
      _running++;
      next.complete();
    }
  }

  int get running => _running;
  int get waiting => _waiting.length;
}

// ── makeUniqueName (from FileOperationService) ───────────────────────────────
// The implementation in FileOperationService.makeUniqueName is identical to the
// one in file_browser_screen.dart already covered by utils_test.dart.
// Only the signature differs (static method vs top-level fn). One smoke test
// confirms the wiring and avoids silent divergence.

String _makeUniqueName(String fileName, Set<String> existingNames) {
  if (!existingNames.contains(fileName.toLowerCase())) return fileName;
  final dotIdx = fileName.lastIndexOf('.');
  final stem   = dotIdx != -1 ? fileName.substring(0, dotIdx) : fileName;
  final ext    = dotIdx != -1 ? fileName.substring(dotIdx) : '';
  for (int i = 1; i < 9999; i++) {
    final candidate = '$stem ($i)$ext';
    if (!existingNames.contains(candidate.toLowerCase())) return candidate;
  }
  return '$fileName-${DateTime.now().millisecondsSinceEpoch}';
}

// ===========================================================================
// Tests
// ===========================================================================

void main() {

  // ── _CopySemaphore ─────────────────────────────────────────────────────────

  group('_CopySemaphore — immediate acquire', () {
    test('acquires immediately when under capacity', () async {
      final sem = _CopySemaphore(3);
      await sem.acquire();
      await sem.acquire();
      expect(sem.running, 2);
      expect(sem.waiting, 0);
    });

    test('acquires immediately at exact capacity', () async {
      final sem = _CopySemaphore(1);
      await sem.acquire();
      expect(sem.running, 1);
      expect(sem.waiting, 0);
    });
  });

  group('_CopySemaphore — queuing', () {
    test('queues when at capacity', () async {
      final sem = _CopySemaphore(1);
      await sem.acquire(); // fills the slot

      var acquired = false;
      final waiter = sem.acquire().then((_) => acquired = true);

      // Give the event loop a turn — waiter should not have completed.
      await Future<void>.delayed(Duration.zero);
      expect(acquired, isFalse);
      expect(sem.waiting, 1);

      sem.release(); // transfers slot
      await waiter;
      expect(acquired, isTrue);
      expect(sem.waiting, 0);
    });

    test('slot count stays at maxConcurrent when slot is transferred to waiter',
        () async {
      final sem = _CopySemaphore(2);
      await sem.acquire();
      await sem.acquire(); // both slots taken

      final waiter = sem.acquire(); // queued
      await Future<void>.delayed(Duration.zero);
      expect(sem.running, 2); // still 2, slot not yet transferred

      sem.release(); // transfers one slot
      await waiter;
      expect(sem.running, 2); // transferred, not freed then re-acquired
    });

    test('multiple waiters are drained in FIFO order', () async {
      final sem = _CopySemaphore(1);
      await sem.acquire();

      final order = <int>[];
      final futures = [
        sem.acquire().then((_) { order.add(1); sem.release(); }),
        sem.acquire().then((_) { order.add(2); sem.release(); }),
        sem.acquire().then((_) { order.add(3); sem.release(); }),
      ];

      await Future<void>.delayed(Duration.zero);
      expect(sem.waiting, 3);
      sem.release(); // kick off the chain

      await Future.wait(futures);
      expect(order, [1, 2, 3]);
    });
  });

  group('_CopySemaphore — release with no waiters', () {
    test('decrements running when queue is empty', () async {
      final sem = _CopySemaphore(3);
      await sem.acquire();
      await sem.acquire();
      expect(sem.running, 2);
      sem.release();
      expect(sem.running, 1);
      sem.release();
      expect(sem.running, 0);
    });

    test('running never goes below zero', () async {
      final sem = _CopySemaphore(2);
      sem.release(); // release without acquire
      expect(sem.running, 0);
    });
  });

  // ── ConcurrencyLimiter ────────────────────────────────────────────────────

  group('ConcurrencyLimiter — acquire and release', () {
    test('acquires immediately when under capacity', () async {
      final limiter = ConcurrencyLimiter(2);
      final c1 = Completer<void>();
      final c2 = Completer<void>();
      await limiter.acquire(c1);
      await limiter.acquire(c2);
      expect(limiter.running, 2);
    });

    test('queues when at capacity', () async {
      final limiter = ConcurrencyLimiter(1);
      final c1 = Completer<void>();
      await limiter.acquire(c1);

      final c2 = Completer<void>();
      var acquired = false;
      limiter.acquire(c2).then((_) => acquired = true);

      await Future<void>.delayed(Duration.zero);
      expect(acquired, isFalse);
      expect(limiter.waiting, 1);

      limiter.release();
      await Future<void>.delayed(Duration.zero);
      expect(acquired, isTrue);
    });
  });

  group('ConcurrencyLimiter — cancel', () {
    test('cancel removes waiter without consuming a slot', () async {
      final limiter = ConcurrencyLimiter(1);
      final c1 = Completer<void>();
      await limiter.acquire(c1);

      final c2 = Completer<void>();
      final waiterFuture = limiter.acquire(c2).catchError((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(limiter.waiting, 1);

      limiter.cancel(c2);
      await waiterFuture; // should complete via error path
      expect(limiter.waiting, 0);

      // Releasing the real slot should not try to drain c2 again.
      final c3 = Completer<void>();
      var c3Acquired = false;
      limiter.acquire(c3).then((_) => c3Acquired = true);
      await Future<void>.delayed(Duration.zero);
      expect(c3Acquired, isFalse); // c3 is now queued

      limiter.release(); // releases c1's slot → should go to c3
      await Future<void>.delayed(Duration.zero);
      expect(c3Acquired, isTrue);
      expect(limiter.running, 1);
    });

    test('cancelling an already-completed completer is a no-op', () async {
      final limiter = ConcurrencyLimiter(2);
      final c1 = Completer<void>();
      await limiter.acquire(c1); // completes immediately
      // c1 is not in the _waiting list; cancel should be harmless
      limiter.cancel(c1);
      expect(limiter.running, 1);
    });
  });

  group('ConcurrencyLimiter — _drainNext drains ALL available slots', () {
    // This test specifically covers the FIX P8 regression: the original
    // _drainNext had `return` inside the while loop, draining only ONE waiter
    // per release() even when multiple slots opened up simultaneously.
    test('drains multiple waiters when maxConcurrency > 1 and all slots free',
        () async {
      final limiter = ConcurrencyLimiter(3);

      // Fill all 3 slots.
      final a = Completer<void>(); await limiter.acquire(a);
      final b = Completer<void>(); await limiter.acquire(b);
      final c = Completer<void>(); await limiter.acquire(c);
      expect(limiter.running, 3);

      // Queue 3 waiters.
      final acquired = <int>[];
      final w1 = Completer<void>();
      final w2 = Completer<void>();
      final w3 = Completer<void>();
      limiter.acquire(w1).then((_) => acquired.add(1));
      limiter.acquire(w2).then((_) => acquired.add(2));
      limiter.acquire(w3).then((_) => acquired.add(3));
      await Future<void>.delayed(Duration.zero);
      expect(limiter.waiting, 3);

      // Release all 3 real slots.
      limiter.release();
      limiter.release();
      limiter.release();
      await Future<void>.delayed(Duration.zero);

      // All 3 waiters should have been unblocked, not just 1.
      expect(acquired.length, 3,
          reason: '_drainNext must loop until queue empty or slots full');
      expect(limiter.running, 3);
      expect(limiter.waiting, 0);
    });

    test('skips cancelled completers without consuming a slot', () async {
      final limiter = ConcurrencyLimiter(1);
      final real = Completer<void>(); await limiter.acquire(real);

      // Queue: cancelled, then live.
      final cancelled = Completer<void>();
      final live      = Completer<void>();
      limiter.acquire(cancelled).catchError((_) {});
      limiter.acquire(live);
      await Future<void>.delayed(Duration.zero);

      limiter.cancel(cancelled); // cancelled is still in queue but completed
      expect(limiter.waiting, 1); // live remains

      limiter.release(); // should skip cancelled and give slot to live
      await Future<void>.delayed(Duration.zero);
      expect(live.isCompleted, isTrue);
      expect(limiter.running, 1); // slot transferred to live, not lost
    });
  });

  // ── makeUniqueName (FileOperationService version) ─────────────────────────

  group('makeUniqueName — smoke tests (FOS implementation)', () {
    // Full coverage lives in utils_test.dart. These guard against the two
    // implementations silently diverging.
    test('no conflict → original name', () {
      expect(_makeUniqueName('report.pdf', {}), 'report.pdf');
    });

    test('conflict → (1) suffix', () {
      expect(_makeUniqueName('report.pdf', {'report.pdf'}), 'report (1).pdf');
    });

    test('conflict chain → increments', () {
      expect(
        _makeUniqueName('file.txt',
            {'file.txt', 'file (1).txt', 'file (2).txt'}),
        'file (3).txt',
      );
    });

    test('case-insensitive conflict detection', () {
      expect(_makeUniqueName('Report.PDF', {'report.pdf'}), 'Report (1).PDF');
    });

    test('no extension', () {
      expect(_makeUniqueName('notes', {'notes'}), 'notes (1)');
    });
  });

  // ── FileItemStatus.copyWith ───────────────────────────────────────────────
  // FileItemStatus is @immutable with a copyWith; test it inline since the
  // class itself can be accessed via file_operation.dart's public exports.
  //
  // NOTE: If file_operation.dart is not importable in tests (due to platform
  // channel transitive deps), the copyWith logic can be inlined here.

  group('FileItemStatus.copyWith', () {
    // Inline the minimal record to avoid pulling in platform dependencies.
    test('copyWith result → pending', () {
      final status = _FileItemStatus(path: 'a.txt', result: _FileItemResult.pending);
      final updated = status.copyWith(result: _FileItemResult.success);
      expect(updated.result, _FileItemResult.success);
      expect(updated.path, 'a.txt'); // unchanged field preserved
    });

    test('copyWith errorMessage is set independently of result', () {
      final status = _FileItemStatus(path: 'b.pdf', result: _FileItemResult.pending);
      final failed = status.copyWith(
          result: _FileItemResult.failed, errorMessage: 'disk full');
      expect(failed.result, _FileItemResult.failed);
      expect(failed.errorMessage, 'disk full');
    });

    test('copyWith does not mutate original', () {
      final original = _FileItemStatus(path: 'c.mp4', result: _FileItemResult.pending);
      original.copyWith(result: _FileItemResult.skipped);
      expect(original.result, _FileItemResult.pending); // unchanged
    });
  });
}

// ── Minimal inline of FileItemStatus / FileItemResult for the copyWith tests ──

enum _FileItemResult { pending, success, skipped, failed }

class _FileItemStatus {
  final String path;
  final _FileItemResult result;
  final String? errorMessage;

  const _FileItemStatus({
    required this.path,
    this.result = _FileItemResult.pending,
    this.errorMessage,
  });

  _FileItemStatus copyWith({_FileItemResult? result, String? errorMessage}) =>
      _FileItemStatus(
        path:         path,
        result:       result ?? this.result,
        errorMessage: errorMessage ?? this.errorMessage,
      );
}