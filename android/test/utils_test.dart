import 'package:flutter_test/flutter_test.dart';
import 'dart:collection';

// ---------------------------------------------------------------------------
// Inline copies of the pure functions under test.
//
// These are reproduced here rather than imported so the test file stays
// self-contained and can be verified before the main codebase is wired up.
// Once the project is structured as a proper package, replace these with
// direct imports.
// ---------------------------------------------------------------------------

// ── format_utils.dart ───────────────────────────────────────────────────────

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
  double size = bytes.toDouble();
  int idx = 0;
  while (size >= 1024 && idx < suffixes.length - 1) {
    size /= 1024;
    idx++;
  }
  return '${size.toStringAsFixed(size < 10 ? 1 : 0)} ${suffixes[idx]}';
}

// ── validation_utils.dart ───────────────────────────────────────────────────

int clampPim(int value) {
  if (value < 0) return 0;
  if (value > 2000) return 2000;
  return value;
}

// ── lru_cache.dart ──────────────────────────────────────────────────────────



class LruCache<K, V> {
  final int capacity;
  final _map = LinkedHashMap<K, V>();

  LruCache(this.capacity) : assert(capacity > 0, 'capacity must be > 0');

  V? operator [](K key) {
    if (!_map.containsKey(key)) return null;
    final val = _map.remove(key) as V;
    _map[key] = val;
    return val;
  }

  void operator []=(K key, V value) {
    _map.remove(key);
    _map[key] = value;
    while (_map.length > capacity) {
      _map.remove(_map.keys.first);
    }
  }

  bool containsKey(K key) => _map.containsKey(key);
  void remove(K key) => _map.remove(key);
  void clear() => _map.clear();
  int get length => _map.length;
}

// ── sort_mixin.dart (compareItems logic, extracted as a pure function) ───────

enum SortBy { name, size, extension }

int compareItems(String a, String b, SortBy sortBy, bool sortAscending) {
  String nameOf(String raw) =>
      raw.startsWith('[DIR] ') ? raw.replaceFirst('[DIR] ', '') : raw.split('|').first;

  int sizeOf(String raw) {
    if (raw.startsWith('[DIR] ')) return 0;
    final p = raw.split('|');
    return p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0;
  }

  final aName = nameOf(a), bName = nameOf(b);
  int result;
  switch (sortBy) {
    case SortBy.name:
      result = aName.toLowerCase().compareTo(bName.toLowerCase());
      break;
    case SortBy.size:
      result = sizeOf(a).compareTo(sizeOf(b));
      break;
    case SortBy.extension:
      String extOf(String n) =>
          n.contains('.') ? n.split('.').last.toLowerCase() : '';
      result = extOf(aName).compareTo(extOf(bName));
      if (result == 0) result = aName.toLowerCase().compareTo(bName.toLowerCase());
      break;
  }
  return sortAscending ? result : -result;
}

// ── file_browser_screen.dart (makeUniqueName, extracted as a pure function) ──

String makeUniqueName(String fileName, Set<String> existingNames) {
  if (!existingNames.contains(fileName.toLowerCase())) return fileName;
  final dotIdx = fileName.lastIndexOf('.');
  final name   = dotIdx != -1 ? fileName.substring(0, dotIdx) : fileName;
  final ext    = dotIdx != -1 ? fileName.substring(dotIdx) : '';
  for (int i = 1; i < 9999; i++) {
    final candidate = '$name ($i)$ext';
    if (!existingNames.contains(candidate.toLowerCase())) return candidate;
  }
  return '$fileName-${DateTime.now().millisecondsSinceEpoch}';
}

// ===========================================================================
// Tests
// ===========================================================================

void main() {
  // ── formatBytes ────────────────────────────────────────────────────────────

  group('formatBytes', () {
    test('zero or negative returns "0 B"', () {
      expect(formatBytes(0),  '0 B');
      expect(formatBytes(-1), '0 B');
    });

    test('bytes below 1 KB', () {
      expect(formatBytes(1),   '1 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(999), '999 B');
    });

    test('kilobytes', () {
      expect(formatBytes(1024),       '1.0 KB');
      expect(formatBytes(1536),       '1.5 KB');
      expect(formatBytes(10 * 1024),  '10 KB');
      expect(formatBytes(100 * 1024), '100 KB');
    });

    test('megabytes', () {
      expect(formatBytes(1024 * 1024),         '1.0 MB');
      expect(formatBytes((4.2 * 1024 * 1024).round()), '4.2 MB');
      expect(formatBytes(10 * 1024 * 1024),    '10 MB');
    });

    test('gigabytes', () {
      expect(formatBytes(1024 * 1024 * 1024),       '1.0 GB');
      expect(formatBytes(10 * 1024 * 1024 * 1024),  '10 GB');
    });

    test('values just below a boundary stay in smaller unit', () {
      // 1023 bytes should not be shown as KB
      expect(formatBytes(1023), '1023 B');
    });

    test('values just above a boundary cross to larger unit', () {
      expect(formatBytes(1025), '1.0 KB');
    });
  });

  // ── clampPim ───────────────────────────────────────────────────────────────

  group('clampPim', () {
    test('zero passes through', () => expect(clampPim(0), 0));
    test('positive value in range passes through', () {
      expect(clampPim(1),    1);
      expect(clampPim(1000), 1000);
      expect(clampPim(2000), 2000);
    });
    test('negative value is clamped to 0', () {
      expect(clampPim(-1),         0);
      expect(clampPim(-1000000),   0);
    });
    test('value above 2000 is clamped to 2000', () {
      expect(clampPim(2001),       2000);
      expect(clampPim(2000000),    2000);
      expect(clampPim(2000000000), 2000);
    });
    test('boundary values are exact', () {
      expect(clampPim(1999), 1999);
      expect(clampPim(2000), 2000);
      expect(clampPim(2001), 2000);
    });
  });

  // ── LruCache ───────────────────────────────────────────────────────────────

  group('LruCache', () {
    test('stores and retrieves a value', () {
      final cache = LruCache<String, int>(3);
      cache['a'] = 1;
      expect(cache['a'], 1);
    });

    test('returns null for missing key', () {
      final cache = LruCache<String, int>(3);
      expect(cache['missing'], isNull);
    });

    test('evicts the least-recently-used entry when over capacity', () {
      final cache = LruCache<String, int>(3);
      cache['a'] = 1;
      cache['b'] = 2;
      cache['c'] = 3;
      // 'a' is LRU; adding 'd' should evict 'a'
      cache['d'] = 4;
      expect(cache['a'], isNull);
      expect(cache['b'], 2);
      expect(cache['c'], 3);
      expect(cache['d'], 4);
    });

    test('accessing a key promotes it to most-recent', () {
      final cache = LruCache<String, int>(3);
      cache['a'] = 1;
      cache['b'] = 2;
      cache['c'] = 3;
      // Access 'a' to make it the most-recent
      expect(cache['a'], 1);
      // Now 'b' is LRU; adding 'd' should evict 'b'
      cache['d'] = 4;
      expect(cache['a'], 1);
      expect(cache['b'], isNull);
      expect(cache['c'], 3);
      expect(cache['d'], 4);
    });

    test('overwriting an existing key updates value without growing cache', () {
      final cache = LruCache<String, int>(3);
      cache['a'] = 1;
      cache['b'] = 2;
      cache['c'] = 3;
      cache['a'] = 99;
      expect(cache.length, 3);
      expect(cache['a'], 99);
    });

    test('remove deletes a key', () {
      final cache = LruCache<String, int>(2);
      cache['x'] = 10;
      cache.remove('x');
      expect(cache['x'], isNull);
      expect(cache.length, 0);
    });

    test('clear empties the cache', () {
      final cache = LruCache<String, int>(5);
      cache['a'] = 1;
      cache['b'] = 2;
      cache.clear();
      expect(cache.length, 0);
      expect(cache['a'], isNull);
    });

    test('capacity-1 cache evicts on every insertion after first', () {
      final cache = LruCache<String, int>(1);
      cache['a'] = 1;
      cache['b'] = 2;
      expect(cache['a'], isNull);
      expect(cache['b'], 2);
    });

    test('containsKey reflects presence correctly', () {
      final cache = LruCache<String, int>(3);
      cache['a'] = 1;
      expect(cache.containsKey('a'), isTrue);
      expect(cache.containsKey('z'), isFalse);
    });
  });

  // ── compareItems (sort logic) ──────────────────────────────────────────────

  group('compareItems — sort by name', () {
    test('alphabetical ascending', () {
      expect(compareItems('apple.txt|100', 'banana.txt|50', SortBy.name, true), isNegative);
      expect(compareItems('banana.txt|50', 'apple.txt|100', SortBy.name, true), isPositive);
      expect(compareItems('same.txt|10', 'same.txt|20', SortBy.name, true), isZero);
    });

    test('alphabetical descending reverses order', () {
      expect(compareItems('apple.txt|100', 'banana.txt|50', SortBy.name, false), isPositive);
    });

    test('case-insensitive', () {
      expect(compareItems('Apple.txt|0', 'apple.txt|0', SortBy.name, true), isZero);
    });

    test('directories use name without [DIR] prefix', () {
      expect(compareItems('[DIR] alpha', '[DIR] beta', SortBy.name, true), isNegative);
    });
  });

  group('compareItems — sort by size', () {
    test('smaller size comes first in ascending order', () {
      expect(compareItems('a.txt|100', 'b.txt|200', SortBy.size, true), isNegative);
      expect(compareItems('a.txt|200', 'b.txt|100', SortBy.size, true), isPositive);
    });

    test('directories always have size 0', () {
      expect(compareItems('[DIR] folder', 'file.txt|0', SortBy.size, true), isZero);
    });

    test('descending reverses', () {
      expect(compareItems('a.txt|100', 'b.txt|200', SortBy.size, false), isPositive);
    });
  });

  group('compareItems — sort by extension', () {
    test('groups by extension', () {
      expect(compareItems('a.jpg|0', 'b.mp4|0', SortBy.extension, true), isNegative);
      expect(compareItems('a.zip|0', 'b.jpg|0', SortBy.extension, true), isPositive);
    });

    test('same extension falls back to name sort', () {
      expect(compareItems('apple.jpg|0', 'banana.jpg|0', SortBy.extension, true), isNegative);
    });

    test('files without extension are treated as empty string extension', () {
      // Empty string sorts before any letter
      expect(compareItems('noext|0', 'file.jpg|0', SortBy.extension, true), isNegative);
    });
  });

  // ── makeUniqueName ─────────────────────────────────────────────────────────

  group('makeUniqueName', () {
    test('returns original name when no conflict', () {
      expect(makeUniqueName('report.pdf', {'other.pdf'}), 'report.pdf');
    });

    test('appends (1) on first conflict', () {
      expect(makeUniqueName('report.pdf', {'report.pdf'}), 'report (1).pdf');
    });

    test('increments suffix until unique', () {
      expect(
        makeUniqueName('report.pdf', {'report.pdf', 'report (1).pdf', 'report (2).pdf'}),
        'report (3).pdf',
      );
    });

    test('works for files without extension', () {
      expect(makeUniqueName('notes', {'notes'}), 'notes (1)');
    });

    test('conflict detection is case-insensitive', () {
      // 'Report.pdf' conflicts with 'report.pdf' in the set
      expect(makeUniqueName('Report.pdf', {'report.pdf'}), 'Report (1).pdf');
    });

    test('no conflict when set is empty', () {
      expect(makeUniqueName('file.txt', {}), 'file.txt');
    });

    test('handles multi-dot filenames correctly — only last dot is the extension', () {
      // 'my.backup.tar' → name='my.backup', ext='.tar'
      expect(
        makeUniqueName('my.backup.tar', {'my.backup.tar'}),
        'my.backup (1).tar',
      );
    });
  });
}