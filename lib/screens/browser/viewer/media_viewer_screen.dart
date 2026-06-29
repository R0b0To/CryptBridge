import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '/../../models/mounted_container.dart';
import '/../../services/vaultexplorer_api.dart';
import 'media_viewer_constants.dart';
import 'playlist_controller.dart';
import 'video_playback_manager.dart';
import 'widgets/encrypted_image_widget.dart';
import 'widgets/media_player_widget.dart';

enum VideoPlaybackMode { playOnce, loop, playAndAdvance }

class MediaViewerScreen extends StatefulWidget {
  final MountedContainer container;
  final List<String> mediaFiles;
  final int initialIndex;
  final String? startingFolder;

  const MediaViewerScreen({
    Key? key,
    required this.container,
    required this.mediaFiles,
    required this.initialIndex,
    this.startingFolder,
  }) : super(key: key);

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  late final PlaylistController _playlistController;
  late final VideoPlaybackManager _playbackManager;
  late final PageController _pageController;

  final ValueNotifier<ScrollPhysics> _swipePhysicsNotifier = 
      ValueNotifier<ScrollPhysics>(const BouncingScrollPhysics());
  
  final ValueNotifier<VideoPlaybackProgress> _videoProgressNotifier = 
      ValueNotifier<VideoPlaybackProgress>(const VideoPlaybackProgress());

  bool _showUI = true;
  bool _isLandscape = false;
  int _activeMenuCount = 0;

  Timer? _slideshowTimer;
  Timer? _hideTimer;

  bool _autoPlay = true;
  bool _autoAdvance = false;
  int _slideshowDelaySeconds = 4;
  VideoPlaybackMode _videoPlaybackMode = VideoPlaybackMode.playOnce;
  double _playbackSpeed = 1.0;
  bool _subtitlesEnabled = true;
  int _doubleTapSkipSeconds = 5;
  BoxFit _imageFit = BoxFit.contain;
  bool _isMuted = false;

  final Map<String, Uint8List> _prefetchedImages = {};
  final Set<String> _prefetchingActive = {};
  final Map<String, int> _rotations = {};

  VideoPlayerController? _lastListenedController;

  @override
  void initState() {
    super.initState();
    _playlistController = PlaylistController(
      container: widget.container,
      initialMediaFiles: widget.mediaFiles,
      initialIndex: widget.initialIndex,
      startingFolder: widget.startingFolder,
    );
    
    _playbackManager = VideoPlaybackManager();
    _pageController = PageController(initialPage: widget.initialIndex);

    _playlistController.addListener(_onPlaylistUpdate);
    _playbackManager.activeControllerNotifier.addListener(_onActiveVideoControllerChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startSlideshowTimerIfNeeded();
      _prefetchSurroundingItems();
    });
  }

  void _onPlaylistUpdate() {
    if (mounted) setState(() {});
  }

  void _onActiveVideoControllerChanged() {
    if (_lastListenedController != null) {
      try {
        _lastListenedController!.removeListener(_onControllerTickUpdate);
      } catch (_) {}
    }

    final controller = _playbackManager.activeController;
    _lastListenedController = controller;

    if (controller == null) {
      _videoProgressNotifier.value = const VideoPlaybackProgress();
      return;
    }

    _videoProgressNotifier.value = const VideoPlaybackProgress();
    _playbackManager.pauseAllExcept(controller);
    controller.addListener(_onControllerTickUpdate);
  }

  void _onControllerTickUpdate() {
    final controller = _playbackManager.activeController;
    if (controller == null || controller.value.hasError) return;

    final isInitialized = controller.value.isInitialized;
    final progress = _videoProgressNotifier.value;

    if (isInitialized && _videoPlaybackMode == VideoPlaybackMode.loop &&
        progress.duration > Duration.zero &&
        progress.position >= progress.duration) {
      _manualLoop(controller);
    } else if (isInitialized && _videoPlaybackMode != VideoPlaybackMode.loop &&
        progress.duration > Duration.zero &&
        progress.position >= progress.duration) {
      if (_videoPlaybackMode == VideoPlaybackMode.playAndAdvance) {
        _navigateToNext();
      }
    }
  }

  Future<void> _manualLoop(VideoPlayerController controller) async {
    try {
      await controller.pause();
      await controller.seekTo(Duration.zero);
      await controller.play();
    } catch (e) {
      debugPrint('Manual loop error execution: $e');
    }
  }

  void _prefetchSurroundingItems() {
    final index = _playlistController.currentIndex;
    final playlist = _playlistController.playlist;
    if (playlist.isEmpty) return;

    final next = index + 1;
    final prev = index - 1;
    if (next < playlist.length) _prefetchThumbnail(playlist[next]);
    if (prev >= 0) _prefetchThumbnail(playlist[prev]);
  }

  Future<void> _prefetchThumbnail(String fileName) async {
    if (!MediaViewerConstants.isImage(fileName)) return;
    if (_prefetchedImages.containsKey(fileName) || _prefetchingActive.contains(fileName)) return;

    _prefetchingActive.add(fileName);
    try {
      final thumbBytes = await vaultExplorerApi.getImageThumbnail(
        widget.container,
        fileName,
        targetSize: MediaViewerConstants.thumbnailTargetSize,
      );
      if (thumbBytes != null && thumbBytes.isNotEmpty && mounted) {
        setState(() {
          _prefetchedImages[fileName] = thumbBytes;
          if (_prefetchedImages.length > MediaViewerConstants.maxPrefetchCacheSize) {
            _prefetchedImages.remove(_prefetchedImages.keys.first);
          }
        });
      }
    } catch (e) {
      debugPrint('Failed to prefetch image content: $e');
    } finally {
      _prefetchingActive.remove(fileName);
    }
  }

  void _navigateToNext() {
    _cancelSlideshowTimer();
    final index = _playlistController.currentIndex;
    if (index < _playlistController.playlist.length - 1) {
      HapticFeedback.lightImpact();
      _pageController.animateToPage(
        index + 1,
        duration: MediaViewerConstants.pageTransitionDuration,
        curve: Curves.easeInOut,
      );
    }
  }

  void _navigateToPrev() {
    _cancelSlideshowTimer();
    final index = _playlistController.currentIndex;
    if (index > 0) {
      HapticFeedback.lightImpact();
      _pageController.animateToPage(
        index - 1,
        duration: MediaViewerConstants.pageTransitionDuration,
        curve: Curves.easeInOut,
      );
    }
  }

  void _startSlideshowTimerIfNeeded() {
    _cancelSlideshowTimer();
    if (!_autoAdvance || _playlistController.isEmpty) return;

    final currentFile = _playlistController.currentFile;
    if (MediaViewerConstants.isImage(currentFile)) {
      _slideshowTimer = Timer(Duration(seconds: _slideshowDelaySeconds), () {
        if (mounted) _navigateToNext();
      });
    }
  }

  Future<void> _deleteCurrentFile() async {
    final cs = Theme.of(context).colorScheme;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete file?'),
        content: const Text('This action is permanent and cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: cs.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final fileToDelete = _playlistController.currentFile;
    bool success = false;
    try {
      success = await vaultExplorerApi.deleteFile(widget.container, fileToDelete);
    } catch (e) {
      debugPrint('Deletion error operation failed: $e');
    }

    if (success && mounted) {
      _prefetchedImages.remove(fileToDelete);
      _playlistController.removeCurrent();
      
      if (_playlistController.isEmpty) {
        Navigator.pop(context);
        return;
      }
      
      _pageController.jumpToPage(_playlistController.currentIndex);
      _prefetchSurroundingItems();
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File deleted successfully')),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: const Text('Failed to delete file'), backgroundColor: cs.error),
      );
    }
  }

  void _cancelSlideshowTimer() {
    _slideshowTimer?.cancel();
    _slideshowTimer = null;
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    if (_activeMenuCount > 0) return;
    
    _hideTimer = Timer(MediaViewerConstants.uiHideDelay, () {
      final controller = _playbackManager.activeController;
      if (mounted && controller != null && controller.value.isPlaying && _showUI && _activeMenuCount == 0) {
        _setUIVisibility(false);
      }
    });
  }

  void _setUIVisibility(bool show) {
    if (mounted) {
      setState(() => _showUI = show);
      if (show) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        _startHideTimer();
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        _hideTimer?.cancel();
      }
    }
  }

  void _menuOpened() {
    _activeMenuCount++;
    _hideTimer?.cancel();
  }

  void _menuClosed() {
    _activeMenuCount = (_activeMenuCount - 1).clamp(0, 999);
    _startHideTimer();
  }

  @override
  void dispose() {
    _playlistController.removeListener(_onPlaylistUpdate);
    if (_lastListenedController != null) {
      try {
        _lastListenedController!.removeListener(_onControllerTickUpdate);
      } catch (_) {}
    }
    _playbackManager.activeControllerNotifier.removeListener(_onActiveVideoControllerChanged);

    _cancelSlideshowTimer();
    _hideTimer?.cancel();
    _pageController.dispose();
    _playbackManager.dispose();
    _swipePhysicsNotifier.dispose();
    _videoProgressNotifier.dispose();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final String minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final String seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    
    if (d.inHours > 0) {
      final String hours = d.inHours.toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  String _getImageFitLabel(BoxFit fit) {
    if (fit == BoxFit.contain) return 'Contain';
    if (fit == BoxFit.fitWidth) return 'Fit Width';
    if (fit == BoxFit.fitHeight) return 'Fit Height';
    return 'Contain';
  }

  String _getPlaybackModeLabel(VideoPlaybackMode mode) {
    if (mode == VideoPlaybackMode.playOnce) return 'Play Once';
    if (mode == VideoPlaybackMode.loop) return 'Loop Current';
    if (mode == VideoPlaybackMode.playAndAdvance) return 'Play & Advance';
    return 'Play Once';
  }

  void _showAdvancedSettings(BuildContext context, bool isImage) {
    final cs = Theme.of(context).colorScheme;
    _menuOpened();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      isScrollControlled: true,
      showDragHandle: false,
      builder: (context) {
        String sheetPage = 'main';

        return StatefulBuilder(
          builder: (context, setSheetState) {
            final isLandscapeLayout = MediaQuery.of(context).orientation == Orientation.landscape;
            final double maxSheetHeight = isLandscapeLayout 
                ? MediaQuery.of(context).size.height * 0.72
                : MediaQuery.of(context).size.height * 0.9;

            Widget buildHeader(String title, VoidCallback? onBack) {
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    if (onBack != null)
                      IconButton(
                        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white70),
                        onPressed: onBack,
                      )
                    else
                      const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: onBack != null ? TextAlign.left : TextAlign.center,
                      ),
                    ),
                    if (onBack != null)
                      const SizedBox(width: 48)
                    else
                      const SizedBox(width: 8),
                  ],
                ),
              );
            }

            return ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxSheetHeight),
                    child: SafeArea(
                      top: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 12),
                          // Integrated non-floating drag handle indicator
                          Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Flexible(
                            child: SingleChildScrollView(
                              child: Padding(
                                padding: const EdgeInsets.only(left: 20, right: 20, top: 4, bottom: 24),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (sheetPage == 'main') ...[
                                      buildHeader(isImage ? 'Image Settings' : 'Playback Settings', null),
                                      const SizedBox(height: 8),
                                      _buildMainPage(
                                        context,
                                        isImage,
                                        setSheetState,
                                        onGoToImageFit: () => setSheetState(() => sheetPage = 'imageFit'),
                                        onGoToSlideshowDelay: () => setSheetState(() => sheetPage = 'slideshowDelay'),
                                        onGoToPlaybackSpeed: () => setSheetState(() => sheetPage = 'playbackSpeed'),
                                        onGoToPlaybackMode: () => setSheetState(() => sheetPage = 'playbackMode'),
                                      ),
                                    ] else if (sheetPage == 'imageFit') ...[
                                      buildHeader('Image Fit Mode', () => setSheetState(() => sheetPage = 'main')),
                                      const SizedBox(height: 8),
                                      _buildImageFitSubmenu(cs, () => setSheetState(() => sheetPage = 'main')),
                                    ] else if (sheetPage == 'slideshowDelay') ...[
                                      buildHeader('Slideshow Delay', () => setSheetState(() => sheetPage = 'main')),
                                      const SizedBox(height: 8),
                                      _buildSlideshowDelaySubmenu(cs, () => setSheetState(() => sheetPage = 'main')),
                                    ] else if (sheetPage == 'playbackSpeed') ...[
                                      buildHeader('Playback Speed', () => setSheetState(() => sheetPage = 'main')),
                                      const SizedBox(height: 8),
                                      _buildPlaybackSpeedSubmenu(cs, () => setSheetState(() => sheetPage = 'main')),
                                    ] else if (sheetPage == 'playbackMode') ...[
                                      buildHeader('Playback Mode', () => setSheetState(() => sheetPage = 'main')),
                                      const SizedBox(height: 8),
                                      _buildPlaybackModeSubmenu(cs, () => setSheetState(() => sheetPage = 'main')),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(_menuClosed);
  }

  Widget _buildMainPage(
    BuildContext context,
    bool isImage,
    StateSetter setSheetState, {
    required VoidCallback onGoToImageFit,
    required VoidCallback onGoToSlideshowDelay,
    required VoidCallback onGoToPlaybackSpeed,
    required VoidCallback onGoToPlaybackMode,
  }) {
    final currentName = _playlistController.currentFile;
    final cs = Theme.of(context).colorScheme;

    if (isImage) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.rotate_right_rounded, color: Colors.white70),
            title: const Text('Rotate 90°', style: TextStyle(color: Colors.white, fontSize: 14)),
            trailing: Text(
              '${(_rotations[currentName] ?? 0) * 90}°',
              style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold, fontSize: 13),
            ),
            onTap: () {
              HapticFeedback.mediumImpact();
              setState(() {
                _rotations[currentName] = ((_rotations[currentName] ?? 0) + 1) % 4;
              });
              setSheetState(() {});
            },
          ),
          const Divider(color: Colors.white10),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.aspect_ratio_rounded, color: Colors.white70),
            title: const Text('Image Fit Mode', style: TextStyle(color: Colors.white, fontSize: 14)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _getImageFitLabel(_imageFit),
                  style: TextStyle(color: cs.primary, fontSize: 13),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right_rounded, color: Colors.white30, size: 20),
              ],
            ),
            onTap: () {
              HapticFeedback.lightImpact();
              onGoToImageFit();
            },
          ),
          const Divider(color: Colors.white10),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.timer_outlined, color: Colors.white70),
            title: const Text('Slideshow Delay', style: TextStyle(color: Colors.white, fontSize: 14)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${_slideshowDelaySeconds}s',
                  style: TextStyle(color: cs.primary, fontSize: 13),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right_rounded, color: Colors.white30, size: 20),
              ],
            ),
            onTap: () {
              HapticFeedback.lightImpact();
              onGoToSlideshowDelay();
            },
          ),
        ],
      );
    } else {
      final hasSubtitles = _playbackManager.isSubtitleAvailable(_playlistController.currentIndex);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.rotate_right_rounded, color: Colors.white70),
            title: const Text('Rotate 90°', style: TextStyle(color: Colors.white, fontSize: 14)),
            trailing: Text(
              '${(_rotations[currentName] ?? 0) * 90}°',
              style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold, fontSize: 13),
            ),
            onTap: () {
              HapticFeedback.mediumImpact();
              setState(() {
                _rotations[currentName] = ((_rotations[currentName] ?? 0) + 1) % 4;
              });
              setSheetState(() {});
            },
          ),
          const Divider(color: Colors.white10),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.slow_motion_video_rounded, color: Colors.white70),
            title: const Text('Playback Speed', style: TextStyle(color: Colors.white, fontSize: 14)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${_playbackSpeed}x',
                  style: TextStyle(color: cs.primary, fontSize: 13),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right_rounded, color: Colors.white30, size: 20),
              ],
            ),
            onTap: () {
              HapticFeedback.lightImpact();
              onGoToPlaybackSpeed();
            },
          ),
          const Divider(color: Colors.white10),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.play_circle_outline_rounded, color: Colors.white70),
            title: const Text('Playback Mode', style: TextStyle(color: Colors.white, fontSize: 14)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _getPlaybackModeLabel(_videoPlaybackMode),
                  style: TextStyle(color: cs.primary, fontSize: 13),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right_rounded, color: Colors.white30, size: 20),
              ],
            ),
            onTap: () {
              HapticFeedback.lightImpact();
              onGoToPlaybackMode();
            },
          ),
          if (hasSubtitles) ...[
            const Divider(color: Colors.white10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.subtitles_rounded, color: Colors.white70),
              title: const Text('Subtitles', style: TextStyle(color: Colors.white, fontSize: 14)),
              value: _subtitlesEnabled,
              activeColor: cs.primary,
              onChanged: (val) {
                HapticFeedback.lightImpact();
                setState(() => _subtitlesEnabled = val);
                setSheetState(() {});
              },
            ),
          ],
        ],
      );
    }
  }

  Widget _buildImageFitSubmenu(ColorScheme cs, VoidCallback onBack) {
    final fits = [BoxFit.contain, BoxFit.fitWidth, BoxFit.fitHeight];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: fits.map((fit) {
        final isSelected = _imageFit == fit;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            _getImageFitLabel(fit),
            style: TextStyle(
              color: isSelected ? cs.primary : Colors.white70,
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          trailing: isSelected ? Icon(Icons.check_rounded, color: cs.primary, size: 18) : null,
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() => _imageFit = fit);
            onBack();
          },
        );
      }).toList(),
    );
  }

  Widget _buildSlideshowDelaySubmenu(ColorScheme cs, VoidCallback onBack) {
    final delays = [2, 4, 6, 8, 10];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: delays.map((delay) {
        final isSelected = _slideshowDelaySeconds == delay;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            '${delay} seconds',
            style: TextStyle(
              color: isSelected ? cs.primary : Colors.white70,
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          trailing: isSelected ? Icon(Icons.check_rounded, color: cs.primary, size: 18) : null,
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() {
              _slideshowDelaySeconds = delay;
              if (_autoAdvance) {
                _startSlideshowTimerIfNeeded();
              }
            });
            onBack();
          },
        );
      }).toList(),
    );
  }

  Widget _buildPlaybackSpeedSubmenu(ColorScheme cs, VoidCallback onBack) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: MediaViewerConstants.playbackSpeeds.map((speed) {
        final isSelected = _playbackSpeed == speed;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            '${speed}x${speed == 1.0 ? " (Normal)" : ""}',
            style: TextStyle(
              color: isSelected ? cs.primary : Colors.white70,
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          trailing: isSelected ? Icon(Icons.check_rounded, color: cs.primary, size: 18) : null,
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() => _playbackSpeed = speed);
            _playbackManager.activeController?.setPlaybackSpeed(speed);
            onBack();
          },
        );
      }).toList(),
    );
  }

  Widget _buildPlaybackModeSubmenu(ColorScheme cs, VoidCallback onBack) {
    final modes = [VideoPlaybackMode.playOnce, VideoPlaybackMode.loop, VideoPlaybackMode.playAndAdvance];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: modes.map((mode) {
        final isSelected = _videoPlaybackMode == mode;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            _getPlaybackModeLabel(mode),
            style: TextStyle(
              color: isSelected ? cs.primary : Colors.white70,
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          trailing: isSelected ? Icon(Icons.check_rounded, color: cs.primary, size: 18) : null,
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() => _videoPlaybackMode = mode);
            onBack();
          },
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_playlistController.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
          ),
        ),
      );
    }

    final total = _playlistController.playlist.length;
    final currentName = _playlistController.currentFile;
    final isCurrentAnImage = MediaViewerConstants.isImage(currentName);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          ValueListenableBuilder<ScrollPhysics>(
            valueListenable: _swipePhysicsNotifier,
            builder: (context, physics, child) {
              return PageView.builder(
                controller: _pageController,
                physics: physics,
                itemCount: total,
                onPageChanged: (index) {
                  _playlistController.updateIndex(index);
                  _startSlideshowTimerIfNeeded();
                  _prefetchSurroundingItems();
                  _playbackManager.handlePageChange(index);
                },
                itemBuilder: (context, index) {
                  final volId = widget.container.volId;
                  final escapedPath = Uri.encodeComponent(_playlistController.playlist[index]);
                  final contentUriString = 'content://com.aeidolon.vaultexplorer.documents/document/$volId%3Afile%3A$escapedPath';
                  final fileName = _playlistController.playlist[index];
                  final prefetchedBytes = _prefetchedImages[fileName];

                  final ext = fileName.split('.').last.toLowerCase();
                  final isImg = MediaViewerConstants.imageExtensions.contains(ext);
                  final isAudio = MediaViewerConstants.audioExtensions.contains(ext);

                  return Container(
                    color: Colors.black,
                    child: isImg
                        ? _ImagePageItem(
                            key: ValueKey(fileName),
                            fileName: fileName,
                            prefetchedBytes: prefetchedBytes,
                            container: widget.container,
                            imageFit: _imageFit,
                            rotationQuarterTurns: _rotations[fileName] ?? 0,
                            showUI: _showUI,
                            onToggleUI: _setUIVisibility,
                            onZoomChanged: (allowSwipe) {
                              _swipePhysicsNotifier.value = allowSwipe 
                                  ? const BouncingScrollPhysics() 
                                  : const NeverScrollableScrollPhysics();
                            },
                          )
                        : MediaPlayerWidget(
                            key: ValueKey(fileName),
                            container: widget.container,
                            fileName: fileName,
                            contentUriString: contentUriString,
                            showUI: _showUI,
                            onToggleUI: _setUIVisibility,
                            skipSeconds: _doubleTapSkipSeconds,
                            autoPlay: _autoPlay,
                            isAudio: isAudio,
                            subtitlesEnabled: _subtitlesEnabled,
                            rotationQuarterTurns: _rotations[fileName] ?? 0,
                            progressNotifier: _videoProgressNotifier,
                            onSubtitlesAvailableChanged: (val) {
                              _playbackManager.updateSubtitleStatus(index, val);
                              if (index == _playlistController.currentIndex) {
                                setState(() {});
                              }
                            },
                            onZoomChanged: (allowSwipe) {
                              _swipePhysicsNotifier.value = allowSwipe 
                                  ? const BouncingScrollPhysics() 
                                  : const NeverScrollableScrollPhysics();
                            },
                            onVideoControllerInitialized: (controller) {
                              _playbackManager.registerController(
                                index: index,
                                controller: controller,
                                currentFocus: index == _playlistController.currentIndex,
                              );
                            },
                            onVideoControllerDisposed: () {
                              _playbackManager.handleDisposed(index);
                            },
                          ),
                  );
                },
              );
            },
          ),

          _buildCenterTransportControls(cs),

          AnimatedPositioned(
            duration: MediaViewerConstants.animationDuration,
            curve: Curves.easeOut,
            top: _showUI ? MediaQuery.of(context).padding.top + 8 : -110,
            left: 16,
            right: 16,
            child: _buildTopBar(cs, currentName, total),
          ),

          AnimatedPositioned(
            duration: MediaViewerConstants.animationDuration,
            curve: Curves.easeOut,
            left: 0,
            right: 0,
            bottom: _showUI ? 0 : -200,
            child: isCurrentAnImage
                ? _buildImageBottomControls(cs, currentName)
                : _buildVideoBottomControls(cs, currentName),
          ),
        ],
      ),
    );
  }

  Widget _buildCenterTransportControls(ColorScheme cs) {
    final bool isFirst = _playlistController.currentIndex == 0;
    final bool isLast = _playlistController.currentIndex == _playlistController.playlist.length - 1;
    final currentName = _playlistController.currentFile;
    final isImage = MediaViewerConstants.isImage(currentName);

    bool isPlayingState = false;
    if (isImage) {
      isPlayingState = _autoAdvance;
    } else {
      isPlayingState = _playbackManager.activeController?.value.isPlaying ?? false;
    }

    return IgnorePointer(
      ignoring: !_showUI,
      child: AnimatedOpacity(
        duration: MediaViewerConstants.animationDuration,
        curve: Curves.easeInOut,
        opacity: _showUI ? 1.0 : 0.0,
        child: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildCenterCircleButton(
                icon: Icons.skip_previous_rounded,
                onPressed: isFirst ? null : _navigateToPrev,
                enabled: !isFirst,
              ),
              const SizedBox(width: 32),
              _buildCenterCircleButton(
                icon: isPlayingState ? Icons.pause_rounded : Icons.play_arrow_rounded,
                isLarge: true,
                onPressed: () {
                  HapticFeedback.mediumImpact();
                  _setUIVisibility(true);
                  if (isImage) {
                    setState(() {
                      _autoAdvance = !_autoAdvance;
                      if (_autoAdvance) {
                        _startSlideshowTimerIfNeeded();
                      } else {
                        _cancelSlideshowTimer();
                      }
                    });
                  } else {
                    final controller = _playbackManager.activeController;
                    if (controller != null) {
                      setState(() {
                        if (controller.value.isPlaying) {
                          controller.pause();
                        } else {
                          controller.play();
                        }
                      });
                    }
                  }
                },
                enabled: true,
              ),
              const SizedBox(width: 32),
              _buildCenterCircleButton(
                icon: Icons.skip_next_rounded,
                onPressed: isLast ? null : _navigateToNext,
                enabled: !isLast,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCenterCircleButton({
    required IconData icon,
    required VoidCallback? onPressed,
    required bool enabled,
    bool isLarge = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withValues(alpha: isLarge ? 0.25 : 0.15),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05), width: 1),
      ),
      child: IconButton(
        iconSize: isLarge ? 48 : 32,
        color: enabled ? Colors.white : Colors.white30,
        icon: Icon(icon),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildTopBar(ColorScheme cs, String currentName, int total) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: () {
                  HapticFeedback.lightImpact();
                  Navigator.pop(context);
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: Text(
                        currentName.split('/').last,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_playlistController.currentIndex + 1} of $total${_playlistController.isScanningSubfolders ? '  ·  scanning…' : ''}',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 11),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline_rounded, color: cs.error),
                tooltip: 'Delete File',
                onPressed: _deleteCurrentFile,
              ),
              _buildMoreMenu(cs),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMoreMenu(ColorScheme cs) {
    return MenuAnchor(
      onOpen: _menuOpened,
      onClose: _menuClosed,
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(Colors.black.withValues(alpha: 0.9)),
        elevation: WidgetStateProperty.all(12),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
          ),
        ),
      ),
      builder: (ctx, controller, child) => IconButton(
        onPressed: () {
          HapticFeedback.lightImpact();
          controller.isOpen ? controller.close() : controller.open();
        },
        icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
        tooltip: 'More Actions',
      ),
      menuChildren: [
        MenuItemButton(
          style: MenuItemButton.styleFrom(foregroundColor: Colors.white),
          onPressed: () async {
            try {
              await vaultExplorerApi.openWithApp(widget.container, _playlistController.currentFile);
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('Failed to open in external app: $e'),
                  backgroundColor: Theme.of(context).colorScheme.error,
                ));
              }
            }
          },
          leadingIcon: const Icon(Icons.open_in_new_rounded, size: 18, color: Colors.white70),
          child: const Text('Open with App'),
        ),
        SubmenuButton(
          style: SubmenuButton.styleFrom(foregroundColor: Colors.white),
          menuStyle: MenuStyle(
            backgroundColor: WidgetStateProperty.all(Colors.black.withValues(alpha: 0.9)),
            shape: WidgetStateProperty.all(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
              ),
            ),
          ),
          leadingIcon: const Icon(Icons.screen_rotation_rounded, size: 18, color: Colors.white70),
          menuChildren: [
            MenuItemButton(
              style: MenuItemButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () {
                HapticFeedback.lightImpact();
                SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
              },
              child: const Text('Force Portrait'),
            ),
            MenuItemButton(
              style: MenuItemButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () {
                HapticFeedback.lightImpact();
                SystemChrome.setPreferredOrientations([
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.landscapeRight,
                ]);
              },
              child: const Text('Force Landscape'),
            ),
            MenuItemButton(
              style: MenuItemButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () {
                HapticFeedback.lightImpact();
                SystemChrome.setPreferredOrientations(DeviceOrientation.values);
              },
              child: const Text('Auto-Rotate (Sensor)'),
            ),
          ],
          child: const Text('Screen Orientation'),
        ),
        MenuItemButton(
          style: MenuItemButton.styleFrom(foregroundColor: Colors.white),
          onPressed: () {
            _playlistController.toggleShuffle();
            if (_pageController.hasClients) {
              _pageController.jumpToPage(_playlistController.currentIndex);
            }
          },
          leadingIcon: Icon(
            Icons.shuffle_rounded,
            size: 18,
            color: _playlistController.isShuffled ? cs.primary : Colors.white70,
          ),
          child: Text(_playlistController.isShuffled ? 'Disable Shuffle' : 'Shuffle Playlist'),
        ),
        const PopupMenuDivider(color: Colors.white10),
        SubmenuButton(
          style: SubmenuButton.styleFrom(foregroundColor: Colors.white),
          menuStyle: MenuStyle(
            backgroundColor: WidgetStateProperty.all(Colors.black.withValues(alpha: 0.9)),
            shape: WidgetStateProperty.all(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
              ),
            ),
          ),
          menuChildren: [
            MenuItemButton(
              style: MenuItemButton.styleFrom(
                foregroundColor: _playlistController.selectedFolder == 'Current Folder Only' ? cs.primary : Colors.white,
              ),
              onPressed: () async {
                await _playlistController.filterByFolder('Current Folder Only');
                if (_pageController.hasClients) {
                  _pageController.jumpToPage(_playlistController.currentIndex);
                }
              },
              leadingIcon: _playlistController.selectedFolder == 'Current Folder Only'
                  ? Icon(Icons.check_rounded, size: 16, color: cs.primary)
                  : const SizedBox(width: 16),
              child: const Text('Current Folder Only'),
            ),
            MenuItemButton(
              style: MenuItemButton.styleFrom(
                foregroundColor: _playlistController.selectedFolder == 'All' ? cs.primary : Colors.white,
              ),
              onPressed: () async {
                await _playlistController.filterByFolder('All');
                if (_pageController.hasClients) {
                  _pageController.jumpToPage(_playlistController.currentIndex);
                }
              },
              leadingIcon: _playlistController.selectedFolder == 'All'
                  ? Icon(Icons.check_rounded, size: 16, color: cs.primary)
                  : const SizedBox(width: 16),
              child: const Text('All (Incl. Subfolders)'),
            ),
          ],
          child: const Text('Folder Filter'),
        ),
      ],
    );
  }

  Widget _buildImageBottomControls(ColorScheme cs, String currentName) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).padding.bottom + 16,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildPillContainer(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _autoAdvance ? Icons.slideshow_rounded : Icons.image_rounded,
                  color: _autoAdvance ? cs.primary : Colors.white70,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  _autoAdvance ? '${_slideshowDelaySeconds}s delay' : 'Static Mode',
                  style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          _buildPillContainer(
            padding: EdgeInsets.zero,
            child: IconButton(
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(8),
              iconSize: 20,
              icon: const Icon(Icons.tune_rounded, color: Colors.white70),
              tooltip: 'Advanced Settings',
              onPressed: () => _showAdvancedSettings(context, true),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoBottomControls(ColorScheme cs, String currentName) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).padding.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
            color: Colors.transparent,
            child: SizedBox(
              height: 48,
              child: ValueListenableBuilder<VideoPlaybackProgress>(
                valueListenable: _videoProgressNotifier,
                builder: (context, progress, child) {
                  final positionStr = _formatDuration(progress.position);
                  final durationStr = _formatDuration(progress.duration);
                  return Row(
                    children: [
                      Text(
                        positionStr,
                        style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: cs.primary,
                            inactiveTrackColor: Colors.white24,
                            trackHeight: 2,
                            thumbColor: cs.primary,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                            trackShape: const RectangularSliderTrackShape(),
                          ),
                          child: Slider(
                            value: progress.sliderValue.clamp(0.0, 1.0),
                            onChanged: (value) {
                              _setUIVisibility(true);
                              _videoProgressNotifier.value = progress.copyWith(
                                isDragging: true,
                                sliderValue: value,
                              );
                              final controller = _playbackManager.activeController;
                              if (controller != null) {
                                final targetMs = (value * progress.duration.inMilliseconds).toInt();
                                controller.seekTo(Duration(milliseconds: targetMs));
                              }
                            },
                            onChangeEnd: (value) {
                              final controller = _playbackManager.activeController;
                              if (controller != null) {
                                final targetMs = (value * progress.duration.inMilliseconds).toInt();
                                controller.seekTo(Duration(milliseconds: targetMs)).then((_) {
                                  _videoProgressNotifier.value = _videoProgressNotifier.value.copyWith(
                                    isDragging: false,
                                  );
                                  _startHideTimer();
                                });
                              }
                            },
                          ),
                        ),
                      ),
                      Text(
                        durationStr,
                        style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildPillContainer(
                    padding: EdgeInsets.zero,
                    child: IconButton(
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.all(8),
                      iconSize: 20,
                      icon: Icon(
                        _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                        color: _isMuted ? cs.error : Colors.white70,
                      ),
                      tooltip: 'Mute',
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        setState(() => _isMuted = !_isMuted);
                        _playbackManager.activeController?.setVolume(_isMuted ? 0.0 : 1.0);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildPillContainer(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: ValueListenableBuilder<VideoPlaybackProgress>(
                      valueListenable: _videoProgressNotifier,
                      builder: (context, progress, child) {
                        final positionStr = _formatDuration(progress.position);
                        final durationStr = _formatDuration(progress.duration);
                        return Text(
                          '$positionStr / $durationStr',
                          style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                        );
                      },
                    ),
                  ),
                ],
              ),
              _buildPillContainer(
                padding: EdgeInsets.zero,
                child: IconButton(
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(8),
                  iconSize: 20,
                  icon: const Icon(Icons.tune_rounded, color: Colors.white70),
                  tooltip: 'Advanced Settings',
                  onPressed: () => _showAdvancedSettings(context, false),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPillContainer({required Widget child, EdgeInsetsGeometry? padding}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: padding ?? const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _ImagePageItem extends StatefulWidget {
  final String fileName;
  final Uint8List? prefetchedBytes;
  final MountedContainer container;
  final BoxFit imageFit;
  final int rotationQuarterTurns;
  final bool showUI;
  final ValueChanged<bool> onToggleUI;
  final ValueChanged<bool> onZoomChanged;

  const _ImagePageItem({
    Key? key,
    required this.fileName,
    required this.prefetchedBytes,
    required this.container,
    required this.imageFit,
    required this.rotationQuarterTurns,
    required this.showUI,
    required this.onToggleUI,
    required this.onZoomChanged,
  }) : super(key: key);

  @override
  State<_ImagePageItem> createState() => _ImagePageItemState();
}

class _ImagePageItemState extends State<_ImagePageItem> {
  late final TransformationController _transformationController;
  double _scale = 1.0;
  TapDownDetails? _doubleTapDetails;

  @override
  void initState() {
    super.initState();
    _transformationController = TransformationController();
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => widget.onToggleUI(!widget.showUI),
      onDoubleTapDown: (d) => _doubleTapDetails = d,
      onDoubleTap: () {
        final position = _doubleTapDetails?.localPosition;
        if (_scale == 1.0) {
          _scale = 2.5;
          if (position != null) {
            final x = -position.dx * (_scale - 1);
            final y = -position.dy * (_scale - 1);
            _transformationController.value = Matrix4.identity()
              ..translate(x, y)
              ..scale(_scale);
          } else {
            _transformationController.value = Matrix4.identity()..scale(_scale);
          }
          widget.onZoomChanged(false);
        } else {
          _scale = 1.0;
          _transformationController.value = Matrix4.identity();
          widget.onZoomChanged(true);
        }
      },
      child: SizedBox.expand(
        child: InteractiveViewer(
          transformationController: _transformationController,
          maxScale: MediaViewerConstants.maxImageZoom,
          minScale: 0.5,
          boundaryMargin: EdgeInsets.zero,
          onInteractionUpdate: (details) {
            final s = _transformationController.value.getMaxScaleOnAxis();
            if (s != _scale) {
              _scale = s;
              widget.onZoomChanged(s <= 1.01);
            }
          },
          onInteractionEnd: (details) {
            final s = _transformationController.value.getMaxScaleOnAxis();
            if (s <= 1.01) {
              widget.onZoomChanged(true);
            }
          },
          child: Center(
            child: RotatedBox(
              quarterTurns: widget.rotationQuarterTurns,
              child: EncryptedImageWidget(
                container: widget.container,
                fileName: widget.fileName,
                prefetchedBytes: widget.prefetchedBytes,
                fit: widget.imageFit,
              ),
            ),
          ),
        ),
      ),
    );
  }
}