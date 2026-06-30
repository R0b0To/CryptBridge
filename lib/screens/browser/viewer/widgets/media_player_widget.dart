import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '/../../models/mounted_container.dart';
import '/../../services/vaultexplorer_api.dart';
import '../media_viewer_constants.dart';

// Highly optimized, fine-grained model updating isolated nodes
class VideoPlaybackProgress {
  final Duration position;
  final Duration duration;
  final double sliderValue;
  final bool isDragging;

  const VideoPlaybackProgress({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.sliderValue = 0.0,
    this.isDragging = false,
  });

  VideoPlaybackProgress copyWith({
    Duration? position,
    Duration? duration,
    double? sliderValue,
    bool? isDragging,
  }) {
    final currentDragging = isDragging ?? this.isDragging;
    final currentDuration = duration ?? this.duration;
    final currentPosition = position ?? this.position;

    double computedSlider = 0.0;
    if (currentDragging) {
      computedSlider = sliderValue ?? this.sliderValue;
    } else if (currentDuration.inMilliseconds > 0) {
      computedSlider =
          currentPosition.inMilliseconds / currentDuration.inMilliseconds;
    }

    return VideoPlaybackProgress(
      position: currentPosition,
      duration: currentDuration,
      sliderValue: computedSlider,
      isDragging: currentDragging,
    );
  }
}

class MediaPlayerWidget extends StatefulWidget {
  final MountedContainer container;
  final String fileName;
  final String contentUriString;
  final bool showUI;
  final ValueChanged<bool> onToggleUI;
  final ValueChanged<bool> onZoomChanged;
  final int skipSeconds;
  final bool autoPlay;
  final bool isAudio;
  final bool subtitlesEnabled;
  final int rotationQuarterTurns;
  final ValueChanged<bool> onSubtitlesAvailableChanged;
  final ValueChanged<VideoPlayerController> onVideoControllerInitialized;
  final VoidCallback onVideoControllerDisposed;
  final ValueNotifier<VideoPlaybackProgress> progressNotifier;

  const MediaPlayerWidget({
    Key? key,
    required this.container,
    required this.fileName,
    required this.contentUriString,
    required this.showUI,
    required this.onToggleUI,
    required this.onZoomChanged,
    required this.skipSeconds,
    required this.autoPlay,
    required this.isAudio,
    required this.subtitlesEnabled,
    required this.rotationQuarterTurns,
    required this.onSubtitlesAvailableChanged,
    required this.onVideoControllerInitialized,
    required this.onVideoControllerDisposed,
    required this.progressNotifier,
  }) : super(key: key);

  @override
  State<MediaPlayerWidget> createState() => _MediaPlayerWidgetState();
}

class _MediaPlayerWidgetState extends State<MediaPlayerWidget> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  String? _playerError;

  bool _showLeftIndicator = false;
  bool _showRightIndicator = false;
  bool _isSpeedHeld = false;

  final TransformationController _videoTransformationController =
      TransformationController();
  double _videoScale = 1.0;
  TapDownDetails? _videoDoubleTapDetails;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    _controller = VideoPlayerController.contentUri(
      Uri.parse(widget.contentUriString),
    );

    _controller.addListener(_onControllerTick);

    try {
      final captionFile = await _loadCaptions(widget.fileName);
      if (captionFile != null && mounted) {
        _controller.setClosedCaptionFile(Future.value(captionFile));
      }
      await _controller.initialize();
      if (mounted) {
        setState(() => _initialized = true);
        widget.onVideoControllerInitialized(_controller);
        await _controller.setVolume(1.0);
        await _controller.setLooping(false);
        if (widget.autoPlay) {
          _controller.play();
          //widget.onToggleUI(false);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _playerError = 'Media stream initialization failed: $e');
      }
    }
  }

  void _onControllerTick() {
    if (!mounted || !_initialized) return;

    // Updates the progressNotifier instead of triggering a full widget setState() rebuild
    widget.progressNotifier.value = widget.progressNotifier.value.copyWith(
      position: _controller.value.position,
      duration: _controller.value.duration,
    );
  }

  Future<ClosedCaptionFile?> _loadCaptions(String videoPath) async {
    final dotIndex = videoPath.lastIndexOf('.');
    if (dotIndex == -1) return null;
    final basePath = videoPath.substring(0, dotIndex);

    for (final ext in ['srt', 'vtt']) {
      final subPath = '$basePath.$ext';
      try {
        final size = await vaultExplorerApi.getFileSize(
          widget.container,
          subPath,
        );
        if (size > 0) {
          final data = await vaultExplorerApi.readFileChunk(
            widget.container,
            subPath,
            0,
            size,
          );
          if (data != null && data.isNotEmpty) {
            final text = utf8.decode(data, allowMalformed: true);
            widget.onSubtitlesAvailableChanged(true);
            return ext == 'srt'
                ? SubRipCaptionFile(text)
                : WebVTTCaptionFile(text);
          }
        }
      } catch (_) {}
    }
    widget.onSubtitlesAvailableChanged(false);
    return null;
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerTick);
    widget.onVideoControllerDisposed();
    _videoTransformationController.dispose();
    try {
      _controller.dispose();
    } catch (_) {}
    super.dispose();
  }

  void _onSpeedHoldStart(LongPressStartDetails _) {
    if (!_initialized) return;
    HapticFeedback.heavyImpact();
    _controller.setPlaybackSpeed(2.0);
    setState(() => _isSpeedHeld = true);
  }

  void _onSpeedHoldEnd(LongPressEndDetails _) {
    if (!_initialized) return;
    _controller.setPlaybackSpeed(1.0);
    setState(() => _isSpeedHeld = false);
  }

  void _handleVideoDoubleTap() {
    if (widget.isAudio) return;
    final position = _videoDoubleTapDetails?.localPosition;
    setState(() {
      if (_videoScale == 1.0) {
        _videoScale = 2.2;
        if (position != null) {
          final x = -position.dx * (_videoScale - 1);
          final y = -position.dy * (_videoScale - 1);
          _videoTransformationController.value = Matrix4.identity()
            ..translate(x, y)
            ..scale(_videoScale);
        } else {
          _videoTransformationController.value = Matrix4.identity()
            ..scale(_videoScale);
        }
        widget.onZoomChanged(false);
      } else {
        _videoScale = 1.0;
        _videoTransformationController.value = Matrix4.identity();
        widget.onZoomChanged(true);
      }
    });
  }

  void _skip({required bool backwards}) {
    HapticFeedback.lightImpact();
    widget.onToggleUI(true);
    final currentPos = _controller.value.position;
    final duration = _controller.value.duration;
    final targetPos = backwards
        ? currentPos - Duration(seconds: widget.skipSeconds)
        : currentPos + Duration(seconds: widget.skipSeconds);
    final clampedPos = targetPos < Duration.zero
        ? Duration.zero
        : (targetPos > duration ? duration : targetPos);
    _controller.seekTo(clampedPos);

    setState(() {
      if (backwards) {
        _showLeftIndicator = true;
      } else {
        _showRightIndicator = true;
      }
    });

    Timer(MediaViewerConstants.doubleTapIndicatorDelay, () {
      if (mounted) {
        setState(() {
          _showLeftIndicator = false;
          _showRightIndicator = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_playerError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, color: cs.error, size: 36),
              const SizedBox(height: 12),
              Text(
                _playerError!,
                style: TextStyle(color: cs.error, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (!_initialized) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
        ),
      );
    }

    final isRotated = widget.rotationQuarterTurns % 2 != 0;
    final double computedAspectRatio = widget.isAudio
        ? 0.8
        : (isRotated
              ? 1.0 / _controller.value.aspectRatio
              : _controller.value.aspectRatio);

    Widget corePlayerWidget = Center(
      child: AspectRatio(
        aspectRatio: computedAspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (widget.isAudio)
              _buildAudioCenterVisual(cs)
            else
              RotatedBox(
                quarterTurns: widget.rotationQuarterTurns,
                child: VideoPlayer(_controller),
              ),
            if (!widget.isAudio && widget.subtitlesEnabled)
              Positioned(
                bottom: widget.showUI ? 130 : 25,
                left: 20,
                right: 20,
                child: ValueListenableBuilder<VideoPlaybackProgress>(
                  valueListenable: widget.progressNotifier,
                  builder: (context, progress, child) {
                    return ClosedCaption(
                      text: _controller.value.caption.text,
                      textStyle: const TextStyle(
                        fontSize: 15,
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            blurRadius: 4,
                            color: Colors.black,
                            offset: Offset(1, 1),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => widget.onToggleUI(!widget.showUI),
                    onDoubleTap: () => _skip(backwards: true),
                    onLongPressStart: _onSpeedHoldStart,
                    onLongPressEnd: _onSpeedHoldEnd,
                    child: Container(),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => widget.onToggleUI(!widget.showUI),
                    onDoubleTapDown: (d) => _videoDoubleTapDetails = d,
                    onDoubleTap: _handleVideoDoubleTap,
                    onLongPressStart: _onSpeedHoldStart,
                    onLongPressEnd: _onSpeedHoldEnd,
                    child: Container(),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => widget.onToggleUI(!widget.showUI),
                    onDoubleTap: () => _skip(backwards: false),
                    onLongPressStart: _onSpeedHoldStart,
                    onLongPressEnd: _onSpeedHoldEnd,
                    child: Container(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (!widget.isAudio) {
      corePlayerWidget = InteractiveViewer(
        transformationController: _videoTransformationController,
        maxScale: MediaViewerConstants.maxVideoZoom,
        minScale: 1.0,
        clipBehavior: Clip.none,
        onInteractionUpdate: (details) {
          final s = _videoTransformationController.value.getMaxScaleOnAxis();
          if (s != _videoScale) {
            setState(() => _videoScale = s);
            widget.onZoomChanged(s <= 1.01);
          }
        },
        onInteractionEnd: (details) {
          final s = _videoTransformationController.value.getMaxScaleOnAxis();
          if (s <= 1.01) widget.onZoomChanged(true);
        },
        child: corePlayerWidget,
      );
    }

    return ClipRect(
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          corePlayerWidget,
          if (_showLeftIndicator)
            _buildIndicator(
              Icons.fast_rewind_rounded,
              '-${widget.skipSeconds}s',
              true,
            ),
          if (_showRightIndicator)
            _buildIndicator(
              Icons.fast_forward_rounded,
              '+${widget.skipSeconds}s',
              false,
            ),
          if (_isSpeedHeld)
            Positioned(
              top: 100,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: cs.primary.withValues(alpha: 0.6),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.fast_forward_rounded,
                        color: cs.primary,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '2× speed',
                        style: TextStyle(
                          color: cs.primary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildIndicator(IconData icon, String text, bool isLeft) {
    return Positioned(
      left: isLeft ? 45 : null,
      right: isLeft ? null : 45,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(30),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 28),
              const SizedBox(height: 4),
              Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAudioCenterVisual(ColorScheme cs) {
    final fileTitle = widget.fileName.split('/').last;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 130,
          height: 130,
          decoration: BoxDecoration(
            color: const Color(0xFF161B22),
            shape: BoxShape.circle,
            border: Border.all(
              color: cs.primary.withValues(alpha: 0.25),
              width: 2,
            ),
          ),
          child: Center(
            child: Icon(Icons.music_note_rounded, size: 56, color: cs.primary),
          ),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Text(
            fileTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 24),
        _AudioVisualizer(isPlaying: _controller.value.isPlaying),
      ],
    );
  }
}

class _AudioVisualizer extends StatefulWidget {
  final bool isPlaying;
  const _AudioVisualizer({Key? key, required this.isPlaying}) : super(key: key);

  @override
  State<_AudioVisualizer> createState() => _AudioVisualizerState();
}

class _AudioVisualizerState extends State<_AudioVisualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<double> _heights = [0.2, 0.5, 0.8, 0.4, 0.9, 0.3, 0.7, 0.5, 0.2];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    if (widget.isPlaying) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _AudioVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isPlaying && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 50,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) => Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(_heights.length, (index) {
            double animValue = _controller.value;
            double factor = (index % 3 == 0)
                ? (animValue * 0.8 + 0.2)
                : (index % 3 == 1)
                ? ((1.0 - animValue) * 0.7 + 0.3)
                : (((animValue + 0.5) % 1.0) * 0.6 + 0.4);
            if (!widget.isPlaying) factor = 0.15;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: 5,
              height: 40 * factor * _heights[index],
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
        ),
      ),
    );
  }
}
