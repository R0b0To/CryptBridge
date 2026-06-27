import 'dart:collection';

/// A fixed-capacity cache that evicts the least-recently-used entry when full.
///
/// Backed by a [LinkedHashMap] whose insertion order tracks recency.
/// Every [operator []] call that hits promotes the entry to most-recent.
class LruCache<K, V> {
  final int capacity;
  final _map = LinkedHashMap<K, V>();

  LruCache(this.capacity) : assert(capacity > 0, 'capacity must be > 0');

  /// Returns the value for [key], promoting it to most-recent, or null if absent.
  V? operator [](K key) {
    if (!_map.containsKey(key)) return null;
    // Remove and re-insert to promote to tail (most-recent).
    final val = _map.remove(key) as V;
    _map[key] = val;
    return val;
  }

  /// Stores [value] under [key], evicting the oldest entry if over capacity.
  void operator []=(K key, V value) {
    _map.remove(key); // remove first so re-insertion lands at tail
    _map[key] = value;
    while (_map.length > capacity) {
      _map.remove(_map.keys.first); // evict head (= least recent)
    }
  }

  bool containsKey(K key) => _map.containsKey(key);

  void remove(K key) => _map.remove(key);

  void clear() => _map.clear();

  int get length => _map.length;
}