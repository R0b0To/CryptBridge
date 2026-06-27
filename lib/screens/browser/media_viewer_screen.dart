import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../../models/mounted_container.dart';
import '../../services/vaultexplorer_api.dart';

bool _autoPlay    = true;
bool _autoAdvance = false;

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
  bool _showUI     = true;
  bool _isLandscape = false;

  late List<String> _originalList;
  late List<String> _currentPlaylist;
  bool _isShuffled = false;

  String _selectedFolder        = 'Current Folder Only';
  int    _doubleTapSkipSeconds  = 5;

  bool _allFilesScanned    = false;
  bool _isScanningSubfolders = false;
  Timer? _slideshowTimer;
  BoxFit _imageFit = BoxFit.contain;

  final Map<String, Uint8List> _prefetchedImages = {};
  final Set<String> _prefetchingActive = {};

  bool   _isMuted           = false;
  bool   _isLooping         = false;
  double _playbackSpeed     = 1.0;
  bool   _subtitlesEnabled  = true;
  bool   _subtitlesAvailable = false;

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

  Future<void> _loadRecursiveMedia() async {
    final baseDir        = _getBaseDir();
    final recursiveFiles = await _scanDirectoryRecursively(baseDir);
    if (recursiveFiles.isEmpty) return;
    if (mounted) setState(() => _originalList = List.from(recursiveFiles));
  }

  Future<List<String>> _scanDirectoryRecursively(String baseDir) async {
    final foundFiles  = <String>[];
    final subdirNames = <String>[];
    try {
      final items =
          await vaultExplorerApi.listDirectory(widget.container, baseDir);
      if (items != null) {
        for (final item in items) {
          if (item.startsWith('[DIR] ')) {
            subdirNames.add(item.replaceFirst('[DIR] ', ''));
          } else if (!item.startsWith('System:')) {
            final fileName = item.split('|').first;
            if (_isSupportedMedia(fileName)) {
              final fullPath =
                  baseDir.isEmpty ? fileName : '$baseDir/$fileName';
              foundFiles.add(fullPath);
            }
          }
        }
        if (subdirNames.isNotEmpty) {
          final nested = await Future.wait(subdirNames.map((name) {
            final subPath =
                baseDir.isEmpty ? name : '$baseDir/$name';
            return _scanDirectoryRecursively(subPath);
          }));
          for (final list in nested) foundFiles.addAll(list);
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
        _pageController.jumpToPage(_currentIndex);
      }
      _prefetchSurroundingItems();
    }
  }

  void _navigateToNext() {
    _cancelSlideshowTimer();
    if (_currentIndex < _currentPlaylist.length - 1) {
      _pageController.animateToPage(_currentIndex + 1,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut);
    }
  }

  void _navigateToPrev() {
    _cancelSlideshowTimer();
    if (_currentIndex > 0) {
      _pageController.animateToPage(_currentIndex - 1,
          duration: const Duration(milliseconds: 350),
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
    if (next < _currentPlaylist.length) _prefetchFile(_currentPlaylist[next]);
    if (prev >= 0)                       _prefetchFile(_currentPlaylist[prev]);
  }

  Future<void> _prefetchFile(String fileName) async {
    if (_prefetchedImages.containsKey(fileName) ||
        _prefetchingActive.contains(fileName)) return;
    final ext = fileName.split('.').last.toLowerCase();
    if (!['jpg','jpeg','png','gif','webp'].contains(ext)) return;

    _prefetchingActive.add(fileName);
    try {
      final size = await vaultExplorerApi.getFileSize(widget.container, fileName);
      if (size > 0) {
        final data = await vaultExplorerApi.readFileChunk(
            widget.container, fileName, 0, size);
        if (data != null && data.isNotEmpty && mounted) {
          setState(() => _addToCache(fileName, data));
        }
      }
    } catch (e) {
      debugPrint('Failed to prefetch $fileName: $e');
    } finally {
      _prefetchingActive.remove(fileName);
    }
  }

  @override
  void dispose() {
    _cancelSlideshowTimer();
    _pageController.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  void _setUIVisibility(bool show) {
    if (mounted) {
      setState(() => _showUI = show);
      if (show) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    }
  }

  void _toggleOrientation() {
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
    if (folder == 'All' && !_allFilesScanned) {
      if (mounted) setState(() => _isScanningSubfolders = true);
      await _loadRecursiveMedia();
      _allFilesScanned = true;
      if (mounted) setState(() => _isScanningSubfolders = false);
    }
    if (!mounted) return;
    setState(() {
      _selectedFolder  = folder;
      final currentFile = _currentPlaylist[_currentIndex];
      _applyFolderFiltering(folder, currentFile);
    });
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
    if (!_autoAdvance) return;
    _navigateToNext();
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
              _currentIndex      = index;
              _subtitlesAvailable = false;
            });
            _startSlideshowTimerIfNeeded();
            _prefetchSurroundingItems();
          },
          itemBuilder: (context, index) {
            final volId       = widget.container.volId;
            final escapedPath =
                Uri.encodeComponent(_currentPlaylist[index]);
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
              autoAdvance: _autoAdvance,
              prefetchedBytes: prefetchedBytes,
              onImageLoaded: (bytes) => _addToCache(fileName, bytes),
              onAutoPlayChanged:    (val) => setState(() => _autoPlay = val),
              onAutoAdvanceChanged: _toggleAutoAdvance,
              onSkipSecondsChanged: (val) =>
                  setState(() => _doubleTapSkipSeconds = val),
              onMediaEnd: _onMediaEnd,
              onNext: _navigateToNext,
              onPrev: _navigateToPrev,
              isMuted: _isMuted,
              isLooping: _isLooping,
              playbackSpeed: _playbackSpeed,
              subtitlesEnabled: _subtitlesEnabled,
              imageFit: _imageFit,
              onSubtitlesAvailableChanged: (val) =>
                  setState(() => _subtitlesAvailable = val),
              onZoomChanged: (allowSwipe) {},
            );
          },
        ),

        // ── Navigation chevrons ────────────────────────────────────────────
        if (_showUI) ...[
          if (_currentIndex > 0)
            Positioned(
              left: 16, top: 0, bottom: 0,
              child: Center(
                child: Container(
                  decoration: const BoxDecoration(
                      color: Colors.black38, shape: BoxShape.circle),
                  child: IconButton(
                    icon: const Icon(Icons.chevron_left_rounded,
                        color: Colors.white, size: 36),
                    tooltip: 'Previous',
                    onPressed: _navigateToPrev,
                  ),
                ),
              ),
            ),
          if (_currentIndex < total - 1)
            Positioned(
              right: 16, top: 0, bottom: 0,
              child: Center(
                child: Container(
                  decoration: const BoxDecoration(
                      color: Colors.black38, shape: BoxShape.circle),
                  child: IconButton(
                    icon: const Icon(Icons.chevron_right_rounded,
                        color: Colors.white, size: 36),
                    tooltip: 'Next',
                    onPressed: _navigateToNext,
                  ),
                ),
              ),
            ),
        ],

        // ── Top action bar ─────────────────────────────────────────────────
        AnimatedPositioned(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          top: _showUI ? 0 : -100,
          left: 0, right: 0,
          child: Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 8,
              bottom: 12, left: 8, right: 8,
            ),
            color: Colors.black.withOpacity(0.7),
            child: Row(children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded,
                    color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(currentName.split('/').last,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      '${_currentIndex + 1} of $total'
                      '${_isScanningSubfolders ? '  ·  scanning…' : ''}',
                      style: const TextStyle(
                          color: Color(0xFF7A8899), fontSize: 11),
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
                builder: (ctx, controller, child) => IconButton(
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  icon: Icon(
                    isCurrentAnImage
                        ? Icons.more_vert_rounded
                        : Icons.settings_rounded,
                    color: Colors.white,
                  ),
                  tooltip: isCurrentAnImage
                      ? 'More Actions'
                      : 'Playback Settings',
                ),
                menuChildren: [
                  MenuItemButton(
                    onPressed: _openWithApp,
                    leadingIcon:
                        const Icon(Icons.open_in_new_rounded, size: 18),
                    child: const Text('Open with App'),
                  ),
                  MenuItemButton(
                    onPressed: _toggleOrientation,
                    leadingIcon: Icon(
                        _isLandscape
                            ? Icons.screen_lock_portrait_rounded
                            : Icons.screen_rotation_rounded,
                        size: 18),
                    child: Text(_isLandscape
                        ? 'Portrait Mode'
                        : 'Landscape Mode'),
                  ),
                  MenuItemButton(
                    onPressed: _toggleShuffle,
                    leadingIcon: Icon(Icons.shuffle_rounded,
                        size: 18,
                        color: _isShuffled ? cs.primary : cs.onSurfaceVariant),
                    child: Text(_isShuffled
                        ? 'Disable Shuffle'
                        : 'Shuffle Playlist'),
                  ),
                  const PopupMenuDivider(),
                  SubmenuButton(
                    menuChildren: [
                      MenuItemButton(
                        onPressed: () =>
                            _filterByFolder('Current Folder Only'),
                        leadingIcon: _selectedFolder == 'Current Folder Only'
                            ? Icon(Icons.check_rounded,
                                size: 16, color: cs.primary)
                            : const SizedBox(width: 16),
                        child: const Text('Current Folder Only'),
                      ),
                      MenuItemButton(
                        onPressed: () => _filterByFolder('All'),
                        leadingIcon: _selectedFolder == 'All'
                            ? Icon(Icons.check_rounded,
                                size: 16, color: cs.primary)
                            : const SizedBox(width: 16),
                        child: const Text('All (Incl. Subfolders)'),
                      ),
                    ],
                    child: const Text('Folder Filter'),
                  ),
                  if (isCurrentAnImage) ...[
                    const PopupMenuDivider(),
                    SubmenuButton(
                      menuChildren: [
                        _fitItem(context, BoxFit.contain, 'Best Fit (Contain)'),
                        _fitItem(context, BoxFit.fitWidth, 'Fit to Width'),
                        _fitItem(context, BoxFit.fitHeight, 'Fit to Height'),
                      ],
                      child: const Text('Image Display Fit'),
                    ),
                    const PopupMenuDivider(),
                    MenuItemButton(
                      onPressed: () => _toggleAutoAdvance(!_autoAdvance),
                      leadingIcon: Icon(Icons.skip_next_rounded,
                          size: 18,
                          color: _autoAdvance
                              ? cs.primary
                              : cs.onSurfaceVariant),
                      child: Text(_autoAdvance
                          ? 'Auto-advance: On'
                          : 'Auto-advance: Off'),
                    ),
                  ],
                  if (!isCurrentAnImage) ...[
                    const PopupMenuDivider(),
                    SubmenuButton(
                      menuChildren: [
                        MenuItemButton(
                          onPressed: () =>
                              setState(() => _isLooping = !_isLooping),
                          leadingIcon: Icon(Icons.loop_rounded,
                              size: 18,
                              color: _isLooping ? cs.primary : cs.onSurfaceVariant),
                          child: Text(_isLooping
                              ? 'Looping: On'
                              : 'Looping: Off'),
                        ),
                        MenuItemButton(
                          onPressed: () =>
                              setState(() => _isMuted = !_isMuted),
                          leadingIcon: Icon(
                              _isMuted
                                  ? Icons.volume_off_rounded
                                  : Icons.volume_up_rounded,
                              size: 18,
                              color: _isMuted ? cs.error : cs.onSurfaceVariant),
                          child: Text(_isMuted ? 'Muted: On' : 'Muted: Off'),
                        ),
                        MenuItemButton(
                          onPressed: () =>
                              setState(() => _autoPlay = !_autoPlay),
                          leadingIcon: Icon(
                              _autoPlay
                                  ? Icons.play_circle_filled_rounded
                                  : Icons.play_circle_outline_rounded,
                              size: 18,
                              color: _autoPlay ? cs.primary : cs.onSurfaceVariant),
                          child: Text(
                              _autoPlay ? 'Auto-play: On' : 'Auto-play: Off'),
                        ),
                        MenuItemButton(
                          onPressed: () =>
                              _toggleAutoAdvance(!_autoAdvance),
                          leadingIcon: Icon(Icons.skip_next_rounded,
                              size: 18,
                              color: _autoAdvance
                                  ? cs.primary
                                  : cs.onSurfaceVariant),
                          child: Text(_autoAdvance
                              ? 'Auto-advance: On'
                              : 'Auto-advance: Off'),
                        ),
                        if (_subtitlesAvailable)
                          MenuItemButton(
                            onPressed: () => setState(
                                () => _subtitlesEnabled = !_subtitlesEnabled),
                            leadingIcon: Icon(
                                _subtitlesEnabled
                                    ? Icons.subtitles_rounded
                                    : Icons.subtitles_off_rounded,
                                size: 18,
                                color: _subtitlesEnabled
                                    ? cs.primary
                                    : cs.onSurfaceVariant),
                            child: Text(_subtitlesEnabled
                                ? 'Subtitles: On'
                                : 'Subtitles: Off'),
                          ),
                      ],
                      child: const Text('Playback Behavior'),
                    ),
                    const PopupMenuDivider(),
                    SubmenuButton(
                      menuChildren: [0.5, 1.0, 1.25, 1.5, 2.0].map((speed) =>
                        MenuItemButton(
                          onPressed: () =>
                              setState(() => _playbackSpeed = speed),
                          leadingIcon: _playbackSpeed == speed
                              ? Icon(Icons.check_rounded,
                                  size: 16, color: cs.primary)
                              : const SizedBox(width: 16),
                          child: Text('${speed}x'),
                        )).toList(),
                      child:
                          Text('Playback Speed (${_playbackSpeed}x)'),
                    ),
                    SubmenuButton(
                      menuChildren: [5, 10, 15, 30].map((s) =>
                        MenuItemButton(
                          onPressed: () =>
                              setState(() => _doubleTapSkipSeconds = s),
                          leadingIcon: _doubleTapSkipSeconds == s
                              ? Icon(Icons.check_rounded,
                                  size: 16, color: cs.primary)
                              : const SizedBox(width: 16),
                          child: Text('$s seconds'),
                        )).toList(),
                      child: Text(
                          'Double-Tap Seek (${_doubleTapSkipSeconds}s)'),
                    ),
                  ],
                ],
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  MenuItemButton _fitItem(
      BuildContext context, BoxFit fit, String label) {
    final cs = Theme.of(context).colorScheme;
    return MenuItemButton(
      onPressed: () => setState(() => _imageFit = fit),
      leadingIcon: _imageFit == fit
          ? Icon(Icons.check_rounded, size: 16, color: cs.primary)
          : const SizedBox(width: 16),
      child: Text(label),
    );
  }
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
  final bool autoAdvance;
  final Uint8List? prefetchedBytes;
  final ValueChanged<Uint8List> onImageLoaded;
  final ValueChanged<bool> onAutoPlayChanged;
  final ValueChanged<bool> onAutoAdvanceChanged;
  final ValueChanged<int> onSkipSecondsChanged;
  final VoidCallback onMediaEnd;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final bool isMuted;
  final bool isLooping;
  final double playbackSpeed;
  final bool subtitlesEnabled;
  final BoxFit imageFit;
  final ValueChanged<bool> onSubtitlesAvailableChanged;

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
    required this.autoAdvance,
    required this.prefetchedBytes,
    required this.onImageLoaded,
    required this.onAutoPlayChanged,
    required this.onAutoAdvanceChanged,
    required this.onSkipSecondsChanged,
    required this.onMediaEnd,
    required this.onNext,
    required this.onPrev,
    required this.isMuted,
    required this.isLooping,
    required this.playbackSpeed,
    required this.subtitlesEnabled,
    required this.imageFit,
    required this.onSubtitlesAvailableChanged,
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
              onTap: () => widget.onToggleUI(!widget.showUI),
              onDoubleTapDown: (d) => _doubleTapDetails = d,
              onDoubleTap: _handleDoubleTap,
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
                child: SizedBox.expand(
                  child: EncryptedImageWidget(
                    container: widget.container,
                    fileName: widget.fileName,
                    prefetchedBytes: widget.prefetchedBytes,
                    onImageLoaded: widget.onImageLoaded,
                    fit: widget.imageFit,
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
              autoAdvance: widget.autoAdvance,
              isAudio: isAudio,
              onAutoPlayChanged: widget.onAutoPlayChanged,
              onAutoAdvanceChanged: widget.onAutoAdvanceChanged,
              onSkipSecondsChanged: widget.onSkipSecondsChanged,
              onMediaEnd: widget.onMediaEnd,
              onNext: widget.onNext,
              onPrev: widget.onPrev,
              isMuted: widget.isMuted,
              isLooping: widget.isLooping,
              playbackSpeed: widget.playbackSpeed,
              subtitlesEnabled: widget.subtitlesEnabled,
              onSubtitlesAvailableChanged: widget.onSubtitlesAvailableChanged,
              onZoomChanged: widget.onZoomChanged,
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

  @override
  void initState() {
    super.initState();
    if (widget.prefetchedBytes != null) {
      _bytes = widget.prefetchedBytes;
    } else {
      _loadImage();
    }
  }

  @override
  void didUpdateWidget(covariant EncryptedImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.prefetchedBytes != null && _bytes == null) {
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
        setState(() => _bytes = data);
        widget.onImageLoaded(data);
      }
    } catch (e) {
      if (mounted)
        setState(() => _error = 'Failed to load encrypted image: $e');
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
  final bool autoAdvance;
  final bool isAudio;
  final ValueChanged<bool> onAutoPlayChanged;
  final ValueChanged<bool> onAutoAdvanceChanged;
  final ValueChanged<int> onSkipSecondsChanged;
  final VoidCallback onMediaEnd;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final bool isMuted;
  final bool isLooping;
  final double playbackSpeed;
  final bool subtitlesEnabled;
  final ValueChanged<bool> onSubtitlesAvailableChanged;

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
    required this.autoAdvance,
    required this.isAudio,
    required this.onAutoPlayChanged,
    required this.onAutoAdvanceChanged,
    required this.onSkipSecondsChanged,
    required this.onMediaEnd,
    required this.onNext,
    required this.onPrev,
    required this.isMuted,
    required this.isLooping,
    required this.playbackSpeed,
    required this.subtitlesEnabled,
    required this.onSubtitlesAvailableChanged,
  }) : super(key: key);

  @override
  State<MediaPlayerWidget> createState() => _MediaPlayerWidgetState();
}

class _MediaPlayerWidgetState extends State<MediaPlayerWidget> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  String? _playerError;

  Duration _position     = Duration.zero;
  Duration _duration     = Duration.zero;
  double _sliderValue    = 0.0;
  bool _isDragging       = false;

  Timer? _hideTimer;
  DateTime _lastSeekTime = DateTime.now();

  bool _showLeftIndicator  = false;
  bool _showRightIndicator = false;
  bool _isSpeedHeld        = false;
  bool _endFired           = false;

  final TransformationController _videoTransformationController =
      TransformationController();
  double _videoScale = 1.0;
  TapDownDetails? _videoDoubleTapDetails;

  @override
  void initState() { super.initState(); _initPlayer(); }

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
    _controller.addListener(_onControllerUpdate);
    try {
      final captionFile = await _loadCaptions(widget.fileName);
      if (captionFile != null && mounted) {
        _controller.setClosedCaptionFile(Future.value(captionFile));
      }
      await _controller.initialize();
      if (mounted) {
        setState(() {
          _initialized = true;
          _duration    = _controller.value.duration;
        });
        await _controller.setVolume(widget.isMuted ? 0.0 : 1.0);
        await _controller.setLooping(widget.isLooping);
        await _controller.setPlaybackSpeed(widget.playbackSpeed);
        if (widget.autoPlay) { _controller.play(); _startHideTimer(); }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _playerError =
            'Media stream initialization failed: $e');
      }
    }
  }

  void _onControllerUpdate() {
    if (_controller.value.hasError) {
      if (mounted) {
        setState(() => _playerError =
            _controller.value.errorDescription ?? 'Native media player error.');
      }
      return;
    }
    if (mounted && _initialized) {
      setState(() {
        _position = _controller.value.position;
        _duration = _controller.value.duration;
        if (!_isDragging && _duration.inMilliseconds > 0) {
          _sliderValue = _position.inMilliseconds / _duration.inMilliseconds;
        }
      });
    }
    if (_initialized && !widget.isLooping && _duration > Duration.zero &&
        _position >= _duration && !_endFired) {
      _endFired = true;
      Future.delayed(const Duration(milliseconds: 400),
          () => widget.onMediaEnd());
    }
    if (_position < _duration * 0.95) _endFired = false;
  }

  @override
  void didUpdateWidget(covariant MediaPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isMuted != widget.isMuted) {
      _controller.setVolume(widget.isMuted ? 0.0 : 1.0);
    }
    if (oldWidget.isLooping != widget.isLooping) {
      _controller.setLooping(widget.isLooping);
    }
    if (oldWidget.playbackSpeed != widget.playbackSpeed) {
      _controller.setPlaybackSpeed(widget.playbackSpeed);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _videoTransformationController.dispose();
    _controller.removeListener(_onControllerUpdate);
    try { _controller.dispose(); } catch (_) {}
    super.dispose();
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _controller.value.isPlaying && widget.showUI) {
        widget.onToggleUI(false);
      }
    });
  }

  void _showControlsAndResetTimer() {
    if (!widget.showUI) widget.onToggleUI(true);
    _startHideTimer();
  }

  void _onSpeedHoldStart(LongPressStartDetails _) {
    if (!_initialized) return;
    _controller.setPlaybackSpeed(2.0);
    widget.onToggleUI(false);
    _hideTimer?.cancel();
  }

  void _onSpeedHoldEnd(LongPressEndDetails _) {
    if (!_initialized) return;
    _controller.setPlaybackSpeed(widget.playbackSpeed);
    _showControlsAndResetTimer();
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
    _showControlsAndResetTimer();
    final currentPos = _controller.value.position;
    final targetPos  = backwards
        ? currentPos - Duration(seconds: widget.skipSeconds)
        : currentPos + Duration(seconds: widget.skipSeconds);
    final clampedPos = targetPos < Duration.zero
        ? Duration.zero
        : (targetPos > _duration ? _duration : targetPos);
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

  String _formatDuration(Duration d) =>
      '${d.inMinutes.remainder(60).toString().padLeft(2, '0')}'
      ':${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

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
            border: Border.all(color: cs.primary.withOpacity(0.25), width: 2),
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

    Widget corePlayerWidget = Center(
      child: AspectRatio(
        aspectRatio:
            widget.isAudio ? 0.8 : _controller.value.aspectRatio,
        child: Stack(alignment: Alignment.center, children: [
          if (widget.isAudio)
            _buildAudioCenterVisual()
          else
            VideoPlayer(_controller),
          if (!widget.isAudio && _controller.value.isInitialized &&
              widget.subtitlesEnabled)
            Positioned(
              bottom: widget.showUI ? 110 : 25,
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
                onTap: () { widget.onToggleUI(!widget.showUI);
                  if (!widget.showUI) _startHideTimer(); },
                onDoubleTap: () => _skip(backwards: true),
                onLongPressStart: _onSpeedHoldStart,
                onLongPressEnd: _onSpeedHoldEnd,
                child: Container(),
              )),
            Expanded(flex: 4,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () { widget.onToggleUI(!widget.showUI);
                  if (!widget.showUI) _startHideTimer(); },
                onDoubleTapDown: (d) => _videoDoubleTapDetails = d,
                onDoubleTap: _handleVideoDoubleTap,
                onLongPressStart: _onSpeedHoldStart,
                onLongPressEnd: _onSpeedHoldEnd,
                child: Container(),
              )),
            Expanded(flex: 3,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () { widget.onToggleUI(!widget.showUI);
                  if (!widget.showUI) _startHideTimer(); },
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
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.55),
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
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.55),
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
            Positioned(top: 20,
              child: IgnorePointer(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: cs.primary.withOpacity(0.6), width: 1),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.fast_forward_rounded, color: cs.primary, size: 16),
                  const SizedBox(width: 6),
                  Text('2× speed', style: TextStyle(color: cs.primary, fontSize: 13,
                      fontWeight: FontWeight.w700, letterSpacing: 0.3)),
                ]),
              ))),
          _bottomControls(context),
          if (widget.showUI)
            Center(child: GestureDetector(
              onTap: () {
                _showControlsAndResetTimer();
                setState(() { _controller.value.isPlaying
                    ? _controller.pause()
                    : _controller.play(); });
              },
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                    color: Colors.black45, shape: BoxShape.circle),
                child: Icon(
                  _controller.value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white, size: 44,
                ),
              ),
            )),
        ],
      ),
    );
  }

  Widget _bottomControls(BuildContext context) {
    final cs           = Theme.of(context).colorScheme;
    final positionStr  = _formatDuration(_position);
    final durationStr  = _formatDuration(_duration);

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      left: 0, right: 0,
      bottom: widget.showUI ? 0 : -140,
      child: Container(
        padding: EdgeInsets.only(
          top: 8,
          bottom: MediaQuery.of(context).padding.bottom + 12,
          left: 16, right: 16,
        ),
        color: Colors.black.withOpacity(0.65),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          Align(alignment: Alignment.centerLeft,
            child: Text('$positionStr / $durationStr',
                style: const TextStyle(color: Colors.white, fontSize: 12,
                    fontWeight: FontWeight.w500))),
          const SizedBox(height: 4),
          SliderTheme(
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
                  _controller.seekTo(Duration(milliseconds: targetMs));
                }
              },
              onChangeEnd: (value) {
                final targetMs = (value * _duration.inMilliseconds).toInt();
                _controller.seekTo(Duration(milliseconds: targetMs))
                    .then((_) { setState(() => _isDragging = false); _startHideTimer(); });
              },
            ),
          ),
        ]),
      ),
    );
  }
}