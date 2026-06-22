import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:get_thumbnail_video/index.dart';
import 'package:get_thumbnail_video/video_thumbnail.dart';
import '../../../utils/file_type_utils.dart';
import '../../../utils/format_utils.dart';

/// A 3-column gallery grid for the file browser.
///
/// Image and video files render as live thumbnails streamed from [streamingServerPort].
/// Directories and other files render their colour-coded type icons.
class FileGridView extends StatelessWidget {
  final List<String> dirs;
  final List<String> files;
  final bool isSelectionMode;
  final Set<String> selectedItems;

  /// FAT path of the current directory (empty string at root).
  final String currentDirPath;

  /// Port of the local streaming server; thumbnails are disabled when null.
  final int? streamingServerPort;

  final ValueChanged<String> onDirTap;
  final ValueChanged<String> onFileTap;
  final ValueChanged<String> onItemLongPress;
  final ValueChanged<String>? onFileLongMenu;

  const FileGridView({
    super.key,
    required this.dirs,
    required this.files,
    required this.isSelectionMode,
    required this.selectedItems,
    required this.currentDirPath,
    this.streamingServerPort,
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
    final canThumb = (isImg || isVid) && streamingServerPort != null;

    final thumbUrl = canThumb
        ? 'http://127.0.0.1:$streamingServerPort/media'
            '?file=${Uri.encodeQueryComponent(fullPath)}'
        : null;

    Widget previewWidget;
    if (thumbUrl != null) {
      if (isImg) {
        previewWidget = _NetworkThumb(url: thumbUrl);
      } else {
        previewWidget = _VideoNetworkThumb(url: thumbUrl);
      }
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
// Network thumbnail with progressive loading
// ─────────────────────────────────────────────────────────────────────────────

class _NetworkThumb extends StatelessWidget {
  final String url;
  const _NetworkThumb({required this.url});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Image.network(
      url,
      fit: BoxFit.cover,
      cacheHeight: 240,
      loadingBuilder: (_, child, progress) {
        if (progress == null) return child;
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
      },
      errorBuilder: (_, __, ___) => Container(
        color: cs.surfaceContainerHighest,
        child: Icon(Icons.broken_image_outlined, size: 28, color: cs.outline),
      ),
    );
  }
}

class _VideoNetworkThumb extends StatefulWidget {
  final String url;
  const _VideoNetworkThumb({required this.url});

  @override
  State<_VideoNetworkThumb> createState() => _VideoNetworkThumbState();
}

class _VideoNetworkThumbState extends State<_VideoNetworkThumb> {
  // Static cache so thumbnail memory persists when scrolling away and back
  static final Map<String, Uint8List> _thumbCache = {};

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
    if (oldWidget.url != widget.url) {
      _fetchVideoFrame();
    }
  }

  Future<void> _fetchVideoFrame() async {
    if (_thumbCache.containsKey(widget.url)) {
      if (mounted) {
        setState(() {
          _bytes = _thumbCache[widget.url];
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
      // In version 0.7.2, thumbnailData returns a non-nullable Future<Uint8List>.
      // Any internal error or failure to decode the frame throws an exception 
      // which is caught by the try-catch block.
      final data = await VideoThumbnail.thumbnailData(
        video: widget.url,
        imageFormat: ImageFormat.WEBP,
        maxHeight: 180, // Bound size to lower memory footprint
        quality: 60,
      );

      _thumbCache[widget.url] = data;
      if (mounted) {
        setState(() {
          _bytes = data;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Video thumbnail generation error: $e');
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
        ),
        // Overlay a semi-transparent play icon to indicate a video file
        Container(
          color: Colors.black.withOpacity(0.15),
          child: const Center(
            child: Icon(
              Icons.play_circle_filled,
              size: 28,
              color: Colors.white70,
            ),
          ),
        ),
      ],
    );
  }
}