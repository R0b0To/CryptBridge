import 'package:flutter/foundation.dart';
import '/../models/mounted_container.dart';
import '/../services/vaultexplorer_api.dart';
import '/../utils/raw_entry.dart';
import 'media_viewer_constants.dart';

class PlaylistController extends ChangeNotifier {
  final MountedContainer container;
  final String? startingFolder;

  List<String> _originalList;
  List<String> _currentPlaylist;
  int _currentIndex;

  bool _isShuffled = false;
  bool _allFilesScanned = false;
  bool _isScanningSubfolders = false;
  String _selectedFolder = 'Current Folder Only';

  PlaylistController({
    required this.container,
    required List<String> initialMediaFiles,
    required int initialIndex,
    this.startingFolder,
  }) : _originalList = List.from(initialMediaFiles),
       _currentPlaylist = List.from(initialMediaFiles),
       _currentIndex = initialIndex {
    _initializeFolderFilter();
  }

  List<String> get playlist => _currentPlaylist;
  int get currentIndex => _currentIndex;
  bool get isShuffled => _isShuffled;
  bool get isScanningSubfolders => _isScanningSubfolders;
  String get selectedFolder => _selectedFolder;
  bool get allFilesScanned => _allFilesScanned;
  bool get isEmpty => _currentPlaylist.isEmpty;
  String get currentFile => isEmpty ? '' : _currentPlaylist[_currentIndex];

  void updateIndex(int index) {
    if (index >= 0 && index < _currentPlaylist.length) {
      _currentIndex = index;
      notifyListeners();
    }
  }

  String getBaseDir() {
    if (startingFolder != null) return startingFolder!;
    if (_originalList.isEmpty) return '';
    final first = _originalList.first;
    if (!first.contains('/')) return '';
    return first.substring(0, first.lastIndexOf('/'));
  }

  void _initializeFolderFilter() {
    final baseDir = getBaseDir();
    final hasSubfolderItems = _originalList.any((file) {
      final dir = file.contains('/')
          ? file.substring(0, file.lastIndexOf('/'))
          : '';
      return dir != baseDir;
    });
    if (hasSubfolderItems) {
      _selectedFolder = 'All';
      _allFilesScanned = true;
    }
  }

  void toggleShuffle() {
    if (isEmpty) return;
    final current = currentFile;
    if (!_isShuffled) {
      final shuffled = List<String>.from(_currentPlaylist)
        ..remove(current)
        ..shuffle();
      shuffled.insert(0, current);
      _currentPlaylist = shuffled;
      _currentIndex = 0;
      _isShuffled = true;
    } else {
      _isShuffled = false;
      _applyFolderFiltering(_selectedFolder, current);
    }
    notifyListeners();
  }

  Future<void> filterByFolder(String folder) async {
    _selectedFolder = folder;
    _applyFolderFiltering(folder, currentFile);

    if (folder == 'All' && !_allFilesScanned) {
      _isScanningSubfolders = true;
      notifyListeners();
      try {
        final recursiveFiles = await _scanDirectoryRecursively(getBaseDir());
        if (recursiveFiles.isNotEmpty) {
          _originalList = List.from(recursiveFiles);
        }
        _allFilesScanned = true;
        if (_selectedFolder == 'All') {
          _applyFolderFiltering('All', currentFile);
        }
      } finally {
        _isScanningSubfolders = false;
        notifyListeners();
      }
    } else {
      notifyListeners();
    }
  }

  void _applyFolderFiltering(String folder, String fileAnchor) {
    final baseDir = getBaseDir();
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

    int newIndex = filteredList.indexOf(fileAnchor);
    if (newIndex == -1) newIndex = 0;

    if (filteredList.isNotEmpty) {
      _currentPlaylist = filteredList;
      _currentIndex = newIndex;
    }
  }

  Future<List<String>> _scanDirectoryRecursively(
    String baseDir, {
    int depth = 0,
  }) async {
    if (depth > MediaViewerConstants.maxDirectorySearchDepth) return [];

    final foundFiles = <String>[];
    final subdirNames = <String>[];

    try {
      final items = await vaultExplorerApi.listDirectory(container, baseDir);
      if (items != null) {
        for (final item in items) {
          if (item.startsWith('System:')) continue;
          final entry = RawEntry.parse(item);

          if (entry.isDir) {
            subdirNames.add(entry.name);
          } else {
            if (MediaViewerConstants.isSupported(entry.name)) {
              final fullPath = baseDir.isEmpty
                  ? entry.name
                  : '$baseDir/${entry.name}';
              foundFiles.add(fullPath);
            }
          }
        }

        if (subdirNames.isNotEmpty) {
          final nested = await Future.wait(
            subdirNames.map((name) {
              final subPath = baseDir.isEmpty ? name : '$baseDir/$name';
              return _scanDirectoryRecursively(subPath, depth: depth + 1);
            }),
          );
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

  void removeCurrent() {
    if (isEmpty) return;
    final file = currentFile;
    _currentPlaylist.removeAt(_currentIndex);
    _originalList.remove(file);
    if (_currentIndex >= _currentPlaylist.length &&
        _currentPlaylist.isNotEmpty) {
      _currentIndex = _currentPlaylist.length - 1;
    }
    notifyListeners();
  }
}
