import 'dart:io';
import 'dart:async'; 
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:video_player/video_player.dart';
import '../../models/mounted_container.dart';
import '../../services/vaultexplorer_api.dart';

class MediaViewerScreen extends StatefulWidget {
  final MountedContainer container;
  final List<String> mediaFiles;
  final int initialIndex;

  const MediaViewerScreen({
    Key? key,
    required this.container,
    required this.mediaFiles,
    required this.initialIndex,
  }) : super(key: key);

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  late PageController _pageController;
  late int _currentIndex;
  bool _showUI = true;
  bool _isLandscape = false; 

  // Stateful Playlist and Settings
  late List<String> _originalList;
  late List<String> _currentPlaylist;
  bool _isShuffled = false;
  
  // Default filter mode is strictly "Current Folder Only"
  String _selectedFolder = 'Current Folder Only';
  int _doubleTapSkipSeconds = 5; 

  ScrollPhysics _pagePhysics = const ClampingScrollPhysics();

  _LocalStreamingServer? _streamingServer;
  int? _serverPort;
  bool _serverReady = false;

  @override
  void initState() {
    super.initState();
    _originalList = List.from(widget.mediaFiles);
    _currentPlaylist = List.from(widget.mediaFiles);
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    
    _startServer();
    
    // Background scanning for recursive files in subfolders
    _loadRecursiveMedia();
  }

  String _getBaseDir() {
    final firstFile = widget.mediaFiles.first;
    if (!firstFile.contains('/')) {
      return '';
    }
    return firstFile.substring(0, firstFile.lastIndexOf('/'));
  }

  bool _isSupportedMedia(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return ['jpg','jpeg','png','gif','webp','mp4','m4v','webm','mov','avi','mkv']
        .contains(ext);
  }

  // Quiet background scanning for subfolders starting from the current directory
  Future<void> _loadRecursiveMedia() async {
    final baseDir = _getBaseDir();
    final recursiveFiles = await _scanDirectoryRecursively(baseDir);
    
    if (recursiveFiles.isEmpty) return;

    if (mounted) {
      setState(() {
        final currentFile = _currentPlaylist[_currentIndex];
        
        // originalList caches all recursive media files found
        _originalList = List.from(recursiveFiles);

        // Keep current item playing while updating swiper database
        _applyFolderFiltering(_selectedFolder, currentFile);
      });
    }
  }

  Future<List<String>> _scanDirectoryRecursively(String baseDir) async {
    List<String> foundFiles = [];
    try {
      final items = await vaultexplorerApi.listDirectory(widget.container, baseDir);
      if (items != null) {
        for (final item in items) {
          if (item.startsWith('[DIR] ')) {
            final subDirName = item.replaceFirst('[DIR] ', '');
            final subDirPath = baseDir.isEmpty ? subDirName : '$baseDir/$subDirName';
            final nested = await _scanDirectoryRecursively(subDirPath);
            foundFiles.addAll(nested);
          } else if (!item.startsWith('System:')) {
            final fileName = item.split('|').first;
            if (_isSupportedMedia(fileName)) {
              final fullPath = baseDir.isEmpty ? fileName : '$baseDir/$fileName';
              foundFiles.add(fullPath);
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Error walking subdirectories: $e");
    }
    return foundFiles;
  }

  void _applyFolderFiltering(String folder, String currentFile) {
    final baseDir = _getBaseDir();
    List<String> filteredList;

    if (folder == 'All') {
      filteredList = List.from(_originalList);
    } else {
      // Current Folder Only: limit files directly to base directory
      filteredList = _originalList.where((file) {
        final dir = file.contains('/') ? file.substring(0, file.lastIndexOf('/')) : '';
        return dir == baseDir;
      }).toList();
    }

    int newIndex = filteredList.indexOf(currentFile);
    if (newIndex == -1) {
      newIndex = 0;
    }

    if (filteredList.isNotEmpty) {
      _currentPlaylist = filteredList;
      _currentIndex = newIndex;
      _pageController.jumpToPage(_currentIndex);
    }
  }

  Future<void> _startServer() async {
    _streamingServer = _LocalStreamingServer(widget.container);
    final port = await _streamingServer!.start();
    if (mounted) {
      setState(() {
        _serverPort = port;
        _serverReady = true;
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _streamingServer?.stop();
    
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  void _setUIVisibility(bool show) {
    if (mounted) {
      setState(() {
        _showUI = show;
      });
      if (show) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    }
  }

  void _toggleOrientation() {
    setState(() {
      _isLandscape = !_isLandscape;
    });
    if (_isLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  // Shuffle Playlist logic without losing current item position
  void _toggleShuffle() {
    setState(() {
      final currentFile = _currentPlaylist[_currentIndex];
      if (!_isShuffled) {
        final List<String> shuffled = List.from(_currentPlaylist);
        shuffled.remove(currentFile);
        shuffled.shuffle();
        shuffled.insert(0, currentFile); 
        _currentPlaylist = shuffled;
        _currentIndex = 0;
        _pageController.jumpToPage(0);
        _isShuffled = true;
      } else {
        _applyFolderFiltering(_selectedFolder, currentFile);
        _isShuffled = false;
      }
    });
  }

  // Filter viewport by selection
  void _filterByFolder(String folder) {
    setState(() {
      _selectedFolder = folder;
      final currentFile = _currentPlaylist[_currentIndex];
      _applyFolderFiltering(folder, currentFile);
    });
  }

  // External launcher bridge
  Future<void> _openWithApp() async {
    final currentFile = _currentPlaylist[_currentIndex];
    try {
      await vaultexplorerApi.openWithApp(widget.container, currentFile);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to open file in external app: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Safe Deletion & Viewport Re-index
  Future<void> _deleteCurrentFile() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Delete file?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This action is permanent and cannot be undone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final currentFile = _currentPlaylist[_currentIndex];
      bool success = false;

      try {
        success = await vaultexplorerApi.deleteFile(widget.container, currentFile);
      } catch (e) {
        debugPrint("Error executing API deletion: $e");
      }

      if (success && mounted) {
        setState(() {
          _currentPlaylist.removeAt(_currentIndex);
          _originalList.remove(currentFile);
          
          if (_currentPlaylist.isEmpty) {
            Navigator.pop(context);
            return;
          }
          if (_currentIndex >= _currentPlaylist.length) {
            _currentIndex = _currentPlaylist.length - 1;
          }
          _pageController.jumpToPage(_currentIndex);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File deleted successfully')),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete file'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _exportCurrentFile() async {
    final fileName = _currentPlaylist[_currentIndex];
    final publicDownloads = Directory('/storage/emulated/0/Download');
    if (!await publicDownloads.exists()) {
      await publicDownloads.create(recursive: true);
    }
    final destPath = '${publicDownloads.path}/$fileName';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Exporting $fileName…')),
    );

    try {
      final success = await vaultexplorerApi.decryptFile(
        widget.container,
        fileName,
        destPath,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success
                ? 'Saved to Downloads/$fileName'
                : 'Export failed'),
            backgroundColor: success ? const Color(0xFF1A3A2A) : null,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_serverReady) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF4FC3F7)),
          ),
        ),
      );
    }

    if (_currentPlaylist.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF4FC3F7)),
          ),
        ),
      );
    }

    final total = _currentPlaylist.length;
    final currentName = _currentPlaylist[_currentIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Media Swiper
          PageView.builder(
            controller: _pageController,
            physics: _pagePhysics,
            itemCount: total,
            onPageChanged: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            itemBuilder: (context, index) {
              final streamUrl = 'http://127.0.0.1:$_serverPort/media?file=${_currentPlaylist[index]}';
              return _MediaPage(
                fileName: _currentPlaylist[index],
                streamUrl: streamUrl,
                showUI: _showUI,
                onToggleUI: _setUIVisibility,
                skipSeconds: _doubleTapSkipSeconds,
                onZoomChanged: (allowSwipe) {
                  setState(() {
                    _pagePhysics = allowSwipe 
                        ? const ClampingScrollPhysics() 
                        : const NeverScrollableScrollPhysics();
                  });
                },
              );
            },
          ),

          // Top Action Bar
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            top: _showUI ? 0 : -100,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 8,
                bottom: 12,
                left: 8,
                right: 8,
              ),
              color: Colors.black.withOpacity(0.7),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          currentName.split('/').last,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_currentIndex + 1} of $total',
                          style: const TextStyle(
                            color: Color(0xFF7A8899),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Filter selection
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.folder_open, color: Colors.white),
                    tooltip: 'Set Directory Filter',
                    onSelected: _filterByFolder,
                    itemBuilder: (context) {
                      return [
                        PopupMenuItem<String>(
                          value: 'Current Folder Only',
                          child: Row(
                            children: [
                              Icon(
                                Icons.folder_shared,
                                color: _selectedFolder == 'Current Folder Only' ? const Color(0xFF4FC3F7) : Colors.grey,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              const Text('Current Folder Only'),
                            ],
                          ),
                        ),
                        PopupMenuItem<String>(
                          value: 'All',
                          child: Row(
                            children: [
                              Icon(
                                Icons.all_inclusive,
                                color: _selectedFolder == 'All' ? const Color(0xFF4FC3F7) : Colors.grey,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              const Text('All (Incl. Subfolders)'),
                            ],
                          ),
                        ),
                      ];
                    },
                  ),
                  // Shuffle Playlist Toggle
                  IconButton(
                    icon: Icon(
                      Icons.shuffle,
                      color: _isShuffled ? const Color(0xFF4FC3F7) : Colors.white,
                    ),
                    tooltip: 'Shuffle Playlist',
                    onPressed: _toggleShuffle,
                  ),
                  IconButton(
                    icon: Icon(
                      _isLandscape ? Icons.screen_lock_portrait : Icons.screen_rotation,
                      color: Colors.white,
                    ),
                    tooltip: 'Toggle Fullscreen Rotation',
                    onPressed: _toggleOrientation,
                  ),
                  IconButton(
                    icon: const Icon(Icons.download_outlined, color: Colors.white),
                    tooltip: 'Export to Downloads',
                    onPressed: _exportCurrentFile,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    tooltip: 'Delete File',
                    onPressed: _deleteCurrentFile,
                  ),
                  // Settings & General Options Menu
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, color: Colors.white),
                    tooltip: 'More Actions',
                    onSelected: (value) {
                      if (value == 'open_with') {
                        _openWithApp();
                      } else if (value.startsWith('skip_')) {
                        final seconds = int.parse(value.split('_')[1]);
                        setState(() {
                          _doubleTapSkipSeconds = seconds;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Double-tap skip set to ${seconds}s')),
                        );
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem<String>(
                        value: 'open_with',
                        child: Row(
                          children: [
                            Icon(Icons.open_in_new, size: 18),
                            SizedBox(width: 8),
                            Text('Open with App'),
                          ],
                        ),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem<String>(
                        enabled: false,
                        child: Text(
                          'Seek Skip Settings',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).disabledColor,
                          ),
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'skip_5',
                        child: Text('Skip 5s (Default) ${_doubleTapSkipSeconds == 5 ? '✓' : ''}'),
                      ),
                      PopupMenuItem<String>(
                        value: 'skip_10',
                        child: Text('Skip 10s ${_doubleTapSkipSeconds == 10 ? '✓' : ''}'),
                      ),
                      PopupMenuItem<String>(
                        value: 'skip_15',
                        child: Text('Skip 15s ${_doubleTapSkipSeconds == 15 ? '✓' : ''}'),
                      ),
                      PopupMenuItem<String>(
                        value: 'skip_30',
                        child: Text('Skip 30s ${_doubleTapSkipSeconds == 30 ? '✓' : ''}'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// _MediaPage — routes images vs videos
// ─────────────────────────────────────────────

class _MediaPage extends StatefulWidget {
  final String fileName;
  final String streamUrl;
  final bool showUI;
  final ValueChanged<bool> onToggleUI;
  final ValueChanged<bool> onZoomChanged; 
  final int skipSeconds;

  const _MediaPage({
    Key? key,
    required this.fileName,
    required this.streamUrl,
    required this.showUI,
    required this.onToggleUI,
    required this.onZoomChanged,
    required this.skipSeconds,
  }) : super(key: key);

  @override
  State<_MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<_MediaPage> {
  final TransformationController _transformationController = TransformationController();
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
          _transformationController.value = Matrix4.identity()..scale(_scale);
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
    final ext = widget.fileName.split('.').last.toLowerCase();
    final isImg = ['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext);

    return Container(
      color: Colors.black,
      child: isImg
          ? GestureDetector(
              onTap: () => widget.onToggleUI(!widget.showUI), 
              onDoubleTapDown: (details) {
                _doubleTapDetails = details;
              },
              onDoubleTap: _handleDoubleTap,
              child: InteractiveViewer(
                transformationController: _transformationController,
                maxScale: 4.0,
                onInteractionUpdate: (details) {
                  final newScale = _transformationController.value.getMaxScaleOnAxis();
                  if (newScale != _scale) {
                    setState(() {
                      _scale = newScale;
                    });
                    widget.onZoomChanged(newScale <= 1.01);
                  }
                },
                onInteractionEnd: (details) {
                  final newScale = _transformationController.value.getMaxScaleOnAxis();
                  if (newScale <= 1.01) {
                    widget.onZoomChanged(true);
                  }
                },
                child: Center(
                  child: Image.network(
                    widget.streamUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => const Center(
                      child: Text('Failed to stream image.', style: TextStyle(color: Colors.red)),
                    ),
                  ),
                ),
              ),
            )
          : RealVideoPlayerWidget(
              streamUrl: widget.streamUrl,
              showUI: widget.showUI,
              onToggleUI: widget.onToggleUI,
              skipSeconds: widget.skipSeconds,
              onZoomChanged: widget.onZoomChanged,
            ),
    );
  }
}

// ─────────────────────────────────────────────
// Real Video Player with hold-to-speed-up
// ─────────────────────────────────────────────

class RealVideoPlayerWidget extends StatefulWidget {
  final String streamUrl;
  final bool showUI;
  final ValueChanged<bool> onToggleUI;
  final int skipSeconds;
  final ValueChanged<bool> onZoomChanged; 

  const RealVideoPlayerWidget({
    Key? key,
    required this.streamUrl,
    required this.showUI,
    required this.onToggleUI,
    required this.skipSeconds,
    required this.onZoomChanged,
  }) : super(key: key);

  @override
  State<RealVideoPlayerWidget> createState() => _RealVideoPlayerWidgetState();
}

class _RealVideoPlayerWidgetState extends State<RealVideoPlayerWidget> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  String? _playerError;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _sliderValue = 0.0;
  bool _isDragging = false;

  Timer? _hideTimer;
  DateTime _lastSeekTime = DateTime.now();

  // On-Screen skip indicators
  bool _showLeftIndicator = false;
  bool _showRightIndicator = false;

  // ── 2× speed-hold state ──────────────────────────────────────────
  // True while the user is pressing and holding the video area.
  bool _isSpeedHeld = false;

  // Video Zoom State
  final TransformationController _videoTransformationController = TransformationController();
  double _videoScale = 1.0;
  TapDownDetails? _videoDoubleTapDetails;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      _controller = VideoPlayerController.networkUrl(Uri.parse(widget.streamUrl));
    } catch (e) {
      _controller = VideoPlayerController.network(widget.streamUrl);
    }
    
    _controller.addListener(() {
      if (_controller.value.hasError) {
        if (mounted) {
          setState(() {
            _playerError = _controller.value.errorDescription ?? "ExoPlayer stream error.";
          });
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
    });

    try {
      await _controller.initialize();
      if (mounted) {
        setState(() {
          _initialized = true;
          _duration = _controller.value.duration;
        });
        _controller.play();
        _startHideTimer(); 
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _playerError = "Stream initialization failed: $e";
        });
      }
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _videoTransformationController.dispose();
    if (_initialized) {
      _controller.dispose();
    }
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
    if (!widget.showUI) {
      widget.onToggleUI(true); 
    }
    _startHideTimer();
  }

  // ── Speed-hold handlers ──────────────────────────────────────────

  /// Called when the user starts a long-press anywhere on the video canvas.
  void _onSpeedHoldStart(LongPressStartDetails _) {
    if (!_initialized) return;
    setState(() => _isSpeedHeld = true);
    _controller.setPlaybackSpeed(2.0);
    // Hide the controls while holding so the indicator has room to breathe.
    widget.onToggleUI(false);
    _hideTimer?.cancel();
  }

  /// Called when the finger is lifted after a long-press.
  void _onSpeedHoldEnd(LongPressEndDetails _) {
    if (!_initialized) return;
    setState(() => _isSpeedHeld = false);
    _controller.setPlaybackSpeed(1.0);
    // Restore controls briefly so the user can see the seek bar again.
    _showControlsAndResetTimer();
  }

  // ── Zoom logic ───────────────────────────────────────────────────

  void _handleVideoDoubleTap() {
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
          _videoTransformationController.value = Matrix4.identity()..scale(_videoScale);
        }
        widget.onZoomChanged(false); 
      } else {
        _videoScale = 1.0;
        _videoTransformationController.value = Matrix4.identity();
        widget.onZoomChanged(true); 
      }
    });
  }

  // ── Skip ─────────────────────────────────────────────────────────

  void _skip({required bool backwards}) {
    _showControlsAndResetTimer();
    final currentPos = _controller.value.position;
    final targetPos = backwards 
        ? currentPos - Duration(seconds: widget.skipSeconds)
        : currentPos + Duration(seconds: widget.skipSeconds);
    
    final clampedPos = targetPos < Duration.zero 
        ? Duration.zero 
        : (targetPos > _duration ? _duration : targetPos);
        
    _controller.seekTo(clampedPos);

    setState(() {
      if (backwards) {
        _showLeftIndicator = true;
      } else {
        _showRightIndicator = true;
      }
    });

    Timer(const Duration(milliseconds: 550), () {
      if (mounted) {
        setState(() {
          if (backwards) {
            _showLeftIndicator = false;
          } else {
            _showRightIndicator = false;
          }
        });
      }
    });
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  @override
  Widget build(BuildContext context) {
    if (_playerError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Color(0xFFEF5350), size: 36),
              const SizedBox(height: 12),
              Text(
                _playerError!,
                style: const TextStyle(color: Color(0xFFEF5350), fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (!_initialized) {
      return const Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF4FC3F7)),
        ),
      );
    }

    return ClipRect(
      child: Stack(
        clipBehavior: Clip.none, 
        alignment: Alignment.center,
        children: [
          // ── Video canvas with zoom ──────────────────────────────────
          InteractiveViewer(
            transformationController: _videoTransformationController,
            maxScale: 6.0,
            minScale: 1.0,
            clipBehavior: Clip.none, 
            onInteractionUpdate: (details) {
              final newScale = _videoTransformationController.value.getMaxScaleOnAxis();
              if (newScale != _videoScale) {
                setState(() {
                  _videoScale = newScale;
                });
                widget.onZoomChanged(newScale <= 1.01);
              }
            },
            onInteractionEnd: (details) {
              final newScale = _videoTransformationController.value.getMaxScaleOnAxis();
              if (newScale <= 1.01) {
                widget.onZoomChanged(true);
              }
            },
            child: Center(
              child: AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    VideoPlayer(_controller),

                    // ── Gesture zones overlay ─────────────────────────
                    // GestureDetector is split into three horizontal zones
                    // (left skip / middle zoom+hold / right skip).
                    // onLongPressStart/End on all three zones so the user
                    // can hold anywhere on the frame to trigger 2× speed.
                    Row(
                      children: [
                        // Left zone — double-tap to skip back, hold for 2×
                        Expanded(
                          flex: 3,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: () {
                              widget.onToggleUI(!widget.showUI); 
                              if (!widget.showUI) _startHideTimer();
                            },
                            onDoubleTap: () => _skip(backwards: true),
                            onLongPressStart: _onSpeedHoldStart,
                            onLongPressEnd: _onSpeedHoldEnd,
                            child: Container(),
                          ),
                        ),

                        // Middle zone — double-tap to zoom, hold for 2×
                        Expanded(
                          flex: 4,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: () {
                              widget.onToggleUI(!widget.showUI); 
                              if (!widget.showUI) _startHideTimer();
                            },
                            onDoubleTapDown: (details) {
                              _videoDoubleTapDetails = details;
                            },
                            onDoubleTap: _handleVideoDoubleTap,
                            onLongPressStart: _onSpeedHoldStart,
                            onLongPressEnd: _onSpeedHoldEnd,
                            child: Container(),
                          ),
                        ),

                        // Right zone — double-tap to skip forward, hold for 2×
                        Expanded(
                          flex: 3,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: () {
                              widget.onToggleUI(!widget.showUI); 
                              if (!widget.showUI) _startHideTimer();
                            },
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
            ),
          ),

          // ── Left skip indicator ─────────────────────────────────────
          if (_showLeftIndicator)
            Positioned(
              left: 45,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.fast_rewind, color: Colors.white, size: 28),
                      const SizedBox(height: 4),
                      Text('-${widget.skipSeconds}s',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ),

          // ── Right skip indicator ────────────────────────────────────
          if (_showRightIndicator)
            Positioned(
              right: 45,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.fast_forward, color: Colors.white, size: 28),
                      const SizedBox(height: 4),
                      Text('+${widget.skipSeconds}s',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ),

          // ── 2× speed indicator (shown while holding) ────────────────
          if (_isSpeedHeld)
            Positioned(
              top: 20,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.65),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFF4FC3F7).withOpacity(0.6),
                      width: 1,
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.fast_forward_rounded,
                          color: Color(0xFF4FC3F7), size: 16),
                      SizedBox(width: 6),
                      Text(
                        '2× speed',
                        style: TextStyle(
                          color: Color(0xFF4FC3F7),
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

          // ── Seekbar control panel ───────────────────────────────────
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            left: 0,
            right: 0,
            bottom: widget.showUI ? 0 : -100, 
            child: Container(
              padding: EdgeInsets.only(
                top: 8,
                bottom: MediaQuery.of(context).padding.bottom + 8,
                left: 16,
                right: 16,
              ),
              color: Colors.black.withOpacity(0.6),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                      size: 20,
                    ),
                    onPressed: () {
                      _showControlsAndResetTimer();
                      setState(() {
                        _controller.value.isPlaying
                            ? _controller.pause()
                            : _controller.play();
                      });
                    },
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatDuration(_position),
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: const Color(0xFF4FC3F7),
                        inactiveTrackColor: const Color(0xFF2A3040),
                        thumbColor: const Color(0xFF4FC3F7),
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                      ),
                      child: Slider(
                        value: _sliderValue.clamp(0.0, 1.0),
                        onChanged: (value) {
                          _showControlsAndResetTimer();
                          setState(() {
                            _isDragging = true;
                            _sliderValue = value;
                          });
                          
                          final now = DateTime.now();
                          if (now.difference(_lastSeekTime).inMilliseconds > 100) {
                            _lastSeekTime = now;
                            final targetMs = (value * _duration.inMilliseconds).toInt();
                            _controller.seekTo(Duration(milliseconds: targetMs));
                          }
                        },
                        onChangeEnd: (value) {
                          final targetMs = (value * _duration.inMilliseconds).toInt();
                          _controller.seekTo(Duration(milliseconds: targetMs)).then((_) {
                            setState(() {
                              _isDragging = false;
                            });
                            _startHideTimer();
                          });
                        },
                      ),
                    ),
                  ),
                  Text(
                    _formatDuration(_duration),
                    style: const TextStyle(color: Color(0xFF7A8899), fontSize: 11),
                  ),
                ],
              ),
            ),
          ),

          // ── Centre play/pause button ────────────────────────────────
          if (widget.showUI)
            Center(
              child: GestureDetector(
                onTap: () {
                  _showControlsAndResetTimer();
                  setState(() {
                    _controller.value.isPlaying
                        ? _controller.pause()
                        : _controller.play();
                  });
                },
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Local HTTP streaming server
// ─────────────────────────────────────────────

class _LocalStreamingServer {
  HttpServer? _server;
  final MountedContainer container;

  _LocalStreamingServer(this.container);

  Future<int> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest);
    return _server!.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }

  void _handleRequest(HttpRequest request) async {
    try {
      if (request.method != 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }

      final fileName = request.uri.queryParameters['file'];
      if (fileName == null) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }

      final fileSize = await vaultexplorerApi.getFileSize(container, fileName);
      if (fileSize <= 0) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final headers = request.response.headers;
      headers.set(HttpHeaders.contentTypeHeader, _getMimeType(fileName));
      headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);

      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final parts = rangeHeader.substring(6).split('-');
        final start = int.tryParse(parts[0]) ?? 0;
        var end = parts.length > 1 && parts[1].isNotEmpty
            ? int.tryParse(parts[1]) ?? (fileSize - 1)
            : (fileSize - 1);

        if (end >= fileSize) {
          end = fileSize - 1;
        }

        final contentLength = end - start + 1;
        request.response.statusCode = HttpStatus.partialContent;
        headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$fileSize');
        headers.set(HttpHeaders.contentLengthHeader, contentLength.toString());

        var currentPosition = start;
        const chunkSize = 524288;

        while (currentPosition <= end) {
          final remaining = end - currentPosition + 1;
          final currentChunkSize = remaining < chunkSize ? remaining : chunkSize;

          final bytes = await vaultexplorerApi.readFileChunk(
            container,
            fileName,
            currentPosition,
            currentChunkSize,
          );

          if (bytes == null || bytes.isEmpty) break;

          request.response.add(bytes);
          await request.response.flush();

          currentPosition += bytes.length;
        }
      } else {
        headers.set(HttpHeaders.contentLengthHeader, fileSize.toString());
        request.response.statusCode = HttpStatus.ok;

        var currentPosition = 0;
        const chunkSize = 131072;

        while (currentPosition < fileSize) {
          final remaining = fileSize - currentPosition;
          final currentChunkSize = remaining < chunkSize ? remaining : chunkSize;

          final bytes = await vaultexplorerApi.readFileChunk(
            container,
            fileName,
            currentPosition,
            currentChunkSize,
          );

          if (bytes == null || bytes.isEmpty) break;

          request.response.add(bytes);
          await request.response.flush();

          currentPosition += bytes.length;
        }
      }
    } catch (e, stack) {
      debugPrint('STREAM SERVER EXCEPTION: $e');
      debugPrint('$stack');
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  String _getMimeType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'mp4':
      case 'm4v':  return 'video/mp4';
      case 'webm': return 'video/webm';
      case 'mkv':  return 'video/x-matroska';
      case 'mov':  return 'video/quicktime';
      case 'avi':  return 'video/x-msvideo';
      case 'png':  return 'image/png';
      case 'jpg':
      case 'jpeg': return 'image/jpeg';
      case 'webp': return 'image/webp';
      case 'gif':  return 'image/gif';
      default:     return 'application/octet-stream';
    }
  }
}