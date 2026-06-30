import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../models/mounted_container.dart';
import '../../../models/thumbnail_cache_mode.dart';
import '../../../services/thumbnail_cache_service.dart';
import '../../../services/vaultexplorer_api.dart';
import '../../../utils/file_type_utils.dart';
import '../../../utils/lru_cache.dart';
import '../../../utils/raw_entry.dart';

/// A dynamic gallery grid for the file browser supporting pinch-to-zoom.
class FileGridView extends StatefulWidget {
  final MountedContainer container;
  final List<String> dirs;
  final List<String> files;
  final bool isSelectionMode;
  final Set<String> selectedItems;
  final String currentDirPath;
  final ThumbnailCacheMode thumbnailCacheMode;
  final ValueChanged<String> onDirTap;
  final ValueChanged<String> onFileTap;
  final ValueChanged<String> onItemLongPress;
  final ValueChanged<String>? onFileLongMenu;

  const FileGridView({
    super.key,
    required this.container,
    required this.dirs,
    required this.files,
    required this.isSelectionMode,
    required this.selectedItems,
    required this.currentDirPath,
    required this.thumbnailCacheMode,
    required this.onDirTap,
    required this.onFileTap,
    required this.onItemLongPress,
    this.onFileLongMenu,
  });

  @override
  State<FileGridView> createState() => _FileGridViewState();
}

class _FileGridViewState extends State<FileGridView> {
  static const _imageExts = {'jpg', 'jpeg', 'png', 'webp', 'gif'};
  static const _videoExts = {'mp4', 'm4v', 'webm', 'mov', 'avi', 'mkv'};

  int _crossAxisCount = 3;
  double _baselineScale = 1.0;

  bool _isImage(String name) {
    final dot = name.lastIndexOf('.');
    if (dot == -1) return false;
    return _imageExts.contains(name.substring(dot + 1).toLowerCase());
  }

  bool _isVideo(String name) {
    final dot = name.lastIndexOf('.');
    if (dot == -1) return false;
    return _videoExts.contains(name.substring(dot + 1).toLowerCase());
  }

  double _getAspectRatio(int columns) {
    switch (columns) {
      case 1:
        return 1.45;
      case 2:
        return 0.95;
      case 3:
      default:
        return 0.74;
    }
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _baselineScale = 1.0;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    final scale = details.scale;
    final factor = scale / _baselineScale;

    if (factor > 1.35) {
      if (_crossAxisCount > 1) {
        setState(() {
          _crossAxisCount--;
          _baselineScale = scale;
        });
      }
    } else if (factor < 0.75) {
      if (_crossAxisCount < 3) {
        setState(() {
          _crossAxisCount++;
          _baselineScale = scale;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.dirs.length + widget.files.length;

    return GestureDetector(
      onScaleStart: _handleScaleStart,
      onScaleUpdate: _handleScaleUpdate,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _crossAxisCount,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: _getAspectRatio(_crossAxisCount),
        ),
        itemCount: total,
        itemBuilder: (context, index) {
          if (index < widget.dirs.length) {
            return _buildDirCell(context, widget.dirs[index]);
          }
          return _buildFileCell(
            context,
            widget.files[index - widget.dirs.length],
          );
        },
      ),
    );
  }

  Widget _buildDirCell(BuildContext context, String rawItem) {
    final name = RawEntry.parse(rawItem).name;
    final isSelected = widget.selectedItems.contains(rawItem);
    final cs = Theme.of(context).colorScheme;

    return _GridCell(
      isSelected: isSelected,
      isSelectionMode: widget.isSelectionMode,
      onTap: () => widget.onDirTap(rawItem),
      onLongPress: () => widget.onItemLongPress(rawItem),
      preview: Center(
        child: Icon(
          Icons.folder_rounded,
          size: _crossAxisCount == 1 ? 72 : 56,
          color: isSelected ? cs.primary : cs.secondary,
        ),
      ),
      label: name,
    );
  }

  Widget _buildFileCell(BuildContext context, String rawItem) {
    final parts = rawItem.split('|');
    final cleanName = parts.first;
    final fileSize = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final fullPath = widget.currentDirPath.isEmpty
        ? cleanName
        : '${widget.currentDirPath}/$cleanName';
    final isSelected = widget.selectedItems.contains(rawItem);

    final isImg = _isImage(cleanName);
    final isVid = _isVideo(cleanName);

    Widget previewWidget;
    if (isImg) {
      previewWidget = _EncryptedImageGridThumb(
        container: widget.container,
        filePath: fullPath,
        cacheMode: widget.thumbnailCacheMode,
      );
    } else if (isVid) {
      previewWidget = _VideoThumb(
        container: widget.container,
        filePath: fullPath,
        cacheMode: widget.thumbnailCacheMode,
      );
    } else {
      previewWidget = Center(
        child: Icon(
          iconForFile(cleanName),
          size: _crossAxisCount == 1 ? 52 : 40,
          color: colorForFile(cleanName),
        ),
      );
    }

    return _GridCell(
      isSelected: isSelected,
      isSelectionMode: widget.isSelectionMode,
      onTap: () => widget.onFileTap(rawItem),
      onLongPress: () => widget.onItemLongPress(rawItem),
      onMoreTap: widget.isSelectionMode
          ? null
          : () => widget.onFileLongMenu?.call(rawItem),
      preview: previewWidget,
      label: cleanName,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Generic grid cell
// ─────────────────────────────────────────────────────────────────────────────

class _GridCell extends StatelessWidget {
  final Widget preview;
  final String label;
  final String? sublabel;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onMoreTap;

  const _GridCell({
    required this.preview,
    required this.label,
    this.sublabel,
    required this.isSelected,
    required this.isSelectionMode,
    required this.onTap,
    required this.onLongPress,
    this.onMoreTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: isSelected
              ? cs.primaryContainer.withValues(alpha: 0.3)
              : cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? cs.primary : cs.outlineVariant,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    preview,
                    if (isSelected)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.12),
                        ),
                        child: Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: _CheckBadge(
                              color: cs.primary,
                              onColor: cs.onPrimary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                color: isSelected
                    ? cs.primaryContainer.withValues(alpha: 0.3)
                    : cs.surfaceContainer,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                    ),
                    if (sublabel != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        sublabel!,
                        style: textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckBadge extends StatelessWidget {
  final Color color;
  final Color onColor;
  const _CheckBadge({required this.color, required this.onColor});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: Icon(Icons.check_rounded, size: 12, color: onColor),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Generic async thumbnail loader
// ─────────────────────────────────────────────────────────────────────────────

typedef _FetchFn = Future<Uint8List> Function(MountedContainer, String);
typedef _SyncLookup = Uint8List? Function();

class _AsyncThumb extends StatefulWidget {
  final MountedContainer container;
  final String filePath;
  final LruCache<String, Future<Uint8List>> cache;
  final ConcurrencyLimiter limiter;
  final _FetchFn fetchFn;
  final Duration debounce;
  final _SyncLookup? syncLookup;

  const _AsyncThumb({
    required Key key,
    required this.container,
    required this.filePath,
    required this.cache,
    required this.limiter,
    required this.fetchFn,
    this.debounce = const Duration(milliseconds: 100),
    this.syncLookup,
  }) : super(key: key);

  @override
  State<_AsyncThumb> createState() => _AsyncThumbState();
}

class _AsyncThumbState extends State<_AsyncThumb> {
  Uint8List? _bytes;
  bool _isLoading = true;
  bool _hasError = false;

  Completer<void>? _limiterCompleter;
  String? _loadingPath;

  // FIX P9: Track whether this widget instance has been disposed so we can
  // avoid calling setState after disposal even when the native fetch completes.
  bool _disposed = false;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    final syncBytes = widget.syncLookup?.call();
    if (syncBytes != null) {
      _bytes = syncBytes;
      _isLoading = false;
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(_AsyncThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _cancel();
      final syncBytes = widget.syncLookup?.call();
      if (syncBytes != null) {
        setState(() {
          _bytes = syncBytes;
          _isLoading = false;
          _hasError = false;
        });
      } else {
        setState(() {
          _bytes = null;
          _isLoading = true;
          _hasError = false;
        });
        _load();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel();
    super.dispose();
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  void _cancel() {
    if (_limiterCompleter != null) {
      widget.limiter.cancel(_limiterCompleter!);
      _limiterCompleter = null;
    }
    // FIX P9: Clearing _loadingPath signals in-flight async continuations to
    // abandon their work as early as possible — the path guard check
    // `targetPath != _loadingPath` below now fires as soon as dispose() runs,
    // rather than only after the limiter wait completes.
    _loadingPath = null;
  }

  Future<void> _load() async {
    final targetPath = widget.filePath;
    _loadingPath = targetPath;
    final cacheKey =
        '${widget.container.volId}:${widget.container.mountedAt.millisecondsSinceEpoch}:$targetPath';

    var future = widget.cache[cacheKey];

    if (future == null) {
      if (mounted) {
        setState(() {
          _isLoading = true;
          _hasError = false;
        });
      }

      await Future.delayed(widget.debounce);
      if (targetPath != _loadingPath || !mounted || _disposed) return;

      final syncBytes = widget.syncLookup?.call();
      if (syncBytes != null) {
        if (mounted && !_disposed) {
          setState(() {
            _bytes = syncBytes;
            _isLoading = false;
          });
        }
        return;
      }

      future = widget.cache[cacheKey];
      if (future == null) {
        future = _fetchWithQueue(widget.container, targetPath).then(
          (data) => data,
          onError: (err) {
            if (widget.cache[cacheKey] == future) {
              widget.cache.remove(cacheKey);
            }
            throw err;
          },
        );
        widget.cache[cacheKey] = future;
      }
    }

    try {
      final data = await future;
      if (targetPath != _loadingPath || !mounted || _disposed) return;
      setState(() {
        _bytes = data;
        _isLoading = false;
      });
    } catch (_) {
      if (targetPath == _loadingPath && mounted && !_disposed) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  Future<Uint8List> _fetchWithQueue(
    MountedContainer container,
    String targetPath,
  ) async {
    final completer = Completer<void>();
    _limiterCompleter = completer;
    bool acquired = false;

    try {
      await widget.limiter.acquire(completer);
      acquired = true;

      // FIX P9: Check disposed state after acquiring the limiter slot —
      // the widget may have been disposed while waiting in the queue.
      if (targetPath != _loadingPath || !mounted || _disposed) {
        throw Exception('Cancelled before processing');
      }

      return await widget.fetchFn(container, targetPath);
    } finally {
      if (_limiterCompleter == completer) _limiterCompleter = null;
      if (acquired) widget.limiter.release();
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Container(
        color: cs.surfaceContainerLow,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: cs.primary.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
    }
    if (_hasError || _bytes == null || _bytes!.isEmpty) {
      return _errorPlaceholder(cs);
    }
    return Image.memory(
      _bytes!,
      fit: BoxFit.cover,
      cacheHeight: 180,
      errorBuilder: (_, __, ___) => _errorPlaceholder(cs),
    );
  }

  Widget _errorPlaceholder(ColorScheme cs) => Container(
    color: cs.surfaceContainerLow,
    child: Center(
      child: Icon(Icons.broken_image_rounded, size: 28, color: cs.outline),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Encrypted image thumbnail
// ─────────────────────────────────────────────────────────────────────────────

class _EncryptedImageGridThumb extends StatelessWidget {
  static final _cache = LruCache<String, Future<Uint8List>>(60);
  static final _limiter = ConcurrencyLimiter(2);

  final MountedContainer container;
  final String filePath;
  final ThumbnailCacheMode cacheMode;

  const _EncryptedImageGridThumb({
    required this.container,
    required this.filePath,
    required this.cacheMode,
  });

  static Future<Uint8List> _fetch(
    MountedContainer container,
    String path,
    ThumbnailCacheMode mode,
  ) async {
    if (mode != ThumbnailCacheMode.disabled) {
      final cached = await ThumbnailCacheService.get(
        container: container,
        filePath: path,
        mode: mode,
      );
      if (cached != null && cached.isNotEmpty) return cached;
    }

    Uint8List? thumbBytes = await vaultExplorerApi.getImageThumbnail(
      container,
      path,
      targetSize: 180,
    );

    if (thumbBytes == null || thumbBytes.isEmpty) {
      final size = await vaultExplorerApi.getFileSize(container, path);
      if (size <= 0) throw Exception('Empty file: $path');
      final raw = await vaultExplorerApi.readFileChunk(
        container,
        path,
        0,
        size,
      );
      if (raw == null || raw.isEmpty) throw Exception('Read failed: $path');
      if (raw.length < 200 * 1024) {
        ThumbnailCacheService.putInMemory(container, path, raw);
      }
      return raw;
    }

    ThumbnailCacheService.putInMemory(container, path, thumbBytes);
    if (mode != ThumbnailCacheMode.disabled) {
      unawaited(
        ThumbnailCacheService.put(
          container: container,
          filePath: path,
          data: thumbBytes,
          mode: mode,
        ),
      );
    }

    return thumbBytes;
  }

  @override
  Widget build(BuildContext context) => _AsyncThumb(
    key: ValueKey('img:$filePath'),
    container: container,
    filePath: filePath,
    cache: _cache,
    limiter: _limiter,
    fetchFn: (c, p) => _fetch(c, p, cacheMode),
    debounce: const Duration(milliseconds: 100),
    syncLookup: () => ThumbnailCacheService.getFromMemory(container, filePath),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Video thumbnail
// ─────────────────────────────────────────────────────────────────────────────

class _VideoThumb extends StatelessWidget {
  static final _cache = LruCache<String, Future<Uint8List>>(100);
  static final _limiter = ConcurrencyLimiter(1);

  final MountedContainer container;
  final String filePath;
  final ThumbnailCacheMode cacheMode;

  const _VideoThumb({
    required this.container,
    required this.filePath,
    required this.cacheMode,
  });

  static Future<Uint8List> _fetch(
    MountedContainer container,
    String path,
    ThumbnailCacheMode mode,
  ) async {
    if (mode != ThumbnailCacheMode.disabled) {
      final cached = await ThumbnailCacheService.get(
        container: container,
        filePath: path,
        mode: mode,
      );
      if (cached != null && cached.isNotEmpty) return cached;
    }

    final data = await vaultExplorerApi.getVideoThumbnail(container, path);
    if (data == null || data.isEmpty) return Uint8List(0);

    ThumbnailCacheService.putInMemory(container, path, data);
    if (mode != ThumbnailCacheMode.disabled) {
      unawaited(
        ThumbnailCacheService.put(
          container: container,
          filePath: path,
          data: data,
          mode: mode,
        ),
      );
    }

    return data;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Stack(
      fit: StackFit.expand,
      children: [
        _AsyncThumb(
          key: ValueKey('vid:$filePath'),
          container: container,
          filePath: filePath,
          cache: _cache,
          limiter: _limiter,
          fetchFn: (c, p) => _fetch(c, p, cacheMode),
          debounce: const Duration(milliseconds: 150),
          syncLookup: () =>
              ThumbnailCacheService.getFromMemory(container, filePath),
        ),
        Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.all(6.0),
            child: Icon(
              Icons.play_circle_outline_rounded,
              size: 16,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ConcurrencyLimiter
// ─────────────────────────────────────────────────────────────────────────────

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

  // FIX P8: The original while loop contained a `return` inside the body,
  // meaning it could only ever drain one waiter per release() call regardless
  // of how many concurrent slots opened up. This was harmless for
  // maxConcurrency=1 but misleading and wrong for higher values.
  //
  // The corrected version drains as many waiters as there are free slots,
  // skipping already-completed (cancelled) completers without burning a slot.
  void _drainNext() {
    while (_waiting.isNotEmpty && _running < maxConcurrency) {
      final next = _waiting.removeLast();
      if (next.isCompleted) {
        // This completer was cancelled while waiting — skip it and try the next
        // one without consuming a concurrency slot.
        continue;
      }
      _running++;
      next.complete();
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper — suppress lint for intentional fire-and-forget futures
// ─────────────────────────────────────────────────────────────────────────────

void unawaited(Future<void> future) {
  future.catchError((Object e) {
    debugPrint('unawaited error (non-fatal): $e');
  });
}
