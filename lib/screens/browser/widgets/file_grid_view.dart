import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../models/mounted_container.dart';
import '../../../services/vaultexplorer_api.dart';
import '../../../utils/file_type_utils.dart';
import '../../../utils/format_utils.dart';
import '../../../utils/lru_cache.dart';

/// A dynamic gallery grid for the file browser supporting pinch-to-zoom column sizes.
class FileGridView extends StatefulWidget {
  final MountedContainer container;
  final List<String> dirs;
  final List<String> files;
  final bool isSelectionMode;
  final Set<String> selectedItems;

  /// FAT path of the current directory (empty string at root).
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

  /// Calculates dynamic aspect ratios so cards retain proper proportions 
  /// across 1, 2, and 3 column modes.
  double _getAspectRatio(int columns) {
    switch (columns) {
      case 1:
        return 1.45; // Landscape card
      case 2:
        return 0.95; // Square-ish card
      case 3:
      default:
        return 0.74; // Compact vertical card
    }
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _baselineScale = 1.0;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    final scale = details.scale;
    final factor = scale / _baselineScale;

    // Fingers moving apart -> Make cards bigger (fewer columns)
    if (factor > 1.35) {
      if (_crossAxisCount > 1) {
        setState(() {
          _crossAxisCount--;
          _baselineScale = scale; // Reset baseline for step-by-step feedback
        });
      }
    } 
    // Fingers moving together -> Make cards smaller (more columns)
    else if (factor < 0.75) {
      if (_crossAxisCount < 3) {
        setState(() {
          _crossAxisCount++;
          _baselineScale = scale; // Reset baseline
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
          return _buildFileCell(context, widget.files[index - widget.dirs.length]);
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
    final parts    = rawItem.split('|');
    final cleanName = parts.first;
    final fileSize  = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final fullPath  =
        widget.currentDirPath.isEmpty ? cleanName : '${widget.currentDirPath}/$cleanName';
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
      onMoreTap: widget.isSelectionMode ? null : () => widget.onFileLongMenu?.call(rawItem),
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
                                color: cs.primary, onColor: cs.onPrimary),
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
                            fontWeight: FontWeight.w600, color: cs.onSurface)),
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
// Encrypted image thumbnail loader
// ─────────────────────────────────────────────────────────────────────────────

class _EncryptedImageGridThumb extends StatefulWidget {
  final MountedContainer container;
  final String filePath;

  const _EncryptedImageGridThumb({
    required this.container,
    required this.filePath,
  });

  @override
  State<_EncryptedImageGridThumb> createState() =>
      _EncryptedImageGridThumbState();
}

class _EncryptedImageGridThumbState extends State<_EncryptedImageGridThumb> {
  static final _imageThumbCache = LruCache<String, Future<Uint8List>>(60);
  static final _imageDecoderLimiter = ConcurrencyLimiter(3);

  Uint8List? _bytes;
  bool _isLoading = true;
  bool _hasError  = false;

  Completer<void>? _limiterCompleter;
  String? _loadingPath;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(_EncryptedImageGridThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _cancelPendingLoad();
      _loadImage();
    }
  }

  @override
  void dispose() {
    _cancelPendingLoad();
    super.dispose();
  }

  void _cancelPendingLoad() {
    if (_limiterCompleter != null) {
      _imageDecoderLimiter.cancel(_limiterCompleter!);
      _limiterCompleter = null;
    }
    _loadingPath = null;
  }

  Future<void> _loadImage() async {
    final targetPath = widget.filePath;
    _loadingPath = targetPath;
    final cacheKey = '${widget.container.volId}:$targetPath';

    // 1. Instant Cache Hit Check (Synchronous)
    var future = _imageThumbCache[cacheKey];

    if (future == null) {
      if (mounted) {
        setState(() {
          _isLoading = true;
          _hasError = false;
        });
      }

      // 2. Debounce Delay (Skip processing if scrolling quickly)
      await Future.delayed(const Duration(milliseconds: 100));
      if (targetPath != _loadingPath || !mounted) return;

      // Double-check cache in case another cell initiated the load during the delay
      future = _imageThumbCache[cacheKey];
      if (future == null) {
        future = _fetchImageBytesWithQueue(widget.container, targetPath);
        _imageThumbCache[cacheKey] = future;
      }
    }

    try {
      final data = await future;
      
      // 3. Recycling Guard
      if (targetPath != _loadingPath || !mounted) return;

      setState(() {
        _bytes = data;
        _isLoading = false;
      });
    } catch (e) {
      if (targetPath == _loadingPath) {
        _imageThumbCache.remove(cacheKey);
        debugPrint('Failed loading image thumbnail: $e');
        
        if (mounted) {
          setState(() {
            _isLoading = false;
            _hasError = true;
          });
        }
      }
    }
  }

  Future<Uint8List> _fetchImageBytesWithQueue(MountedContainer container, String targetPath) async {
    final completer = Completer<void>();
    _limiterCompleter = completer;

    bool acquired = false;
    try {
      await _imageDecoderLimiter.acquire(completer);
      acquired = true;

      if (targetPath != _loadingPath || !mounted) {
        throw Exception('Cancelled before processing');
      }

      final size = await vaultExplorerApi.getFileSize(container, targetPath);
      if (size <= 0) throw Exception('File is empty');

      final data = await vaultExplorerApi.readFileChunk(container, targetPath, 0, size);
      if (data == null || data.isEmpty) throw Exception('No bytes read');
      return data;
    } finally {
      if (_limiterCompleter == completer) {
        _limiterCompleter = null;
      }
      if (acquired) {
        _imageDecoderLimiter.release();
      }
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
                strokeWidth: 1.5, color: cs.primary.withOpacity(0.6)),
          ),
        ),
      );
    }
    if (_hasError || _bytes == null) {
      return Container(
        color: cs.surfaceContainerLow,
        child: Center(
            child: Icon(Icons.broken_image_rounded, size: 28, color: cs.outline)),
      );
    }
    return Image.memory(_bytes!, fit: BoxFit.cover, cacheHeight: 180);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Video thumbnail loader
// ─────────────────────────────────────────────────────────────────────────────

class _VideoThumb extends StatefulWidget {
  final MountedContainer container;
  final String filePath;

  const _VideoThumb({required this.container, required this.filePath});

  @override
  State<_VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<_VideoThumb> {
  static final _videoThumbCache = LruCache<String, Future<Uint8List>>(100);
  static final _videoDecoderLimiter = ConcurrencyLimiter(1);

  Uint8List? _bytes;
  bool _isLoading = true;
  bool _hasError  = false;

  Completer<void>? _limiterCompleter;
  String? _loadingPath;

  @override
  void initState() {
    super.initState();
    _fetchVideoFrame();
  }

  @override
  void didUpdateWidget(_VideoThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _cancelPendingLoad();
      _fetchVideoFrame();
    }
  }

  @override
  void dispose() {
    _cancelPendingLoad();
    super.dispose();
  }

  void _cancelPendingLoad() {
    if (_limiterCompleter != null) {
      _videoDecoderLimiter.cancel(_limiterCompleter!);
      _limiterCompleter = null;
    }
    _loadingPath = null;
  }

  Future<void> _fetchVideoFrame() async {
    final targetPath = widget.filePath;
    _loadingPath = targetPath;
    final cacheKey = '${widget.container.volId}:$targetPath';

    var future = _videoThumbCache[cacheKey];

    if (future == null) {
      if (mounted) {
        setState(() {
          _isLoading = true;
          _hasError = false;
        });
      }

      await Future.delayed(const Duration(milliseconds: 150));
      if (targetPath != _loadingPath || !mounted) return;

      future = _videoThumbCache[cacheKey];
      if (future == null) {
        future = _fetchVideoBytesWithQueue(widget.container, targetPath);
        _videoThumbCache[cacheKey] = future;
      }
    }

    try {
      final data = await future;
      if (targetPath != _loadingPath || !mounted) return;

      if (data.isEmpty) {
        setState(() {
          _bytes = null;
          _isLoading = false;
          _hasError = true;
        });
      } else {
        setState(() {
          _bytes = data;
          _isLoading = false;
          _hasError = false;
        });
      }
    } catch (e) {
      if (targetPath == _loadingPath) {
        _videoThumbCache.remove(cacheKey);
        if (mounted) {
          setState(() {
            _isLoading = false;
            _hasError = true;
          });
        }
      }
    }
  }

  Future<Uint8List> _fetchVideoBytesWithQueue(MountedContainer container, String targetPath) async {
    final completer = Completer<void>();
    _limiterCompleter = completer;

    bool acquired = false;
    try {
      await _videoDecoderLimiter.acquire(completer);
      acquired = true;

      if (targetPath != _loadingPath || !mounted) {
        throw Exception('Cancelled before processing');
      }

      final data = await vaultExplorerApi.getVideoThumbnail(container, targetPath);
      if (data == null || data.isEmpty) {
        return Uint8List(0);
      }
      return data;
    } catch (e) {
      if (e.toString().contains('Cancelled')) {
        rethrow;
      }
      debugPrint('Video thumbnail extraction error for $targetPath: $e');
      return Uint8List(0);
    } finally {
      if (_limiterCompleter == completer) {
        _limiterCompleter = null;
      }
      if (acquired) {
        _videoDecoderLimiter.release();
      }
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
                strokeWidth: 1.5, color: cs.primary.withOpacity(0.6)),
          ),
        ),
      );
    }
    if (_hasError || _bytes == null || _bytes!.isEmpty) {
      return Container(
        color: cs.surfaceContainerLow,
        child: Center(
            child: Icon(Icons.play_circle_outline_rounded,
                size: 32, color: cs.outline)),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(_bytes!, fit: BoxFit.cover, cacheHeight: 180),
        Container(
          color: Colors.black.withOpacity(0.12),
          child: const Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: EdgeInsets.all(6.0),
              child: Icon(Icons.play_circle_outline_rounded,
                  size: 16, color: Colors.white70),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Concurrency Limiter
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
    try {
      await completer.future;
    } catch (_) {
      rethrow;
    }
  }

  void cancel(Completer<void> completer) {
    if (_waiting.remove(completer)) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('Cancelled in queue'));
      }
    }
  }

  void release() {
    _running--;
    if (_running < 0) {
      _running = 0;
    }
    _processNext();
  }

  void _processNext() {
    while (_running < maxConcurrency && _waiting.isNotEmpty) {
      _running++;
      final next = _waiting.removeLast();
      if (!next.isCompleted) {
        next.complete();
      } else {
        _running--;
      }
    }
  }
}