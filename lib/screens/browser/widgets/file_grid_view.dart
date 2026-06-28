import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../models/mounted_container.dart';
import '../../../models/thumbnail_cache_mode.dart';
import '../../../services/thumbnail_cache_service.dart';
import '../../../services/vaultexplorer_api.dart';
import '../../../utils/file_type_utils.dart';
import '../../../utils/format_utils.dart';
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
      case 1:  return 1.45;
      case 2:  return 0.95;
      case 3:
      default: return 0.74;
    }
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _baselineScale = 1.0;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    final scale  = details.scale;
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
              context, widget.files[index - widget.dirs.length]);
        },
      ),
    );
  }

  Widget _buildDirCell(BuildContext context, String rawItem) {
    final name = RawEntry.parse(rawItem).name;
    final isSelected = widget.selectedItems.contains(rawItem);
    final cs         = Theme.of(context).colorScheme;

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
    final parts     = rawItem.split('|');
    final cleanName = parts.first;
    final fileSize  = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final fullPath  = widget.currentDirPath.isEmpty
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
    final cs        = Theme.of(context).colorScheme;
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
                            color: cs.primary.withValues(alpha: 0.12)),
                        child: Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: _CheckBadge(
                                color: cs.primary,
                                onColor: cs.onPrimary),
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
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface)),
                    if (sublabel != null) ...[
                      const SizedBox(height: 2),
                      Text(sublabel!,
                          style: textTheme.labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant)),
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

typedef _FetchFn   = Future<Uint8List> Function(MountedContainer, String);

/// Optional synchronous callback checked before entering the async pipeline.
///
/// If it returns non-null bytes the widget displays the image immediately —
/// no loading state, no setState call, no frame of spinner.  Used to query
/// [ThumbnailCacheService.getFromMemory] at widget construction time.
typedef _SyncLookup = Uint8List? Function();

class _AsyncThumb extends StatefulWidget {
  final MountedContainer container;
  final String filePath;
  final LruCache<String, Future<Uint8List>> cache;
  final ConcurrencyLimiter limiter;
  final _FetchFn fetchFn;
  final Duration debounce;

  /// Checked synchronously in [initState] and [didUpdateWidget].
  /// Returning non-null skips the entire async pipeline for that render cycle.
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
  bool _hasError  = false;

  Completer<void>? _limiterCompleter;
  String? _loadingPath;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // FIX: Synchronous memory-cache check before any async work.
    // If the bytes are already in Tier 1 memory, display immediately — no
    // loading spinner, no setState, no async scheduling overhead.
    final syncBytes = widget.syncLookup?.call();
    if (syncBytes != null) {
      _bytes    = syncBytes;
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
      // FIX: Check memory cache for the new path before resetting to loading.
      final syncBytes = widget.syncLookup?.call();
      if (syncBytes != null) {
        setState(() {
          _bytes     = syncBytes;
          _isLoading = false;
          _hasError  = false;
        });
      } else {
        setState(() {
          _bytes     = null;
          _isLoading = true;
          _hasError  = false;
        });
        _load();
      }
    }
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  void _cancel() {
    if (_limiterCompleter != null) {
      widget.limiter.cancel(_limiterCompleter!);
      _limiterCompleter = null;
    }
    _loadingPath = null;
  }

  Future<void> _load() async {
    final targetPath = widget.filePath;
    _loadingPath     = targetPath;
    final cacheKey   = '${widget.container.volId}:$targetPath';

    // ── Check the Future-LRU cache (request deduplication) ────────────────
    // Multiple widgets requesting the same path share a single in-flight Future
    // so the underlying fetch runs only once regardless of how many cells
    // scroll into view simultaneously.
    var future = widget.cache[cacheKey];

    if (future == null) {
      if (mounted) {
        setState(() { _isLoading = true; _hasError = false; });
      }

      // Debounce: items that scroll away within this window never trigger a
      // fetch at all.
      await Future.delayed(widget.debounce);
      if (targetPath != _loadingPath || !mounted) return;

      // FIX: Re-check memory cache after debounce.  If a sibling widget
      // finished loading this thumbnail during the debounce window, the bytes
      // are now in Tier 1 — skip the fetch entirely.
      final syncBytes = widget.syncLookup?.call();
      if (syncBytes != null) {
        if (mounted) setState(() { _bytes = syncBytes; _isLoading = false; });
        return;
      }

      // Re-check Future cache (another widget may have created the Future
      // during the debounce window).
      future = widget.cache[cacheKey];
      if (future == null) {
        future = _fetchWithQueue(widget.container, targetPath).then(
          (data) => data,
          onError: (err) {
            // Evict stale failed Future so the next attempt retries cleanly.
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
      if (targetPath != _loadingPath || !mounted) return;
      setState(() { _bytes = data; _isLoading = false; });
    } catch (_) {
      if (targetPath == _loadingPath && mounted) {
        setState(() { _isLoading = false; _hasError = true; });
      }
    }
  }

  Future<Uint8List> _fetchWithQueue(
      MountedContainer container, String targetPath) async {
    final completer  = Completer<void>();
    _limiterCompleter = completer;
    bool acquired    = false;

    try {
      await widget.limiter.acquire(completer);
      acquired = true;

      if (targetPath != _loadingPath || !mounted) {
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
            width: 18, height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: cs.primary.withValues(alpha: 0.6)),
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
      cacheHeight: 180, // Let Flutter cache the decoded bitmap at display size.
      errorBuilder: (_, __, ___) => _errorPlaceholder(cs),
    );
  }

  Widget _errorPlaceholder(ColorScheme cs) => Container(
        color: cs.surfaceContainerLow,
        child: Center(
            child: Icon(Icons.broken_image_rounded,
                size: 28, color: cs.outline)),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Encrypted image thumbnail
// ─────────────────────────────────────────────────────────────────────────────

class _EncryptedImageGridThumb extends StatelessWidget {
  // Shared across all instances — deduplicates in-flight requests and keeps
  // resolved Futures alive for the lifetime of the widget tree.
  static final _cache   = LruCache<String, Future<Uint8List>>(60);
  static final _limiter = ConcurrencyLimiter(2);

  final MountedContainer container;
  final String filePath;
  final ThumbnailCacheMode cacheMode;

  const _EncryptedImageGridThumb({
    required this.container,
    required this.filePath,
    required this.cacheMode,
  });

  /// Full three-tier fetch:
  ///
  ///  1. Tier 1 — memory (via syncLookup in _AsyncThumb, not reached here)
  ///  2. Tier 2 — disk (delegated to ThumbnailCacheService.get)
  ///  3. Tier 3 — native [getImageThumbnail]:
  ///     Uses Android BitmapFactory with inSampleSize subsampling, scales to
  ///     the target size, and JPEG-compresses.  Returns ~15 KB over JNI instead
  ///     of the raw multi-MB source file.
  ///
  /// FIX: the old code called readFileChunk() on cache miss, transferring the
  /// entire source file (potentially 5–10 MB) over the JNI bridge just to
  /// display a 180×180 thumbnail.  getImageThumbnail() does the downscale
  /// natively and transfers ~300–500× less data for identical visual output.
  ///
  /// FIX: _triggerBackgroundThumbnailGen() (the old fire-and-forget native
  /// write) has been removed.  Thumbnails are generated inline on the cache-
  /// miss path and written to disk immediately via ThumbnailCacheService.put().
  /// This eliminates a competing native decode/encode/write that was previously
  /// running *during* scroll for every cache miss.
  static Future<Uint8List> _fetch(
    MountedContainer container,
    String path,
    ThumbnailCacheMode mode,
  ) async {
    // Tier 2 — disk / in-container.
    // (Tier 1 is already checked synchronously by syncLookup before _fetch
    //  is ever called, but ThumbnailCacheService.get also guards it internally.)
    if (mode != ThumbnailCacheMode.disabled) {
      final cached = await ThumbnailCacheService.get(
          container: container, filePath: path, mode: mode);
      if (cached != null && cached.isNotEmpty) return cached;
      // Note: get() calls putInMemory() on a hit, so Tier 1 is now populated.
    }

    // Tier 3 — generate via native Android subsampled decode.
    Uint8List? thumbBytes =
        await vaultExplorerApi.getImageThumbnail(container, path, targetSize: 180);

    // Fallback: raw file read for unsupported/corrupt images.
    // Full-res bytes are intentionally *not* stored in the memory cache to
    // avoid blowing the ~2.4 MB budget with a single large image.
    if (thumbBytes == null || thumbBytes.isEmpty) {
      final size = await vaultExplorerApi.getFileSize(container, path);
      if (size <= 0) throw Exception('Empty file: $path');
      final raw =
          await vaultExplorerApi.readFileChunk(container, path, 0, size);
      if (raw == null || raw.isEmpty) throw Exception('Read failed: $path');
      // Only cache small files in memory (icons, screenshots).  Large files
      // (>200 KB) stay in the LRU-Future cache only to cap memory usage.
      if (raw.length < 200 * 1024) {
        ThumbnailCacheService.putInMemory(container, path, raw);
      }
      return raw;
    }

    // Cache the generated thumbnail: memory immediately, disk asynchronously.
    ThumbnailCacheService.putInMemory(container, path, thumbBytes);
    if (mode != ThumbnailCacheMode.disabled) {
      unawaited(ThumbnailCacheService.put(
          container: container, filePath: path, data: thumbBytes, mode: mode));
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
        // FIX: Synchronous fast-path.  If bytes are already in Tier 1 memory,
        // the widget displays the image in initState — no loading state, no
        // setState, no async scheduling.
        syncLookup: () =>
            ThumbnailCacheService.getFromMemory(container, filePath),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Video thumbnail
// ─────────────────────────────────────────────────────────────────────────────

class _VideoThumb extends StatelessWidget {
  static final _cache   = LruCache<String, Future<Uint8List>>(100);
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
    // Tier 2 — disk / in-container.
    if (mode != ThumbnailCacheMode.disabled) {
      final cached = await ThumbnailCacheService.get(
          container: container, filePath: path, mode: mode);
      if (cached != null && cached.isNotEmpty) return cached;
    }

    // Tier 3 — native video frame extraction.
    final data = await vaultExplorerApi.getVideoThumbnail(container, path);
    if (data == null || data.isEmpty) return Uint8List(0);

    // Cache: memory immediately, disk asynchronously.
    ThumbnailCacheService.putInMemory(container, path, data);
    if (mode != ThumbnailCacheMode.disabled) {
      unawaited(ThumbnailCacheService.put(
          container: container, filePath: path, data: data, mode: mode));
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
            child: Icon(Icons.play_circle_outline_rounded,
                size: 16,
                color: cs.onSurface.withValues(alpha: 0.7)),
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

  void _drainNext() {
    while (_waiting.isNotEmpty && _running < maxConcurrency) {
      final next = _waiting.removeLast();
      if (next.isCompleted) continue;
      _running++;
      next.complete();
      return;
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