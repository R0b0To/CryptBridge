import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../../models/mounted_container.dart';
import '../../services/vaultexplorer_api.dart';
import '../../utils/raw_entry.dart'; 

// Unified Video Playback Modes
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
  late PageController _pageController;
  late int _currentIndex;
  bool _showUI      = true;
  bool _isLandscape = false;
  bool _isMenuOpen  = false; // Prevents the auto-hide timer from firing while a menu is open

  late List<String> _originalList;
  late List<String> _currentPlaylist;
  bool _isShuffled = false;

  bool _allFilesScanned      = false;
  bool _isScanningSubfolders = false;
  Timer? _slideshowTimer;

  bool _autoPlay              = true;
  bool _autoAdvance           = false;
  VideoPlaybackMode _videoPlaybackMode = VideoPlaybackMode.playOnce;
  double _playbackSpeed         = 1.0;
  bool _subtitlesEnabled        = true;
  int _doubleTapSkipSeconds     = 5;
  String _selectedFolder        = 'Current Folder Only';
  BoxFit _imageFit              = BoxFit.contain;
  bool _isMuted                 = false;

  final Map<String, Uint8List> _prefetchedImages = {};
  final Set<String> _prefetchingActive = {};

  bool _subtitlesAvailable = false;

  VideoPlayerController? _activeVideoController;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _sliderValue = 0.0;
  bool _isDragging = false;
  DateTime _lastSeekTime = DateTime.now();
  bool _endFired = false;
  Timer? _hideTimer;

  final Map<String, int> _rotations = {};

  static const int _maxLiveControllers = 3;
  final Map<int, VideoPlayerController> _initializedControllers = {};
  final Map<int, bool> _subtitlesAvailableMap = {};

  @override
  void initState() {
    super.initState();
    _originalList    = List.from(widget.mediaFiles);
    _currentPlaylist = List.from(widget.mediaFiles);
    _currentIndex    = widget.initialIndex;
    _pageController  = PageController(initialPage: widget.initialIndex);

    final baseDir = _getBaseDir();
    final hasSubfolderItems = widget.mediaFiles.any((file) {
      final dir = file.contains('/')
          ? file.substring(0, file.lastIndexOf('/'))
          : '';
      return dir != baseDir;
    });
    if (hasSubfolderItems) {
      _selectedFolder  = 'All';
      _allFilesScanned = true;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startSlideshowTimerIfNeeded();
      _prefetchSurroundingItems();
    });
  }

  String _getBaseDir() {
    if (widget.startingFolder != null) return widget.startingFolder!;
    if (widget.mediaFiles.isEmpty) return '';
    final first = widget.mediaFiles.first;
    if (!first.contains('/')) return '';
    return first.substring(0, first.lastIndexOf('/'));
  }

  bool _isSupportedMedia(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return ['jpg','jpeg','png','gif','webp',
            'mp4','m4v','webm','mov','avi','mkv',
            'mp3','m4a','wav','flac','ogg','aac'].contains(ext);
  }

  bool _isImageFile(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return ['jpg','jpeg','png','gif','webp'].contains(ext);
  }

  Future<List<String>> _scanDirectoryRecursively(String baseDir, {int depth = 0}) async {
    if (depth > 20) return [];

    final foundFiles  = <String>[];
    final subdirNames = <String>[];
    
    try {
      final items = await vaultExplorerApi.listDirectory(widget.container, baseDir);
      if (items != null) {
        for (final item in items) {
          if (item.startsWith('System:')) continue;
          
          final entry = RawEntry.parse(item);
          
          if (entry.isDir) {
            subdirNames.add(entry.name);
          } else {
            if (_isSupportedMedia(entry.name)) {
              final fullPath = baseDir.isEmpty ? entry.name : '$baseDir/${entry.name}';
              foundFiles.add(fullPath);
            }
          }
        }
        
        if (subdirNames.isNotEmpty) {
          final nested = await Future.wait(subdirNames.map((name) {
            final subPath = baseDir.isEmpty ? name : '$baseDir/$name';
            return _scanDirectoryRecursively(subPath, depth: depth + 1);
          }));
          for (final list in nested) {
            foundFiles.addAll(list);
          }
        }
      }
    } catch (e) {
      debugPrint('Error walking subdirectories: $e');
    }
    
    return foundFiles;
  }

  void _applyFolderFiltering(String folder, String currentFile) {
    final baseDir = _getBaseDir();
    List<String> filteredList;
    if (folder == 'All') {
      filteredList = List.from(_originalList);
    } else {
      filteredList = _originalList.where((file) {
        final dir = file.contains('/')
            ? file.substring(0, file.lastIndexOf('/'))
            : '';
        return dir == baseDir;
      }).toList();
    }
    int newIndex = filteredList.indexOf(currentFile);
    if (newIndex == -1) newIndex = 0;
    if (filteredList.isNotEmpty) {
      _currentPlaylist = filteredList;
      _currentIndex    = newIndex;
      if (_pageController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageController.hasClients) {
            _pageController.jumpToPage(_currentIndex);
          }
        });
      }
      _prefetchSurroundingItems();
    }
  }

  void _navigateToNext() {
    _cancelSlideshowTimer();
    if (_currentIndex < _currentPlaylist.length - 1) {
      HapticFeedback.lightImpact();
      _pageController.animateToPage(_currentIndex + 1,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut);
    }
  }

  void _navigateToPrev() {
    _cancelSlideshowTimer();
    if (_currentIndex > 0) {
      HapticFeedback.lightImpact();
      _pageController.animateToPage(_currentIndex - 1,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut);
    }
  }

  void _startSlideshowTimerIfNeeded() {
    _cancelSlideshowTimer();
    if (!_autoAdvance || _currentPlaylist.isEmpty) return;
    final ext = _currentPlaylist[_currentIndex].split('.').last.toLowerCase();
    if (['jpg','jpeg','png','gif','webp'].contains(ext)) {
      _slideshowTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) _navigateToNext();
      });
    }
  }

  void _toggleAutoAdvance(bool value) {
    HapticFeedback.mediumImpact();
    setState(() => _autoAdvance = value);
    if (_autoAdvance) {
      _startSlideshowTimerIfNeeded();
    } else {
      _cancelSlideshowTimer();
    }
  }

  void _cancelSlideshowTimer() {
    _slideshowTimer?.cancel();
    _slideshowTimer = null;
  }

  void _addToCache(String fileName, Uint8List bytes) {
    _prefetchedImages.remove(fileName);
    _prefetchedImages[fileName] = bytes;
    if (_prefetchedImages.length > 5) {
      _prefetchedImages.remove(_prefetchedImages.keys.first);
    }
  }

  void _prefetchSurroundingItems() {
    if (_currentPlaylist.isEmpty) return;
    final next = _currentIndex + 1;
    final prev = _currentIndex - 1;
    if (next < _currentPlaylist.length) _prefetchThumbnail(_currentPlaylist[next]);
    if (prev >= 0)                       _prefetchThumbnail(_currentPlaylist[prev]);
  }

  Future<void> _prefetchThumbnail(String fileName) async {
    if (!_isImageFile(fileName)) return;
    if (_prefetchedImages.containsKey(fileName) ||
        _prefetchingActive.contains(fileName)) return;

    _prefetchingActive.add(fileName);
    try {
      final thumbBytes = await vaultExplorerApi.getImageThumbnail(
          widget.container, fileName, targetSize: 360);
      if (thumbBytes != null && thumbBytes.isNotEmpty && mounted) {
        setState(() => _addToCache(fileName, thumbBytes));
      }
    } catch (e) {
      debugPrint('Failed to prefetch thumbnail for $fileName: $e');
    } finally {
      _prefetchingActive.remove(fileName);
    }
  }

  void _setActiveController(VideoPlayerController? controller) {
    if (_activeVideoController != null) {
      _activeVideoController!.removeListener(_onControllerUpdate);
    }
    _activeVideoController = controller;
    if (_activeVideoController != null) {
      _activeVideoController!.addListener(_onControllerUpdate);
      _onControllerUpdate();
    } else {
      setState(() {
        _position = Duration.zero;
        _duration = Duration.zero;
        _sliderValue = 0.0;
      });
    }
  }

  void _evictDistantControllers(int currentIndex) {
    while (_initializedControllers.length >= _maxLiveControllers) {
      int furthestIndex = -1;
      int maxDistance   = -1;
      for (final pageIndex in _initializedControllers.keys) {
        final dist = (pageIndex - currentIndex).abs();
        if (dist > maxDistance) {
          maxDistance   = dist;
          furthestIndex = pageIndex;
        }
      }
      if (furthestIndex == -1) break;
      final evicted = _initializedControllers.remove(furthestIndex);
      _subtitlesAvailableMap.remove(furthestIndex);
      if (evicted != null) {
        evicted.removeListener(_onControllerUpdate);
        Future.microtask(() {
          try { evicted.dispose(); } catch (_) {}
        });
      }
    }
  }

  void _onControllerUpdate() {
    if (_activeVideoController == null) return;
    if (_activeVideoController!.value.hasError) return;

    final isInitialized = _activeVideoController!.value.isInitialized;
    if (mounted && isInitialized) {
      setState(() {
        _position = _activeVideoController!.value.position;
        _duration = _activeVideoController!.value.duration;
        if (!_isDragging && _duration.inMilliseconds > 0) {
          _sliderValue = _position.inMilliseconds / _duration.inMilliseconds;
        }
      });
    }

    if (isInitialized && _videoPlaybackMode == VideoPlaybackMode.loop &&
        _duration > Duration.zero &&
        _position >= _duration && !_endFired) {
      _endFired = true;
      _manualLoop();
    } else if (isInitialized && _videoPlaybackMode != VideoPlaybackMode.loop &&
        _duration > Duration.zero &&
        _position >= _duration && !_endFired) {
      _endFired = true;
      if (_videoPlaybackMode == VideoPlaybackMode.playAndAdvance) {
        Future.delayed(const Duration(milliseconds: 400), () => _onMediaEnd());
      }
    }

    if (_position < _duration * 0.95) _endFired = false;
  }

  Future<void> _manualLoop() async {
    try {
      await _activeVideoController?.pause();
      await _activeVideoController?.seekTo(Duration.zero);
      await _activeVideoController?.play();
      if (mounted) setState(() { _endFired = false; });
    } catch (e) {
      debugPrint('Manual loop error: $e');
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    if (_isMenuOpen) return; // Prevent automatic dismissal if menu is open
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _activeVideoController != null &&
          _activeVideoController!.value.isPlaying && _showUI && !_isMenuOpen) {
        _setUIVisibility(false);
      }
    });
  }

  void _showControlsAndResetTimer() {
    if (!_showUI) _setUIVisibility(true);
    _startHideTimer();
  }

  @override
  void dispose() {
    _cancelSlideshowTimer();
    _hideTimer?.cancel();
    _pageController.dispose();
    if (_activeVideoController != null) {
      _activeVideoController!.removeListener(_onControllerUpdate);
    }
    for (final ctrl in _initializedControllers.values) {
      try { ctrl.dispose(); } catch (_) {}
    }
    _initializedControllers.clear();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
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

  void _toggleOrientation() {
    HapticFeedback.mediumImpact();
    setState(() => _isLandscape = !_isLandscape);
    if (_isLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
  }

  void _toggleShuffle() {
    HapticFeedback.mediumImpact();
    setState(() {
      final currentFile = _currentPlaylist[_currentIndex];
      if (!_isShuffled) {
        final shuffled = List<String>.from(_currentPlaylist)
          ..remove(currentFile)
          ..shuffle();
        shuffled.insert(0, currentFile);
        _currentPlaylist = shuffled;
        _currentIndex    = 0;
        if (_pageController.hasClients) _pageController.jumpToPage(0);
        _isShuffled = true;
      } else {
        _applyFolderFiltering(_selectedFolder, currentFile);
        _isShuffled = false;
      }
      _prefetchSurroundingItems();
    });
  }

  Future<void> _filterByFolder(String folder) async {
    if (!mounted) return;
    HapticFeedback.mediumImpact();

    setState(() {
      _selectedFolder = folder;
      final currentFile = _currentPlaylist.isNotEmpty ? _currentPlaylist[_currentIndex] : '';
      _applyFolderFiltering(folder, currentFile);
    });

    if (folder == 'All' && !_allFilesScanned) {
      setState(() => _isScanningSubfolders = true);
      try {
        final baseDir = _getBaseDir();
        final recursiveFiles = await _scanDirectoryRecursively(baseDir);

        if (mounted) {
          setState(() {
            if (recursiveFiles.isNotEmpty) {
              _originalList = List.from(recursiveFiles);
            }
            _allFilesScanned = true;
            if (_selectedFolder == 'All') {
              final currentFile = _currentPlaylist.isNotEmpty ? _currentPlaylist[_currentIndex] : '';
              _applyFolderFiltering('All', currentFile);
            }
          });
        }
      } catch (e) {
        debugPrint('Error loading subfolders: $e');
      } finally {
        if (mounted) setState(() => _isScanningSubfolders = false);
      }
    }
  }

  Future<void> _openWithApp() async {
    final currentFile = _currentPlaylist[_currentIndex];
    try {
      await vaultExplorerApi.openWithApp(widget.container, currentFile);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to open in external app: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
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

    final currentFile = _currentPlaylist[_currentIndex];
    bool success = false;
    try {
      success = await vaultExplorerApi.deleteFile(widget.container, currentFile);
    } catch (e) {
      debugPrint('Deletion error: $e');
    }

    if (success && mounted) {
      setState(() {
        _currentPlaylist.removeAt(_currentIndex);
        _originalList.remove(currentFile);
        _prefetchedImages.remove(currentFile);
        if (_currentPlaylist.isEmpty) { Navigator.pop(context); return; }
        if (_currentIndex >= _currentPlaylist.length) {
          _currentIndex = _currentPlaylist.length - 1;
        }
        if (_pageController.hasClients) {
          _pageController.jumpToPage(_currentIndex);
        }
        _prefetchSurroundingItems();
      });
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File deleted successfully')));
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Failed to delete file'),
          backgroundColor: cs.error));
    }
  }

  void _onMediaEnd() {
    _navigateToNext();
  }

  String _formatDuration(Duration d) =>
      '${d.inMinutes.remainder(60).toString().padLeft(2, '0')}'
      ':${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  IconData _getIconForFit(BoxFit fit) {
    switch (fit) {
      case BoxFit.contain:    return Icons.aspect_ratio_rounded;
      case BoxFit.fitWidth:   return Icons.swap_horiz_rounded;
      case BoxFit.fitHeight:  return Icons.swap_vert_rounded;
      default:                return Icons.aspect_ratio_rounded;
    }
  }

  Widget _buildImageFitMenu(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MenuAnchor(
      onOpen: () { _isMenuOpen = true; _hideTimer?.cancel(); },
      onClose: () { _isMenuOpen = false; _startHideTimer(); },
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(Colors.black.withValues(alpha:0.9)),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withValues(alpha:0.12)),
          ),
        ),
      ),
      builder: (ctx, controller, child) => IconButton(
        icon: Icon(_getIconForFit(_imageFit), color: cs.primary, size: 20),
        tooltip: 'Image Fit Options',
        onPressed: () {
          HapticFeedback.lightImpact();
          controller.isOpen ? controller.close() : controller.open();
        },
      ),
      menuChildren: [
        _fitMenuItem(BoxFit.contain,   'Contain (Best Fit)', Icons.aspect_ratio_rounded),
        _fitMenuItem(BoxFit.fitWidth,  'Fit to Width',       Icons.swap_horiz_rounded),
        _fitMenuItem(BoxFit.fitHeight, 'Fit to Height',      Icons.swap_vert_rounded),
      ],
    );
  }

  Widget _fitMenuItem(BoxFit fit, String label, IconData icon) {
    final isSelected = _imageFit == fit;
    return MenuItemButton(
      closeOnActivate: false, // Settings won't abruptly dismiss while clicking
      style: MenuItemButton.styleFrom(
        foregroundColor: isSelected ? Theme.of(context).colorScheme.primary : Colors.white,
      ),
      onPressed: () {
        HapticFeedback.lightImpact();
        setState(() => _imageFit = fit);
      },
      leadingIcon: Icon(icon, size: 18,
          color: isSelected ? Theme.of(context).colorScheme.primary : Colors.white70),
      child: Text(label),
    );
  }

  IconData _getIconForPlaybackMode(VideoPlaybackMode mode) {
    switch (mode) {
      case VideoPlaybackMode.playOnce:       return Icons.redo_rounded;
      case VideoPlaybackMode.loop:           return Icons.loop_rounded;
      case VideoPlaybackMode.playAndAdvance: return Icons.playlist_play_rounded;
    }
  }

  Widget _buildVideoPlaybackModeMenu(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MenuAnchor(
      onOpen: () { _isMenuOpen = true; _hideTimer?.cancel(); },
      onClose: () { _isMenuOpen = false; _startHideTimer(); },
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(Colors.black.withValues(alpha:0.9)),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withValues(alpha:0.12)),
          ),
        ),
      ),
      builder: (ctx, controller, child) => IconButton(
        icon: Icon(
          _getIconForPlaybackMode(_videoPlaybackMode),
          color: _videoPlaybackMode == VideoPlaybackMode.playOnce
              ? Colors.white70
              : cs.primary,
          size: 20,
        ),
        tooltip: 'Playback Mode',
        onPressed: () {
          HapticFeedback.lightImpact();
          controller.isOpen ? controller.close() : controller.open();
        },
      ),
      menuChildren: [
        _playbackModeItem(VideoPlaybackMode.playOnce,       'Play Once',      Icons.redo_rounded),
        _playbackModeItem(VideoPlaybackMode.loop,           'Loop Current',   Icons.loop_rounded),
        _playbackModeItem(VideoPlaybackMode.playAndAdvance, 'Play & Advance', Icons.playlist_play_rounded),
      ],
    );
  }

  Widget _playbackModeItem(VideoPlaybackMode mode, String label, IconData icon) {
    final isSelected = _videoPlaybackMode == mode;
    return MenuItemButton(
      closeOnActivate: false, // Prevents menu disappearing on touch
      style: MenuItemButton.styleFrom(
        foregroundColor: isSelected ? Theme.of(context).colorScheme.primary : Colors.white,
      ),
      onPressed: () {
        HapticFeedback.lightImpact();
        setState(() => _videoPlaybackMode = mode);
      },
      leadingIcon: Icon(icon, size: 18,
          color: isSelected ? Theme.of(context).colorScheme.primary : Colors.white70),
      child: Text(label),
    );
  }

  Widget _buildImageBottomControls(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final currentName = _currentPlaylist[_currentIndex];
    
    final bool isFirst = _currentIndex == 0;
    final bool isLast = _currentIndex == _currentPlaylist.length - 1;

    return _buildGlassDock(
      context,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _autoAdvance ? Icons.slideshow_rounded : Icons.image_rounded,
              color: _autoAdvance ? cs.primary : Colors.white70,
              size: 14,
            ),
            const SizedBox(width: 8),
            Text(
              _autoAdvance ? 'Auto-Advance Active (4s)' : 'Static Mode',
              style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildImageFitMenu(context),
                      IconButton(
                        icon: const Icon(Icons.rotate_right_rounded, color: Colors.white70, size: 20),
                        tooltip: 'Rotate 90°',
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          setState(() {
                            _rotations[currentName] = ((_rotations[currentName] ?? 0) + 1) % 4;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(Icons.skip_previous_rounded, color: isFirst ? Colors.white38 : Colors.white, size: 28),
                  onPressed: isFirst ? null : _navigateToPrev,
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _toggleAutoAdvance(!_autoAdvance),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _autoAdvance ? cs.primary : Colors.white12,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _autoAdvance ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: _autoAdvance ? cs.onPrimary : Colors.white,
                      size: 28,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.skip_next_rounded, color: isLast ? Colors.white38 : Colors.white, size: 28),
                  onPressed: isLast ? null : _navigateToNext,
                ),
              ],
            ),
            const Expanded(child: SizedBox.shrink()),
          ],
        ),
      ],
    );
  }

  Widget _buildVideoBottomControls(BuildContext context) {
    final cs           = Theme.of(context).colorScheme;
    final positionStr  = _formatDuration(_position);
    final durationStr  = _formatDuration(_duration);
    final currentName  = _currentPlaylist[_currentIndex];

    final bool isFirst = _currentIndex == 0;
    final bool isLast = _currentIndex == _currentPlaylist.length - 1;

    return _buildGlassDock(
      context,
      children: [
        Row(
          children: [
            Text(positionStr,
                style: const TextStyle(color: Colors.white70, fontSize: 11,
                    fontWeight: FontWeight.bold)),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: cs.primary,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: cs.primary,
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                  trackShape: const RectangularSliderTrackShape(),
                ),
                child: Slider(
                  value: _sliderValue.clamp(0.0, 1.0),
                  onChanged: (value) {
                    _showControlsAndResetTimer();
                    setState(() { _isDragging = true; _sliderValue = value; });
                    final now = DateTime.now();
                    if (now.difference(_lastSeekTime).inMilliseconds > 100) {
                      _lastSeekTime = now;
                      final targetMs = (value * _duration.inMilliseconds).toInt();
                      _activeVideoController?.seekTo(Duration(milliseconds: targetMs));
                    }
                  },
                  onChangeEnd: (value) {
                    final targetMs = (value * _duration.inMilliseconds).toInt();
                    _activeVideoController?.seekTo(Duration(milliseconds: targetMs))
                        .then((_) { setState(() => _isDragging = false); _startHideTimer(); });
                  },
                ),
              ),
            ),
            Text(durationStr,
                style: const TextStyle(color: Colors.white70, fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                          color: _isMuted ? cs.error : Colors.white70,
                          size: 20,
                        ),
                        tooltip: 'Mute',
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          setState(() {
                            _isMuted = !_isMuted;
                            _activeVideoController?.setVolume(_isMuted ? 0.0 : 1.0);
                          });
                        },
                      ),
                      _buildVideoPlaybackModeMenu(context),
                      IconButton(
                        icon: const Icon(Icons.rotate_right_rounded, color: Colors.white70, size: 20),
                        tooltip: 'Rotate 90°',
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          setState(() {
                            _rotations[currentName] = ((_rotations[currentName] ?? 0) + 1) % 4;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(Icons.skip_previous_rounded, color: isFirst ? Colors.white38 : Colors.white, size: 28),
                  onPressed: isFirst ? null : _navigateToPrev,
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    _showControlsAndResetTimer();
                    if (_activeVideoController != null) {
                      setState(() {
                        if (_activeVideoController!.value.isPlaying) {
                          _activeVideoController!.pause();
                        } else {
                          _activeVideoController!.play();
                        }
                      });
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
                    child: Icon(
                      (_activeVideoController?.value.isPlaying ?? false)
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: cs.onPrimary, size: 28,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.skip_next_rounded, color: isLast ? Colors.white38 : Colors.white, size: 28),
                  onPressed: isLast ? null : _navigateToNext,
                ),
              ],
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (_subtitlesAvailable)
                        IconButton(
                          icon: Icon(
                            _subtitlesEnabled ? Icons.subtitles_rounded : Icons.subtitles_off_rounded,
                            color: _subtitlesEnabled ? cs.primary : Colors.white70,
                            size: 20,
                          ),
                          tooltip: 'Subtitles',
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            setState(() => _subtitlesEnabled = !_subtitlesEnabled);
                          },
                        ),
                      _SpeedControlMenu(
                        currentSpeed: _playbackSpeed,
                        onMenuOpen: () { _isMenuOpen = true; _hideTimer?.cancel(); },
                        onMenuClose: () { _isMenuOpen = false; _startHideTimer(); },
                        onSpeedChanged: (speed) {
                          setState(() {
                            _playbackSpeed = speed;
                            _activeVideoController?.setPlaybackSpeed(speed);
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_currentPlaylist.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation<Color>(cs.primary))),
      );
    }

    final total       = _currentPlaylist.length;
    final currentName = _currentPlaylist[_currentIndex];
    final currentExt  = currentName.split('.').last.toLowerCase();
    final isCurrentAnImage =
        ['jpg','jpeg','png','gif','webp'].contains(currentExt);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView.builder(
          controller: _pageController,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: total,
          onPageChanged: (index) {
            setState(() {
              _currentIndex       = index;
              _subtitlesAvailable = _subtitlesAvailableMap[index] ?? false;
            });
            _startSlideshowTimerIfNeeded();
            _prefetchSurroundingItems();
            _setActiveController(_initializedControllers[index]);
          },
          itemBuilder: (context, index) {
            final volId       = widget.container.volId;
            final escapedPath = Uri.encodeComponent(_currentPlaylist[index]);
            final contentUriString =
                'content://com.aeidolon.vaultexplorer.documents/document/'
                '$volId%3Afile%3A$escapedPath';
            final fileName        = _currentPlaylist[index];
            final prefetchedBytes = _prefetchedImages[fileName];

            return _MediaPage(
              key: ValueKey(fileName),
              container: widget.container,
              fileName: fileName,
              contentUriString: contentUriString,
              showUI: _showUI,
              onToggleUI: _setUIVisibility,
              skipSeconds: _doubleTapSkipSeconds,
              autoPlay: _autoPlay,
              prefetchedBytes: prefetchedBytes,
              rotationQuarterTurns: _rotations[fileName] ?? 0,
              onImageLoaded: (bytes) {},
              onZoomChanged: (allowSwipe) {},
              subtitlesEnabled: _subtitlesEnabled,
              imageFit: _imageFit,
              onSubtitlesAvailableChanged: (val) {
                _subtitlesAvailableMap[index] = val;
                if (index == _currentIndex) {
                  setState(() => _subtitlesAvailable = val);
                }
              },
              onVideoControllerInitialized: (controller) {
                _evictDistantControllers(index);
                _initializedControllers[index] = controller;
                if (index == _currentIndex) {
                  _setActiveController(controller);
                }
              },
              onVideoControllerDisposed: () {
                _initializedControllers.remove(index);
                _subtitlesAvailableMap.remove(index);
                if (index == _currentIndex) {
                  _setActiveController(null);
                }
              },
            );
          },
        ),

        // ── Top action bar ────────────────────────────────────────────────
        AnimatedPositioned(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          top: _showUI ? MediaQuery.of(context).padding.top + 8 : -110,
          left: 16, right: 16,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24), // M3 smoother corner rounding
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha:0.65),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withValues(alpha:0.08)),
                ),
                child: Row(children: [
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
                        Text(currentName.split('/').last,
                            maxLines: 2, // Wrapping nicely on 2 lines prevents abrupt ellipse truncation
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14, height: 1.25,
                                fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(
                          '${_currentIndex + 1} of $total'
                          '${_isScanningSubfolders ? '  ·  scanning…' : ''}',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha:0.7), fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline_rounded, color: cs.error),
                    tooltip: 'Delete File',
                    onPressed: _deleteCurrentFile,
                  ),
                  MenuAnchor(
                    onOpen: () { _isMenuOpen = true; _hideTimer?.cancel(); },
                    onClose: () { _isMenuOpen = false; _startHideTimer(); },
                    style: MenuStyle(
                      backgroundColor: WidgetStateProperty.all(Colors.black.withValues(alpha:0.9)),
                      elevation: WidgetStateProperty.all(12),
                      shape: WidgetStateProperty.all(
                        RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                          side: BorderSide(color: Colors.white.withValues(alpha:0.12)),
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
                        onPressed: _openWithApp,
                        leadingIcon: const Icon(Icons.open_in_new_rounded, size: 18, color: Colors.white70),
                        child: const Text('Open with App'),
                      ),
                      MenuItemButton(
                        style: MenuItemButton.styleFrom(foregroundColor: Colors.white),
                        onPressed: _toggleOrientation,
                        leadingIcon: Icon(
                            _isLandscape
                                ? Icons.screen_lock_portrait_rounded
                                : Icons.screen_rotation_rounded,
                            size: 18,
                            color: Colors.white70),
                        child: Text(_isLandscape ? 'Portrait Mode' : 'Landscape Mode'),
                      ),
                      MenuItemButton(
                        style: MenuItemButton.styleFrom(foregroundColor: Colors.white),
                        onPressed: _toggleShuffle,
                        leadingIcon: Icon(Icons.shuffle_rounded,
                            size: 18,
                            color: _isShuffled ? cs.primary : Colors.white70),
                        child: Text(_isShuffled ? 'Disable Shuffle' : 'Shuffle Playlist'),
                      ),
                      const PopupMenuDivider(color: Colors.white10),
                      SubmenuButton(
                        style: SubmenuButton.styleFrom(foregroundColor: Colors.white),
                        menuStyle: MenuStyle(
                          backgroundColor: WidgetStateProperty.all(Colors.black.withValues(alpha:0.9)),
                          shape: WidgetStateProperty.all(
                            RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                              side: BorderSide(color: Colors.white.withValues(alpha:0.12)),
                            ),
                          ),
                        ),
                        menuChildren: [
                          MenuItemButton(
                            style: MenuItemButton.styleFrom(
                              foregroundColor: _selectedFolder == 'Current Folder Only'
                                  ? cs.primary : Colors.white,
                            ),
                            onPressed: () => _filterByFolder('Current Folder Only'),
                            leadingIcon: _selectedFolder == 'Current Folder Only'
                                ? Icon(Icons.check_rounded, size: 16, color: cs.primary)
                                : const SizedBox(width: 16),
                            child: const Text('Current Folder Only'),
                          ),
                          MenuItemButton(
                            style: MenuItemButton.styleFrom(
                              foregroundColor: _selectedFolder == 'All'
                                  ? cs.primary : Colors.white,
                            ),
                            onPressed: () => _filterByFolder('All'),
                            leadingIcon: _selectedFolder == 'All'
                                ? Icon(Icons.check_rounded, size: 16, color: cs.primary)
                                : const SizedBox(width: 16),
                            child: const Text('All (Incl. Subfolders)'),
                          ),
                        ],
                        child: const Text('Folder Filter'),
                      ),
                    ],
                  ),
                ]),
              ),
            ),
          ),
        ),

        // ── Bottom Controls ───────────────────────────────────────────────
        AnimatedPositioned(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          left: 0,
          right: 0,
          bottom: _showUI ? 0 : -200,
          child: isCurrentAnImage
              ? _buildImageBottomControls(context)
              : _buildVideoBottomControls(context),
        ),
      ]),
    );
  }
}

// ── Shared glassmorphic dock ──────────────────────────────────────────────────

Widget _buildGlassDock(BuildContext context, {required List<Widget> children}) {
  return Container(
    margin: EdgeInsets.only(
      left: 16,
      right: 16,
      bottom: MediaQuery.of(context).padding.bottom + 16,
    ),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(28), // Sleek M3 pill-shaped borders
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha:0.4),
          blurRadius: 24,
          offset: const Offset(0, 12),
        )
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha:0.55),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha:0.08)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    ),
  );
}

// ── _MediaPage ────────────────────────────────────────────────────────────────

class _MediaPage extends StatefulWidget {
  final MountedContainer container;
  final String fileName;
  final String contentUriString;
  final bool showUI;
  final ValueChanged<bool> onToggleUI;
  final ValueChanged<bool> onZoomChanged;
  final int skipSeconds;
  final bool autoPlay;
  final Uint8List? prefetchedBytes;
  final ValueChanged<Uint8List> onImageLoaded;
  final int rotationQuarterTurns;
  final bool subtitlesEnabled;
  final BoxFit imageFit;
  final ValueChanged<bool> onSubtitlesAvailableChanged;
  final ValueChanged<VideoPlayerController> onVideoControllerInitialized;
  final VoidCallback onVideoControllerDisposed;

  const _MediaPage({
    Key? key,
    required this.container,
    required this.fileName,
    required this.contentUriString,
    required this.showUI,
    required this.onToggleUI,
    required this.onZoomChanged,
    required this.skipSeconds,
    required this.autoPlay,
    required this.prefetchedBytes,
    required this.onImageLoaded,
    required this.rotationQuarterTurns,
    required this.subtitlesEnabled,
    required this.imageFit,
    required this.onSubtitlesAvailableChanged,
    required this.onVideoControllerInitialized,
    required this.onVideoControllerDisposed,
  }) : super(key: key);

  @override
  State<_MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<_MediaPage> {
  final TransformationController _transformationController =
      TransformationController();
  double _scale = 1.0;
  TapDownDetails? _doubleTapDetails;

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  void _handleDoubleTap() {
    final position = _doubleTapDetails?.localPosition;
    setState(() {
      if (_scale == 1.0) {
        _scale = 2.5;
        if (position != null) {
          final x = -position.dx * (_scale - 1);
          final y = -position.dy * (_scale - 1);
          _transformationController.value = Matrix4.identity()
            ..translate(x, y)
            ..scale(_scale);
        } else {
          _transformationController.value =
              Matrix4.identity()..scale(_scale);
        }
        widget.onZoomChanged(false);
      } else {
        _scale = 1.0;
        _transformationController.value = Matrix4.identity();
        widget.onZoomChanged(true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ext   = widget.fileName.split('.').last.toLowerCase();
    final isImg = ['jpg','jpeg','png','gif','webp'].contains(ext);
    final isAudio = ['mp3','m4a','wav','flac','ogg','aac'].contains(ext);

    return Container(
      color: Colors.black,
      child: isImg
          ? GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => widget.onToggleUI(!widget.showUI),
              onDoubleTapDown: (d) => _doubleTapDetails = d,
              onDoubleTap: _handleDoubleTap,
              child: SizedBox.expand(
                child: InteractiveViewer(
                  transformationController: _transformationController,
                  maxScale: 4.0,
                  onInteractionUpdate: (details) {
                    final s =
                        _transformationController.value.getMaxScaleOnAxis();
                    if (s != _scale) {
                      setState(() => _scale = s);
                      widget.onZoomChanged(s <= 1.01);
                    }
                  },
                  onInteractionEnd: (details) {
                    final s =
                        _transformationController.value.getMaxScaleOnAxis();
                    if (s <= 1.01) widget.onZoomChanged(true);
                  },
                  child: Center(
                    child: RotatedBox(
                      quarterTurns: widget.rotationQuarterTurns,
                      child: EncryptedImageWidget(
                        container: widget.container,
                        fileName: widget.fileName,
                        prefetchedBytes: widget.prefetchedBytes,
                        onImageLoaded: widget.onImageLoaded,
                        fit: widget.imageFit,
                      ),
                    ),
                  ),
                ),
              ),
            )
          : MediaPlayerWidget(
              container: widget.container,
              fileName: widget.fileName,
              contentUriString: widget.contentUriString,
              showUI: widget.showUI,
              onToggleUI: widget.onToggleUI,
              skipSeconds: widget.skipSeconds,
              autoPlay: widget.autoPlay,
              isAudio: isAudio,
              subtitlesEnabled: widget.subtitlesEnabled,
              rotationQuarterTurns: widget.rotationQuarterTurns, // Added rotation pass-through for Videos
              onSubtitlesAvailableChanged: widget.onSubtitlesAvailableChanged,
              onZoomChanged: widget.onZoomChanged,
              onVideoControllerInitialized: widget.onVideoControllerInitialized,
              onVideoControllerDisposed: widget.onVideoControllerDisposed,
            ),
    );
  }
}

// ── EncryptedImageWidget ──────────────────────────────────────────────────────

class EncryptedImageWidget extends StatefulWidget {
  final MountedContainer container;
  final String fileName;
  final Uint8List? prefetchedBytes;
  final ValueChanged<Uint8List> onImageLoaded;
  final BoxFit fit;

  const EncryptedImageWidget({
    Key? key,
    required this.container,
    required this.fileName,
    this.prefetchedBytes,
    required this.onImageLoaded,
    required this.fit,
  }) : super(key: key);

  @override
  State<EncryptedImageWidget> createState() => _EncryptedImageWidgetState();
}

class _EncryptedImageWidgetState extends State<EncryptedImageWidget> {
  Uint8List? _bytes;
  String? _error;
  bool _isFullResLoaded = false;

  @override
  void initState() {
    super.initState();
    if (widget.prefetchedBytes != null) {
      _bytes = widget.prefetchedBytes;
    }
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant EncryptedImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fileName != oldWidget.fileName) {
      _isFullResLoaded = false;
      _bytes = widget.prefetchedBytes;
      _error = null;
      _loadImage();
    } else if (!_isFullResLoaded && widget.prefetchedBytes != null && _bytes == null) {
      setState(() => _bytes = widget.prefetchedBytes);
    }
  }

  Future<void> _loadImage() async {
    try {
      final size = await vaultExplorerApi.getFileSize(
          widget.container, widget.fileName);
      if (size <= 0) throw Exception('File is empty');
      
      final data = await vaultExplorerApi.readFileChunk(
          widget.container, widget.fileName, 0, size);
      if (data == null || data.isEmpty) throw Exception('No content bytes');
      
      if (mounted) {
        setState(() {
          _bytes = data;
          _isFullResLoaded = true;
        });
        widget.onImageLoaded(data);
      }
    } catch (e) {
      if (mounted && _bytes == null) {
        setState(() => _error = 'Failed to load encrypted image: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(_error!,
              style: TextStyle(color: cs.error, fontSize: 13)),
        ),
      );
    }
    if (_bytes == null) {
      return Center(
        child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation<Color>(cs.primary)),
      );
    }
    return Image.memory(_bytes!,
        fit: widget.fit,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) => Center(
          child: Text('Invalid image format.',
              style: TextStyle(color: cs.error)),
        ));
  }
}

// ── Audio Visualizer ──────────────────────────────────────────────────────────

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
        vsync: this, duration: const Duration(milliseconds: 1200));
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
  void dispose() { _controller.dispose(); super.dispose(); }

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
                  color: cs.primary, borderRadius: BorderRadius.circular(3)),
            );
          }),
        ),
      ),
    );
  }
}

// ── Speed Selector Menu ───────────────────────────────────────────────────────

class _SpeedControlMenu extends StatelessWidget {
  final double currentSpeed;
  final ValueChanged<double> onSpeedChanged;
  final VoidCallback onMenuOpen;
  final VoidCallback onMenuClose;

  const _SpeedControlMenu({
    Key? key,
    required this.currentSpeed,
    required this.onSpeedChanged,
    required this.onMenuOpen,
    required this.onMenuClose,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MenuAnchor(
      onOpen: onMenuOpen,
      onClose: onMenuClose,
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(Colors.black.withValues(alpha:0.9)),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withValues(alpha:0.12)),
          ),
        ),
      ),
      builder: (ctx, controller, child) => IconButton(
        icon: Text(
          '${currentSpeed}x',
          style: const TextStyle(
            color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold,
          ),
        ),
        tooltip: 'Playback Speed',
        onPressed: () {
          HapticFeedback.lightImpact();
          controller.isOpen ? controller.close() : controller.open();
        },
      ),
      menuChildren: [0.5, 1.0, 1.25, 1.5, 2.0].map((speed) =>
        MenuItemButton(
          closeOnActivate: false, // Prevents menu dismissing immediately while rapid-testing speeds
          style: MenuItemButton.styleFrom(
            foregroundColor: currentSpeed == speed ? cs.primary : Colors.white,
          ),
          onPressed: () {
            HapticFeedback.lightImpact();
            onSpeedChanged(speed);
          },
          leadingIcon: currentSpeed == speed
              ? Icon(Icons.check_rounded, size: 16, color: cs.primary)
              : const SizedBox(width: 16),
          child: Text('${speed}x'),
        )).toList(),
    );
  }
}

// ── MediaPlayerWidget ─────────────────────────────────────────────────────────

class MediaPlayerWidget extends StatefulWidget {
  final MountedContainer container;
  final String fileName;
  final String contentUriString;
  final bool showUI;
  final ValueChanged<bool> onToggleUI;
  final int skipSeconds;
  final ValueChanged<bool> onZoomChanged;
  final bool autoPlay;
  final bool isAudio;
  final bool subtitlesEnabled;
  final int rotationQuarterTurns;
  final ValueChanged<bool> onSubtitlesAvailableChanged;
  final ValueChanged<VideoPlayerController> onVideoControllerInitialized;
  final VoidCallback onVideoControllerDisposed;

  const MediaPlayerWidget({
    Key? key,
    required this.container,
    required this.fileName,
    required this.contentUriString,
    required this.showUI,
    required this.onToggleUI,
    required this.skipSeconds,
    required this.onZoomChanged,
    required this.autoPlay,
    required this.isAudio,
    required this.subtitlesEnabled,
    required this.rotationQuarterTurns,
    required this.onSubtitlesAvailableChanged,
    required this.onVideoControllerInitialized,
    required this.onVideoControllerDisposed,
  }) : super(key: key);

  @override
  State<MediaPlayerWidget> createState() => _MediaPlayerWidgetState();
}

class _MediaPlayerWidgetState extends State<MediaPlayerWidget> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  String? _playerError;

  bool _showLeftIndicator  = false;
  bool _showRightIndicator = false;
  bool _isSpeedHeld        = false;
  bool _localMuted         = false;

  final TransformationController _videoTransformationController =
      TransformationController();
  double _videoScale = 1.0;
  TapDownDetails? _videoDoubleTapDetails;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<ClosedCaptionFile?> _loadCaptions(String videoPath) async {
    final dotIndex = videoPath.lastIndexOf('.');
    if (dotIndex == -1) return null;
    final basePath = videoPath.substring(0, dotIndex);
    for (final ext in ['srt', 'vtt']) {
      final subPath = '$basePath.$ext';
      try {
        final size = await vaultExplorerApi.getFileSize(
            widget.container, subPath);
        if (size > 0) {
          final data = await vaultExplorerApi.readFileChunk(
              widget.container, subPath, 0, size);
          if (data != null && data.isNotEmpty) {
            final text = utf8.decode(data, allowMalformed: true);
            if (mounted) widget.onSubtitlesAvailableChanged(true);
            return ext == 'srt'
                ? SubRipCaptionFile(text)
                : WebVTTCaptionFile(text);
          }
        }
      } catch (_) {}
    }
    if (mounted) widget.onSubtitlesAvailableChanged(false);
    return null;
  }

  Future<void> _initPlayer() async {
    _controller = VideoPlayerController.contentUri(
        Uri.parse(widget.contentUriString));

    _controller.addListener(() {
      if (mounted) setState(() {});
    });

    try {
      final captionFile = await _loadCaptions(widget.fileName);
      if (captionFile != null && mounted) {
        _controller.setClosedCaptionFile(Future.value(captionFile));
      }
      await _controller.initialize();
      if (mounted) {
        setState(() { _initialized = true; });
        widget.onVideoControllerInitialized(_controller);
        await _controller.setVolume(_localMuted ? 0.0 : 1.0);
        await _controller.setLooping(false);
        if (widget.autoPlay) {
          _controller.play();
          widget.onToggleUI(true);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _playerError =
            'Media stream initialization failed: $e');
      }
    }
  }

  @override
  void dispose() {
    widget.onVideoControllerDisposed();
    _videoTransformationController.dispose();
    try { _controller.dispose(); } catch (_) {}
    super.dispose();
  }

  void _onSpeedHoldStart(LongPressStartDetails _) {
    if (!_initialized) return;
    HapticFeedback.heavyImpact();
    _controller.setPlaybackSpeed(2.0);
    setState(() => _isSpeedHeld = true);
    widget.onToggleUI(false);
  }

  void _onSpeedHoldEnd(LongPressEndDetails _) {
    if (!_initialized) return;
    _controller.setPlaybackSpeed(1.0);
    setState(() => _isSpeedHeld = false);
    widget.onToggleUI(true);
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
          _videoTransformationController.value =
              Matrix4.identity()..scale(_videoScale);
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
    final duration   = _controller.value.duration;
    final targetPos  = backwards
        ? currentPos - Duration(seconds: widget.skipSeconds)
        : currentPos + Duration(seconds: widget.skipSeconds);
    final clampedPos = targetPos < Duration.zero
        ? Duration.zero
        : (targetPos > duration ? duration : targetPos);
    _controller.seekTo(clampedPos);
    setState(() {
      if (backwards) { _showLeftIndicator  = true; }
      else           { _showRightIndicator = true; }
    });
    Timer(const Duration(milliseconds: 550), () {
      if (mounted) {
        setState(() { _showLeftIndicator = false; _showRightIndicator = false; });
      }
    });
  }

  Widget _buildAudioCenterVisual() {
    final cs        = Theme.of(context).colorScheme;
    final fileTitle = widget.fileName.split('/').last;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 130, height: 130,
          decoration: BoxDecoration(
            color: const Color(0xFF161B22),
            shape: BoxShape.circle,
            border: Border.all(color: cs.primary.withValues(alpha:0.25), width: 2),
          ),
          child: Center(child: Icon(Icons.music_note_rounded,
              size: 56, color: cs.primary)),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Text(fileTitle,
              style: const TextStyle(color: Colors.white, fontSize: 15,
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(height: 24),
        _AudioVisualizer(isPlaying: _controller.value.isPlaying),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_playerError != null) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline_rounded, color: cs.error, size: 36),
          const SizedBox(height: 12),
          Text(_playerError!,
              style: TextStyle(color: cs.error, fontSize: 13),
              textAlign: TextAlign.center),
        ]),
      ));
    }

    if (!_initialized) {
      return Center(child: CircularProgressIndicator(
          strokeWidth: 2.5,
          valueColor: AlwaysStoppedAnimation<Color>(cs.primary)));
    }

    // Determine correct Aspect Ratio accounting for manual video rotation inversion constraints
    final isRotated = widget.rotationQuarterTurns % 2 != 0;
    final double computedAspectRatio = widget.isAudio 
        ? 0.8 
        : (isRotated 
            ? 1.0 / _controller.value.aspectRatio 
            : _controller.value.aspectRatio);

    Widget corePlayerWidget = Center(
      child: AspectRatio(
        aspectRatio: computedAspectRatio,
        child: Stack(alignment: Alignment.center, children: [
          if (widget.isAudio)
            _buildAudioCenterVisual()
          else
            RotatedBox(
              quarterTurns: widget.rotationQuarterTurns,
              child: VideoPlayer(_controller),
            ),
          
          if (!widget.isAudio && _controller.value.isInitialized && widget.subtitlesEnabled)
            Positioned(
              bottom: widget.showUI ? 130 : 25,
              left: 20, right: 20,
              child: ClosedCaption(
                text: _controller.value.caption.text,
                textStyle: const TextStyle(fontSize: 15, color: Colors.white,
                    shadows: [
                      Shadow(blurRadius: 4, color: Colors.black,
                          offset: Offset(1, 1))
                    ]),
              ),
            ),
          
          Row(children: [
            Expanded(flex: 3,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => widget.onToggleUI(!widget.showUI),
                onDoubleTap: () => _skip(backwards: true),
                onLongPressStart: _onSpeedHoldStart,
                onLongPressEnd: _onSpeedHoldEnd,
                child: Container(),
              )),
            Expanded(flex: 4,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => widget.onToggleUI(!widget.showUI),
                onDoubleTapDown: (d) => _videoDoubleTapDetails = d,
                onDoubleTap: _handleVideoDoubleTap,
                onLongPressStart: _onSpeedHoldStart,
                onLongPressEnd: _onSpeedHoldEnd,
                child: Container(),
              )),
            Expanded(flex: 3,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => widget.onToggleUI(!widget.showUI),
                onDoubleTap: () => _skip(backwards: false),
                onLongPressStart: _onSpeedHoldStart,
                onLongPressEnd: _onSpeedHoldEnd,
                child: Container(),
              )),
          ]),
        ]),
      ),
    );

    if (!widget.isAudio) {
      corePlayerWidget = InteractiveViewer(
        transformationController: _videoTransformationController,
        maxScale: 6.0, minScale: 1.0, clipBehavior: Clip.none,
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
      child: Stack(clipBehavior: Clip.none, alignment: Alignment.center,
        children: [
          corePlayerWidget,
          if (_showLeftIndicator)
            Positioned(left: 45,
              child: IgnorePointer(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha:0.55),
                    borderRadius: BorderRadius.circular(30)),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.fast_rewind_rounded, color: Colors.white, size: 28),
                  const SizedBox(height: 4),
                  Text('-${widget.skipSeconds}s',
                      style: const TextStyle(color: Colors.white, fontSize: 11,
                          fontWeight: FontWeight.bold)),
                ]),
              ))),
          if (_showRightIndicator)
            Positioned(right: 45,
              child: IgnorePointer(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha:0.55),
                    borderRadius: BorderRadius.circular(30)),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.fast_forward_rounded, color: Colors.white, size: 28),
                  const SizedBox(height: 4),
                  Text('+${widget.skipSeconds}s',
                      style: const TextStyle(color: Colors.white, fontSize: 11,
                          fontWeight: FontWeight.bold)),
                ]),
              ))),
          if (_isSpeedHeld)
            Positioned(top: 100,
              child: IgnorePointer(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha:0.65),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: cs.primary.withValues(alpha:0.6), width: 1),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.fast_forward_rounded, color: cs.primary, size: 16),
                  const SizedBox(width: 6),
                  Text('2× speed', style: TextStyle(color: cs.primary, fontSize: 13,
                      fontWeight: FontWeight.w700, letterSpacing: 0.3)),
                ]),
              ))),
        ],
      ),
    );
  }
}