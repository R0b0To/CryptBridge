import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'media_viewer_constants.dart';

class VideoPlaybackManager {
  final Map<int, VideoPlayerController> _controllers = {};
  final Map<int, bool> _subtitlesAvailableMap = {};

  final ValueNotifier<VideoPlayerController?> activeControllerNotifier =
      ValueNotifier<VideoPlayerController?>(null);

  VideoPlayerController? get activeController => activeControllerNotifier.value;

  VideoPlayerController? getController(int index) => _controllers[index];

  bool isSubtitleAvailable(int index) => _subtitlesAvailableMap[index] ?? false;

  void registerController({
    required int index,
    required VideoPlayerController controller,
    required bool currentFocus,
  }) {
    _evictDistantControllers(index);
    _controllers[index] = controller;

    if (currentFocus) {
      activeControllerNotifier.value = controller;
    }
  }

  void updateSubtitleStatus(int index, bool available) {
    _subtitlesAvailableMap[index] = available;
  }

  void handlePageChange(int newIndex) {
    activeControllerNotifier.value = _controllers[newIndex];
  }

  /// Explicitly halts any video stream other than the focus controller to prevent cross-page audio leaks.
  void pauseAllExcept(VideoPlayerController keepActive) {
    for (final ctrl in _controllers.values) {
      if (ctrl != keepActive) {
        try {
          ctrl.pause();
        } catch (_) {}
      }
    }
  }

  void handleDisposed(int index) {
    _controllers.remove(index);
    _subtitlesAvailableMap.remove(index);
    if (activeControllerNotifier.value == _controllers[index]) {
      activeControllerNotifier.value = null;
    }
  }

  void _evictDistantControllers(int currentIndex) {
    while (_controllers.length >=
        MediaViewerConstants.maxLiveVideoControllers) {
      int furthestIndex = -1;
      int maxDistance = -1;

      for (final pageIndex in _controllers.keys) {
        final dist = (pageIndex - currentIndex).abs();
        if (dist > maxDistance) {
          maxDistance = dist;
          furthestIndex = pageIndex;
        }
      }

      if (furthestIndex == -1) break;
      final evicted = _controllers.remove(furthestIndex);
      _subtitlesAvailableMap.remove(furthestIndex);

      if (evicted != null) {
        Future.microtask(() {
          try {
            evicted.dispose();
          } catch (e) {
            debugPrint('Failed evicting video controller safely: $e');
          }
        });
      }
    }
  }

  void dispose() {
    activeControllerNotifier.dispose();
    for (final ctrl in _controllers.values) {
      try {
        ctrl.dispose();
      } catch (_) {}
    }
    _controllers.clear();
    _subtitlesAvailableMap.clear();
  }
}
