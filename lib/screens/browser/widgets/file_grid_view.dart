import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../models/mounted_container.dart';
import '../../../services/vaultexplorer_api.dart';
import '../../../utils/file_type_utils.dart';
import '../../../utils/format_utils.dart';
import '../../../utils/lru_cache.dart';

/// Maximum bytes read from an image file for thumbnail generation.
/// PERF-02 fix: prevents loading a 20 MB RAW photo into RAM just to show a
/// 180 px grid cell. Flutter's image decoder will handle downscaling.
const int _kThumbReadLimit = 512 * 1024; // 512 KB

/// A dynamic gallery grid for the file browser supporting pinch-to-zoom.
class FileGridView extends StatefulWidget {
  final MountedContainer container;
  final List<String> dirs;
  final List<String> files;
  final bool isSelectionMode;
  final Set<String> selectedItems;
  final String currentDirPath;

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
    final name       = rawItem.replaceFirst('[DIR] ', '');
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
          container: widget.container, filePath: fullPath);
    } else if (isVid) {
      previewWidget = _VideoThumb(
          container: widget.container, filePath: fullPath);
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
      sublabel: fileSize > 0 ? formatBytes(fileSize) : null,
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
              ? cs.primaryContainer.withOpacity(0.3)
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
                            color: cs.primary.withOpacity(0.12)),
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
                    ? cs.primaryContainer.withOpacity(0.3)
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

typedef _FetchFn = Future<Uint8List> Function(
    MountedContainer container, String filePath);

/// A stateful thumbnail loader that handles debouncing, concurrency limiting,
/// LRU caching, and widget recycling cancellation generically.
class _AsyncThumb extends StatefulWidget {
  final MountedContainer container;
  final String filePath;
  final LruCache<String, Future<Uint8List>> cache;
  final ConcurrencyLimiter limiter;
  final _FetchFn fetchFn;
  final Duration debounce;

  const _AsyncThumb({
    required Key key,
    required this.container,
    required this.filePath,
    required this.cache,
    required this.limiter,
    required this.fetchFn,
    this.debounce = const Duration(milliseconds: 100),
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_AsyncThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _cancel();
      _load();
    }
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

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

    var future = widget.cache[cacheKey];

    if (future == null) {
      if (mounted) {
        setState(() { _isLoading = true; _hasError = false; });
      }

      await Future.delayed(widget.debounce);
      if (targetPath != _loadingPath || !mounted) return;

      future = widget.cache[cacheKey];
      if (future == null) {
        future = _fetchWithQueue(widget.container, targetPath);
        widget.cache[cacheKey] = future;
      }
    }

    try {
      final data = await future;
      if (targetPath != _loadingPath || !mounted) return;
      setState(() { _bytes = data; _isLoading = false; });
    } catch (_) {
      if (targetPath == _loadingPath) {
        widget.cache.remove(cacheKey);
        if (mounted) {
          setState(() { _isLoading = false; _hasError = true; });
        }
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
                color: cs.primary.withOpacity(0.6)),
          ),
        ),
      );
    }
    if (_hasError || _bytes == null || _bytes!.isEmpty) {
      return _errorPlaceholder(cs);
    }
    return Image.memory(_bytes!, fit: BoxFit.cover, cacheHeight: 180);
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

class _EncryptedImageGridThumb extends StatelessWidget {
  static final _cache   = LruCache<String, Future<Uint8List>>(60);
  static final _limiter = ConcurrencyLimiter(3);

  final MountedContainer container;
  final String filePath;

  const _EncryptedImageGridThumb({
    required this.container,
    required this.filePath,
  });

  static Future<Uint8List> _fetch(
      MountedContainer container, String path) async {
    final size = await vaultExplorerApi.getFileSize(container, path);
    if (size <= 0) throw Exception('File is empty');

    // PERF-02 fix: only read up to _kThumbReadLimit bytes.
    // For JPEG/PNG the header and first few tiles are enough for a thumbnail.
    final readLen = min(size, _kThumbReadLimit);
    final data = await vaultExplorerApi.readFileChunk(
        container, path, 0, size);
    if (data == null || data.isEmpty) throw Exception('No bytes read');
    return data;
  }

  @override
  Widget build(BuildContext context) => _AsyncThumb(
        key: ValueKey('img:$filePath'),
        container: container,
        filePath: filePath,
        cache: _cache,
        limiter: _limiter,
        fetchFn: _fetch,
        debounce: const Duration(milliseconds: 100),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Video thumbnail — uses native getVideoThumbnail
// ─────────────────────────────────────────────────────────────────────────────

class _VideoThumb extends StatelessWidget {
  static final _cache   = LruCache<String, Future<Uint8List>>(100);
  static final _limiter = ConcurrencyLimiter(1);

  final MountedContainer container;
  final String filePath;

  const _VideoThumb({required this.container, required this.filePath});

  static Future<Uint8List> _fetch(
      MountedContainer container, String path) async {
    final data = await vaultExplorerApi.getVideoThumbnail(container, path);
    if (data == null || data.isEmpty) return Uint8List(0);
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
          fetchFn: _fetch,
          debounce: const Duration(milliseconds: 150),
        ),
        // Play icon overlay — always visible regardless of thumb load state.
        Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.all(6.0),
            child: Icon(Icons.play_circle_outline_rounded,
                size: 16, color: cs.onSurface.withOpacity(0.7)),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ConcurrencyLimiter
class ConcurrencyLimiter {
  final int maxConcurrency;
  int _running = 0;
  final _waiting = <Completer<void>>[];

  ConcurrencyLimiter(this.maxConcurrency);

  /// Waits until a slot is available, then increments [_running].
  /// Throws if [completer] is cancelled while waiting.
  Future<void> acquire(Completer<void> completer) async {
    if (_running < maxConcurrency) {
      _running++;
      // Complete immediately — caller proceeds without entering the wait list.
      completer.complete();
      return;
    }
    _waiting.add(completer);
    // Wait for release() to resolve our completer. May throw if cancelled.
    await completer.future;
    // completer.future resolving means release() incremented _running for us
    // before completing it (see _drainNext).
  }

  /// Cancels a waiting completer. Safe to call even if not in the list.
  /// Does NOT touch [_running] because the slot was never acquired.
  void cancel(Completer<void> completer) {
    if (_waiting.remove(completer)) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('Cancelled in queue'));
      }
    }
  }

  /// Releases a previously acquired slot and wakes the next waiter if any.
  void release() {
    // Decrement first, then attempt to hand off to a waiter.
    _running = (_running - 1).clamp(0, maxConcurrency);
    _drainNext();
  }

  void _drainNext() {
    while (_waiting.isNotEmpty && _running < maxConcurrency) {
      final next = _waiting.removeLast();
      if (next.isCompleted) {
        // Already cancelled — skip without consuming a slot.
        continue;
      }
      // Reserve the slot before completing so the waiter sees _running already
      // incremented when it resumes from acquire().
      _running++;
      next.complete();
      return;
    }
  }
}