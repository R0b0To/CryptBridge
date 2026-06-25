import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../models/mounted_container.dart';
import '../../../services/vaultexplorer_api.dart';
import '../../../utils/file_type_utils.dart';
import '../../../utils/format_utils.dart';

/// A 3-column gallery grid for the file browser.
///
/// Image and video files render as live thumbnails loaded natively from memory 
/// and content providers without relying on a local HTTP port.
class FileGridView extends StatelessWidget {
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

  static const _imageExts = {'jpg', 'jpeg', 'png', 'webp', 'gif'};
  static const _videoExts = {'mp4', 'm4v', 'webm', 'mov', 'avi', 'mkv'};

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

  @override
  Widget build(BuildContext context) {
    final total = dirs.length + files.length;

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.76,
      ),
      itemCount: total,
      itemBuilder: (context, index) {
        if (index < dirs.length) return _buildDirCell(context, dirs[index]);
        return _buildFileCell(context, files[index - dirs.length]);
      },
    );
  }

  // ── Directory cell ──────────────────────────────────────────────────────────

  Widget _buildDirCell(BuildContext context, String rawItem) {
    final name = rawItem.replaceFirst('[DIR] ', '');
    final isSelected = selectedItems.contains(rawItem);

    return _GridCell(
      isSelected: isSelected,
      isSelectionMode: isSelectionMode,
      onTap: () => onDirTap(rawItem),
      onLongPress: () => onItemLongPress(rawItem),
      preview: const Center(
        child: Icon(Icons.folder_rounded, size: 52, color: Color(0xFFFFA726)),
      ),
      label: name,
    );
  }

  // ── File cell ───────────────────────────────────────────────────────────────

  Widget _buildFileCell(BuildContext context, String rawItem) {
    final parts = rawItem.split('|');
    final cleanName = parts.first;
    final fileSize = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final fullPath =
        currentDirPath.isEmpty ? cleanName : '$currentDirPath/$cleanName';
    final isSelected = selectedItems.contains(rawItem);

    final isImg = _isImage(cleanName);
    final isVid = _isVideo(cleanName);

    Widget previewWidget;
    if (isImg) {
      previewWidget = _EncryptedImageGridThumb(
        container: container,
        filePath: fullPath,
      );
    } else if (isVid) {
      // Replaced contentUrl construction with direct parameter passing:
      previewWidget = _VideoNetworkThumb(
        container: container,
        filePath: fullPath,
      );
    } else {
      previewWidget = Center(
        child: Icon(
          iconForFile(cleanName),
          size: 40,
          color: colorForFile(cleanName),
        ),
      );
    }

    return _GridCell(
      isSelected: isSelected,
      isSelectionMode: isSelectionMode,
      onTap: () => onFileTap(rawItem),
      onLongPress: () => onItemLongPress(rawItem),
      onMoreTap:
          isSelectionMode ? null : () => onFileLongMenu?.call(rawItem),
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
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: isSelected
              ? cs.primaryContainer.withOpacity(0.4)
              : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? cs.primary : cs.outline.withOpacity(0.35),
            width: isSelected ? 1.5 : 0.5,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(7.5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Preview area ───────────────────────────────────────────────
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    preview,

                    // Selection tint + check badge
                    if (isSelected)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: cs.primary.withOpacity(0.16),
                        ),
                        child: Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                            padding: const EdgeInsets.all(5),
                            child: _CheckBadge(
                                color: cs.primary, onColor: cs.onPrimary),
                          ),
                        ),
                      ),

                  ],
                ),
              ),

              // ── Label area ─────────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 5),
                color: isSelected
                    ? cs.primaryContainer.withOpacity(0.4)
                    : cs.surface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                        letterSpacing: 0.1,
                      ),
                    ),
                    if (sublabel != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        sublabel!,
                        style: TextStyle(fontSize: 9, color: cs.outline),
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
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(Icons.check, size: 11, color: onColor),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Encrypted JNI Image Thumbnail Loader with downscaling (Prevents OOM)
// ─────────────────────────────────────────────────────────────────────────────

class _EncryptedImageGridThumb extends StatefulWidget {
  final MountedContainer container;
  final String filePath;

  const _EncryptedImageGridThumb({
    required this.container,
    required this.filePath,
  });

  @override
  State<_EncryptedImageGridThumb> createState() => _EncryptedImageGridThumbState();
}

class _EncryptedImageGridThumbState extends State<_EncryptedImageGridThumb> {
  // Static memory cache so thumbnail allocations persist while scrolling
  static final Map<String, Uint8List> _imageThumbCache = {};

  Uint8List? _bytes;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(_EncryptedImageGridThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    final cacheKey = '${widget.container.volId}:${widget.filePath}';
    if (_imageThumbCache.containsKey(cacheKey)) {
      if (mounted) {
        setState(() {
          _bytes = _imageThumbCache[cacheKey];
          _isLoading = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
        _hasError = false;
      });
    }

    try {
      final size = await vaultExplorerApi.getFileSize(widget.container, widget.filePath);
      if (size <= 0) throw Exception('File is empty');

      final data = await vaultExplorerApi.readFileChunk(
        widget.container,
        widget.filePath,
        0,
        size,
      );

      if (data == null || data.isEmpty) throw Exception('No content bytes read');

      _imageThumbCache[cacheKey] = data;
      if (mounted) {
        setState(() {
          _bytes = data;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Failed loading image thumbnail: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Container(
        color: cs.surfaceContainerHighest,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: cs.primary.withOpacity(0.6),
            ),
          ),
        ),
      );
    }

    if (_hasError || _bytes == null) {
      return Container(
        color: cs.surfaceContainerHighest,
        child: Center(
          child: Icon(Icons.broken_image_outlined, size: 28, color: cs.outline),
        ),
      );
    }

    return Image.memory(
      _bytes!,
      fit: BoxFit.cover,
      // Downscale decoded image structure in GPU memory to prevent memory overhead
      cacheHeight: 180, 
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Content URI Video Thumbnail Generation (Zero-Server)
// ─────────────────────────────────────────────────────────────────────────────

class _VideoNetworkThumb extends StatefulWidget {
  final MountedContainer container;
  final String filePath;

  const _VideoNetworkThumb({
    required this.container,
    required this.filePath,
  });

  @override
  State<_VideoNetworkThumb> createState() => _VideoNetworkThumbState();
}

class _VideoNetworkThumbState extends State<_VideoNetworkThumb> {
  // Static memory cache so standard thumbnails persist during scroll recycle actions
  static final Map<String, Uint8List> _videoThumbCache = {};

  Uint8List? _bytes;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _fetchVideoFrame();
  }

  @override
  void didUpdateWidget(_VideoNetworkThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _fetchVideoFrame();
    }
  }

  Future<void> _fetchVideoFrame() async {
    final cacheKey = '${widget.container.volId}:${widget.filePath}';
    if (_videoThumbCache.containsKey(cacheKey)) {
      if (mounted) {
        setState(() {
          _bytes = _videoThumbCache[cacheKey];
          _isLoading = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
        _hasError = false;
      });
    }

    try {
      final data = await vaultExplorerApi.getVideoThumbnail(
        widget.container,
        widget.filePath,
      );

      if (data == null || data.isEmpty) throw Exception('No frame bytes received');

      _videoThumbCache[cacheKey] = data;
      if (mounted) {
        setState(() {
          _bytes = data;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Native Video thumbnail generation error: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Container(
        color: cs.surfaceContainerHighest,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: cs.primary.withOpacity(0.6),
            ),
          ),
        ),
      );
    }

    if (_hasError || _bytes == null) {
      return Container(
        color: cs.surfaceContainerHighest,
        child: Center(
          child: Icon(Icons.play_circle_outline, size: 32, color: cs.outline),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(
          _bytes!,
          fit: BoxFit.cover,
          cacheHeight: 180, // Memory footprint optimization
        ),
        Container(
          color: Colors.black.withOpacity(0.12),
          child: const Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: EdgeInsets.all(6.0),
              child: Icon(
                Icons.play_circle_outline,
                size: 16,
                color: Colors.white70,
              ),
            ),
          ),
        ),
      ],
    );
  }
}