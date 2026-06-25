import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/mounted_container.dart';
import '../../services/cross_container_clipboard.dart';
import '../../services/vaultexplorer_api.dart';
import '../../utils/format_utils.dart';
import '../../utils/temp_file_utils.dart';
import 'browser_dialogs.dart';
import 'media_viewer_screen.dart';
import 'mixins/selection_mixin.dart';
import 'mixins/sort_mixin.dart';
import 'widgets/breadcrumb_bar.dart';
import 'widgets/clipboard_app_bar.dart';
import 'widgets/file_grid_view.dart';
import 'widgets/file_list_view.dart';
import 'widgets/selection_app_bar.dart';

// ── Conflict resolution ────────────────────────────────────────────────────────

enum _ConflictResolution { skip, overwrite, keepBoth }
typedef _ConflictResult = ({_ConflictResolution resolution, bool applyToAll});

// ── Disk-full sentinel ────────────────────────────────────────────────────────

class _DiskFullException implements Exception {
  const _DiskFullException();
}

// ── Layout mode ───────────────────────────────────────────────────────────────

enum BrowserLayoutMode { list, grid }

// ── Path segment model ────────────────────────────────────────────────────────

class PathSegment {
  final String label;
  final String fatPath;
  const PathSegment(this.label, this.fatPath);
}

// ── Screen ────────────────────────────────────────────────────────────────────

class FileBrowserScreen extends StatefulWidget {
  final MountedContainer container;
  const FileBrowserScreen({super.key, required this.container});

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen>
    with SelectionMixin<FileBrowserScreen>, SortMixin<FileBrowserScreen> {

  // ── Core state ────────────────────────────────────────────────────────────
  final List<PathSegment> _pathStack = [const PathSegment('Root', '')];
  List<String> _currentItems = [];
  bool _isLoading = false;
  int _freeSpace = 0;

  // ── Inline status (replaces SnackBars for operation feedback) ─────────────
  String? _statusMessage;
  bool _statusIsError = false;

  // ── Unified clipboard ─────────────────────────────────────────────────────
  CrossContainerClipboard get _clip => CrossContainerClipboard.instance;

  // ── Search state ──────────────────────────────────────────────────────────
  bool _isSearchActive = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  // ── Layout state ──────────────────────────────────────────────────────────
  BrowserLayoutMode _layoutMode = BrowserLayoutMode.list;

  // ── Convenience getters ───────────────────────────────────────────────────
  bool get _atRoot => _pathStack.length == 1;
  String get _currentDirPath => _pathStack.last.fatPath;

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _freeSpace = widget.container.freeSpace;
    _loadDirectoryContents('');
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ── Inline status ─────────────────────────────────────────────────────────

  void _setStatus(String msg, {bool error = false, Duration? autoClear}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = msg;
      _statusIsError = error;
    });
    final delay = autoClear ?? (error
        ? const Duration(seconds: 5)
        : const Duration(seconds: 3));
    Future.delayed(delay, () {
      if (mounted && _statusMessage == msg) {
        setState(() => _statusMessage = null);
      }
    });
  }

  void _clearStatus() {
    if (mounted) setState(() => _statusMessage = null);
  }

  // ── Directory loading ─────────────────────────────────────────────────────

  Future<void> _loadDirectoryContents(String path) async {
    setState(() => _isLoading = true);
    try {
      final items =
          await vaultExplorerApi.listDirectory(widget.container, path);
      final space = await vaultExplorerApi.getSpaceInfo(widget.container);
      if (mounted) {
        setState(() {
          _currentItems = items ?? [];
          if (space != null && space.length > 1) _freeSpace = space[1];
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _setStatus('Failed loading folder: ${e.runtimeType}', error: true);
      }
    }
  }

  // ── Search helpers ────────────────────────────────────────────────────────

  void _clearSearch() {
    _isSearchActive = false;
    _searchQuery = '';
    _searchController.clear();
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _enterDirectory(String rawDirEntry) {
    final name = rawDirEntry.replaceFirst('[DIR] ', '');
    final newPath =
        _currentDirPath.isEmpty ? name : '$_currentDirPath/$name';
    setState(() {
      _pathStack.add(PathSegment(name, newPath));
      _clearSearch();
    });
    _loadDirectoryContents(newPath);
  }

  void _navigateUp() {
    if (_atRoot) return;
    setState(() {
      _pathStack.removeLast();
      _clearSearch();
    });
    _loadDirectoryContents(_currentDirPath);
  }

  void _jumpTo(int index) {
    if (index == _pathStack.length - 1) return;
    setState(() {
      _pathStack.removeRange(index + 1, _pathStack.length);
      _clearSearch();
    });
    _loadDirectoryContents(_currentDirPath);
  }

  // ── Item tap / long-press ─────────────────────────────────────────────────

  void _handleDirTap(String rawItem) {
    if (isSelectionMode) {
      toggleSelectItem(rawItem);
    } else {
      _enterDirectory(rawItem);
    }
  }

 // ── FileBrowserScreen Navigation Excerpt ───────────────────────────────────

  void _handleFileTap(String rawItem) {
    if (isSelectionMode) {
      toggleSelectItem(rawItem);
      return;
    }
    final cleanName = rawItem.split('|').first;
    final fullPath =
        _currentDirPath.isEmpty ? cleanName : '$_currentDirPath/$cleanName';

    if (_isSupportedMedia(cleanName)) {
      final mediaEntries = _currentItems
          .where((f) => !f.startsWith('[DIR]') && !f.startsWith('System:'))
          .map((f) => f.split('|').first)
          .where(_isSupportedMedia)
          .toList();
      final resolvedPaths = mediaEntries
          .map((f) => _currentDirPath.isEmpty ? f : '$_currentDirPath/$f')
          .toList();
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MediaViewerScreen(
            container: widget.container,
            mediaFiles: resolvedPaths,
            initialIndex: mediaEntries.indexOf(cleanName),
            startingFolder: _currentDirPath, // <-- Passed starting folder
          ),
        ),
      );
    } else {
      _openFileWithApp(cleanName, fullPath);
    }
  }

  Future<void> _startMediaViewerFromCurrentLocation() async {
    final localMedia = _currentItems
        .where((f) => !f.startsWith('[DIR]') && !f.startsWith('System:'))
        .map((f) => f.split('|').first)
        .where(_isSupportedMedia)
        .toList();

    if (localMedia.isNotEmpty) {
      final resolvedPaths = localMedia
          .map((f) => _currentDirPath.isEmpty ? f : '$_currentDirPath/$f')
          .toList();

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MediaViewerScreen(
            container: widget.container,
            mediaFiles: resolvedPaths,
            initialIndex: 0,
            startingFolder: _currentDirPath, // <-- Passed starting folder
          ),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    _setStatus('Scanning subfolders for media…', autoClear: const Duration(seconds: 15));

    try {
      final recursiveMedia = await _scanMediaRecursively(_currentDirPath);
      if (!mounted) return;

      if (recursiveMedia.isNotEmpty) {
        _clearStatus();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MediaViewerScreen(
              container: widget.container,
              mediaFiles: recursiveMedia,
              initialIndex: 0,
              startingFolder: _currentDirPath, // <-- Passed starting folder
            ),
          ),
        );
      } else {
        _setStatus('No media files found in this folder or its subfolders', error: true);
      }
    } catch (e) {
      _setStatus('Failed to scan subfolders: $e', error: true);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _handleItemLongPress(String rawItem) {
    HapticFeedback.selectionClick();
    if (!isSelectionMode) {
      setState(() {
        isSelectionMode = true;
        selectedItems.add(rawItem);
      });
    } else {
      toggleSelectItem(rawItem);
    }
  }

  // ── Media helpers ─────────────────────────────────────────────────────────

  bool _isSupportedMedia(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return const {
      'jpg', 'jpeg', 'png', 'gif', 'webp',
      'mp4', 'm4v', 'webm', 'mov', 'avi', 'mkv',
      'mp3', 'm4a', 'wav', 'flac', 'ogg', 'aac'
    }.contains(ext);
  }

  Future<List<String>> _scanMediaRecursively(String dirPath) async {
    final foundFiles = <String>[];
    try {
      final items = await vaultExplorerApi.listDirectory(widget.container, dirPath);
      if (items != null) {
        for (final item in items) {
          if (item.startsWith('System:')) continue;
          if (item.startsWith('[DIR] ')) {
            final subDirName = item.replaceFirst('[DIR] ', '');
            final subDirPath = dirPath.isEmpty ? subDirName : '$dirPath/$subDirName';
            final nested = await _scanMediaRecursively(subDirPath);
            foundFiles.addAll(nested);
          } else {
            final fileName = item.split('|').first;
            if (_isSupportedMedia(fileName)) {
              final fullPath = dirPath.isEmpty ? fileName : '$dirPath/$fileName';
              foundFiles.add(fullPath);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error scanning subfolder for media: $e');
    }
    return foundFiles;
  }



  Future<void> _openFileWithApp(String cleanName, String fullPath) async {
    try {
      final ok =
          await vaultExplorerApi.openWithApp(widget.container, fullPath);
      if (!ok && mounted) {
        _setStatus('No app found for this file type', error: true);
      }
    } catch (_) {
      if (mounted) {
        _setStatus('Could not open "$cleanName"', error: true);
      }
    }
  }

  // ── Clipboard init ────────────────────────────────────────────────────────

  void _initClipboard({required bool cut}) {
    final sources = selectedItems.map((item) {
      final isDir = item.startsWith('[DIR] ');
      final name =
          isDir ? item.replaceFirst('[DIR] ', '') : item.split('|').first;
      final path =
          _currentDirPath.isEmpty ? name : '$_currentDirPath/$name';
      int? size;
      if (!isDir) {
        final parts = item.split('|');
        if (parts.length > 1) size = int.tryParse(parts[1]);
      }
      return <String, dynamic>{'path': path, 'isDir': isDir, 'size': size};
    }).toList();

    _clip.set(
      container: widget.container,
      cut: cut,
      clipItems: sources,
    );

    exitSelectionMode();
  }

  // ── Space pre-flight ──────────────────────────────────────────────────────

  Future<int> _measureTreeBytes(
      MountedContainer container, String path) async {
    int total = 0;
    final entries =
        await vaultExplorerApi.listDirectory(container, path) ?? [];
    for (final entry in entries) {
      if (entry.startsWith('System:')) continue;
      if (entry.startsWith('[DIR] ')) {
        final childName = entry.replaceFirst('[DIR] ', '');
        total += await _measureTreeBytes(container, '$path/$childName');
      } else {
        final parts = entry.split('|');
        total += parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
      }
    }
    return total;
  }

  Future<int> _measureItemBytes(
      MountedContainer container, Map<String, dynamic> item) async {
    if (!(item['isDir'] as bool)) {
      final cached = item['size'] as int?;
      if (cached != null) return cached;
      return vaultExplorerApi.getFileSize(container, item['path'] as String);
    }
    return _measureTreeBytes(container, item['path'] as String);
  }

  // ── Paste ─────────────────────────────────────────────────────────────────

  Future<void> _paste() async {
    if (!_clip.hasItems) return;

    final srcContainer = _clip.sourceContainer!;
    final items = List<Map<String, dynamic>>.from(_clip.items);
    final isCut = _clip.isCutOperation;
    final sameContainer = _clip.isFromContainer(widget.container);

    final toProcess = <Map<String, dynamic>>[];
    int skipCount = 0;
    for (final item in items) {
      final srcPath = item['path'] as String;
      final isDir = item['isDir'] as bool;
      final fileName = srcPath.split('/').last;
      final destPath =
          _currentDirPath.isEmpty ? fileName : '$_currentDirPath/$fileName';
      if (sameContainer) {
        if (srcPath == destPath) { skipCount++; continue; }
        if (isDir && destPath.startsWith('$srcPath/')) { skipCount++; continue; }
      }
      toProcess.add({...item, '_destPath': destPath});
    }

    if (toProcess.isEmpty) {
      _setStatus('Nothing to paste — already at destination');
      _clip.clear();
      return;
    }

    setState(() => _isLoading = true);
    _setStatus('Checking available space…', autoClear: const Duration(minutes: 5));

    if (!(sameContainer && isCut)) {
      int requiredBytes = 0;
      for (final item in toProcess) {
        requiredBytes += await _measureItemBytes(srcContainer, item);
      }
      final spaceInfo = await vaultExplorerApi.getSpaceInfo(widget.container);
      final freeBytes =
          (spaceInfo != null && spaceInfo.length > 1) ? spaceInfo[1] : 0;
      if (requiredBytes > (freeBytes * 0.95).floor()) {
        setState(() => _isLoading = false);
        _setStatus(
          'Not enough space — need ${formatBytes(requiredBytes)}, '
          'only ${formatBytes(freeBytes)} free',
          error: true,
          autoClear: const Duration(seconds: 6),
        );
        return;
      }
    }

    final existingRaw = await vaultExplorerApi.listDirectory(
            widget.container, _currentDirPath) ??
        [];
    final existingNames = <String>{};
    final existingDirs = <String>{};
    for (final item in existingRaw) {
      if (item.startsWith('[DIR] ')) {
        final n = item.replaceFirst('[DIR] ', '').toLowerCase();
        existingNames.add(n);
        existingDirs.add(n);
      } else {
        existingNames.add(item.split('|').first.toLowerCase());
      }
    }

    _ConflictResolution? globalResolution;
    final tmpDir = await getTemporaryDirectory();
    int failCount = 0;
    final List<String> createdDestPaths = [];
    bool diskFull = false;

    _setStatus(
      isCut ? 'Moving…' : 'Copying…',
      autoClear: const Duration(minutes: 10),
    );

    try {
      for (final item in toProcess) {
        if (!mounted) break;

        final srcPath = item['path'] as String;
        final isDir = item['isDir'] as bool;
        final fileName = srcPath.split('/').last;
        String destPath = item['_destPath'] as String;

        // ── Conflict resolution ─────────────────────────────────────────
        if (existingNames.contains(fileName.toLowerCase())) {
          _ConflictResolution? resolution = globalResolution;
          if (resolution == null) {
            final result = await _showConflictResolutionDialog(
              fileName,
              hasMore: toProcess.length > 1,
            );
            if (!mounted) break;
            if (result == null) break;
            if (result.applyToAll) globalResolution = result.resolution;
            resolution = result.resolution;
          }
          switch (resolution) {
            case _ConflictResolution.skip:
              skipCount++;
              continue;
            case _ConflictResolution.overwrite:
              if (sameContainer && isCut) {
                final destIsDir =
                    existingDirs.contains(fileName.toLowerCase());
                await _deleteEntryRecursive(
                    widget.container, destPath, destIsDir);
              }
            case _ConflictResolution.keepBoth:
              final uniqueName = _makeUniqueName(fileName, existingNames);
              existingNames.add(uniqueName.toLowerCase());
              destPath = _currentDirPath.isEmpty
                  ? uniqueName
                  : '$_currentDirPath/$uniqueName';
          }
        }

        // ── Execute ─────────────────────────────────────────────────────
        try {
          if (sameContainer && isCut) {
            final ok = await vaultExplorerApi.renameFile(
                widget.container, srcPath, destPath);
            if (!ok) failCount++;
          } else if (sameContainer && !isCut) {
            final ok = await _copyEntryWithinContainer(
                srcPath, destPath, isDir, tmpDir, createdDestPaths);
            if (!ok) failCount++;
          } else {
            final ok = await _copyEntryAcrossContainers(
              srcContainer: srcContainer,
              destContainer: widget.container,
              srcPath: srcPath,
              destPath: destPath,
              isDir: isDir,
              tmpDir: tmpDir,
              createdDestPaths: createdDestPaths,
            );
            if (!ok) failCount++;
            if (ok && isCut) {
              await _deleteEntryRecursive(srcContainer, srcPath, isDir);
            }
          }
        } on _DiskFullException {
          diskFull = true;
          break;
        }
      }
    } finally {
      if (diskFull) {
        for (final path in createdDestPaths.reversed) {
          try {
            await _deleteEntryRecursive(widget.container, path, false);
          } catch (_) {}
        }
      }
      _clip.clear();
      await _loadDirectoryContents(_currentDirPath);
      if (mounted) {
        if (diskFull) {
          _setStatus(
            'Disk full — operation stopped and partial files removed',
            error: true,
            autoClear: const Duration(seconds: 6),
          );
        } else {
          final successCount = toProcess.length - failCount - skipCount;
          final parts = [
            if (successCount > 0)
              '${isCut ? 'Moved' : 'Copied'} $successCount item(s)',
            if (skipCount > 0) '$skipCount skipped',
            if (failCount > 0) '$failCount failed',
          ];
          _setStatus(
            parts.join(' · '),
            error: failCount > 0,
          );
        }
      }
    }
  }

  // ── Conflict helpers ──────────────────────────────────────────────────────

  static String _makeUniqueName(String fileName, Set<String> existingNames) {
    if (!existingNames.contains(fileName.toLowerCase())) return fileName;
    final dotIdx = fileName.lastIndexOf('.');
    final name = dotIdx != -1 ? fileName.substring(0, dotIdx) : fileName;
    final ext = dotIdx != -1 ? fileName.substring(dotIdx) : '';
    for (int i = 1; i < 9999; i++) {
      final candidate = '$name ($i)$ext';
      if (!existingNames.contains(candidate.toLowerCase())) return candidate;
    }
    return '$fileName-${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<_ConflictResult?> _showConflictResolutionDialog(
    String fileName, {
    required bool hasMore,
  }) {
    bool applyToAll = false;
    final cs = Theme.of(context).colorScheme;

    return showDialog<_ConflictResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Already Exists', style: TextStyle(fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: TextSpan(
                  style: Theme.of(ctx).textTheme.bodyMedium,
                  children: [
                    TextSpan(
                      text: '"$fileName"',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, color: cs.primary),
                    ),
                    const TextSpan(
                        text: ' already exists in this location.'),
                  ],
                ),
              ),
              if (hasMore) ...[
                const SizedBox(height: 14),
                GestureDetector(
                  onTap: () => setLocal(() => applyToAll = !applyToAll),
                  child: Row(
                    children: [
                      Checkbox(
                        value: applyToAll,
                        onChanged: (v) =>
                            setLocal(() => applyToAll = v ?? false),
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text('Apply to all conflicts',
                            style: TextStyle(fontSize: 13)),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx,
                  (resolution: _ConflictResolution.skip, applyToAll: applyToAll)),
              child: const Text('Skip'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx,
                  (resolution: _ConflictResolution.overwrite, applyToAll: applyToAll)),
              child: Text('Overwrite', style: TextStyle(color: cs.error)),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx,
                  (resolution: _ConflictResolution.keepBoth, applyToAll: applyToAll)),
              style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
              child: const Text('Keep Both'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Recursive delete ──────────────────────────────────────────────────────

  Future<bool> _deleteEntryRecursive(
      MountedContainer container, String path, bool isDir) async {
    if (!isDir) return vaultExplorerApi.deleteFile(container, path);
    final children =
        await vaultExplorerApi.listDirectory(container, path) ?? [];
    for (final entry in children) {
      if (entry.startsWith('System:')) continue;
      final childIsDir = entry.startsWith('[DIR] ');
      final childName = childIsDir
          ? entry.replaceFirst('[DIR] ', '')
          : entry.split('|').first;
      await _deleteEntryRecursive(container, '$path/$childName', childIsDir);
    }
    return vaultExplorerApi.deleteFile(container, path);
  }

  // ── Same-container copy ───────────────────────────────────────────────────

  Future<bool> _copyEntryWithinContainer(
    String srcPath,
    String destPath,
    bool isDir,
    Directory tmpDir,
    List<String> createdDestPaths,
  ) async {
    if (!isDir) {
      final tempFile =
          File(TempFileUtils.uniquePath(tmpDir, prefix: 'cb_copy'));
      try {
        final decOk = await vaultExplorerApi.decryptFile(
            widget.container, srcPath, tempFile.path);
        if (!decOk) return false;
        final ok = await vaultExplorerApi.writeBackFile(
            widget.container, destPath, tempFile.path);
        if (!ok) throw const _DiskFullException();
        createdDestPaths.add(destPath);
        return true;
      } finally {
        if (await tempFile.exists()) await tempFile.delete();
      }
    }
    final children =
        await vaultExplorerApi.listDirectory(widget.container, srcPath) ?? [];
    await vaultExplorerApi.createDirectory(widget.container, destPath);
    createdDestPaths.add(destPath);
    bool allOk = true;
    for (final entry in children) {
      if (entry.startsWith('System:')) continue;
      final childIsDir = entry.startsWith('[DIR] ');
      final childName = childIsDir
          ? entry.replaceFirst('[DIR] ', '')
          : entry.split('|').first;
      final ok = await _copyEntryWithinContainer(
        '$srcPath/$childName',
        '$destPath/$childName',
        childIsDir,
        tmpDir,
        createdDestPaths,
      );
      if (!ok) allOk = false;
    }
    return allOk;
  }

  // ── Cross-container copy ──────────────────────────────────────────────────

  Future<bool> _copyEntryAcrossContainers({
    required MountedContainer srcContainer,
    required MountedContainer destContainer,
    required String srcPath,
    required String destPath,
    required bool isDir,
    required Directory tmpDir,
    required List<String> createdDestPaths,
  }) async {
    if (!isDir) {
      final tempFile =
          File(TempFileUtils.uniquePath(tmpDir, prefix: 'xclip'));
      try {
        final decOk = await vaultExplorerApi.decryptFile(
            srcContainer, srcPath, tempFile.path);
        if (!decOk) return false;
        final ok = await vaultExplorerApi.writeBackFile(
            destContainer, destPath, tempFile.path);
        if (!ok) throw const _DiskFullException();
        createdDestPaths.add(destPath);
        return true;
      } finally {
        if (await tempFile.exists()) await tempFile.delete();
      }
    }
    final children =
        await vaultExplorerApi.listDirectory(srcContainer, srcPath) ?? [];
    await vaultExplorerApi.createDirectory(destContainer, destPath);
    createdDestPaths.add(destPath);
    bool allOk = true;
    for (final entry in children) {
      if (entry.startsWith('System:')) continue;
      final childIsDir = entry.startsWith('[DIR] ');
      final childName = childIsDir
          ? entry.replaceFirst('[DIR] ', '')
          : entry.split('|').first;
      final ok = await _copyEntryAcrossContainers(
        srcContainer: srcContainer,
        destContainer: destContainer,
        srcPath: '$srcPath/$childName',
        destPath: '$destPath/$childName',
        isDir: childIsDir,
        tmpDir: tmpDir,
        createdDestPaths: createdDestPaths,
      );
      if (!ok) allOk = false;
    }
    return allOk;
  }

  // ── Batch delete ──────────────────────────────────────────────────────────

  void _batchDelete() {
    HapticFeedback.heavyImpact();
    BrowserDialogs.showBatchDelete(
      context,
      toDelete: List<String>.from(selectedItems),
      onConfirmed: (items) async {
        setState(() => _isLoading = true);
        int failCount = 0;
        try {
          for (final item in items) {
            final isDir = item.startsWith('[DIR] ');
            final name = isDir
                ? item.replaceFirst('[DIR] ', '')
                : item.split('|').first;
            final full =
                _currentDirPath.isEmpty ? name : '$_currentDirPath/$name';
            if (!await _deleteEntryRecursive(widget.container, full, isDir)) {
              failCount++;
            }
          }
        } finally {
          exitSelectionMode();
          await _loadDirectoryContents(_currentDirPath);
          final successCount = items.length - failCount;
          _setStatus(
            failCount == 0
                ? 'Deleted $successCount item(s)'
                : '$successCount deleted · $failCount failed',
            error: failCount > 0,
          );
        }
      },
    );
  }

  // ── Import / Export ───────────────────────────────────────────────────────

  Future<void> _exportSelectedToStorage() async {
    final items = selectedItems.map((item) {
      final isDir = item.startsWith('[DIR] ');
      final name =
          isDir ? item.replaceFirst('[DIR] ', '') : item.split('|').first;
      final path =
          _currentDirPath.isEmpty ? name : '$_currentDirPath/$name';
      return <String, dynamic>{'path': path, 'isDir': isDir};
    }).toList();
    if (items.isEmpty) return;

    setState(() => _isLoading = true);
    try {
      final count =
          await vaultExplorerApi.exportSelectedToFolder(widget.container, items);
      _setStatus(count > 0
          ? 'Exported $count file(s)'
          : 'Export cancelled or failed',
          error: count == 0);
    } catch (e) {
      _setStatus('Export error: ${e.runtimeType}', error: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
    exitSelectionMode();
  }

  Future<void> _importFilesFromDevice() async {
    setState(() => _isLoading = true);
    try {
      final count =
          await vaultExplorerApi.importFiles(widget.container, _currentDirPath);
      if (count > 0) await _loadDirectoryContents(_currentDirPath);
      _setStatus(count > 0
          ? 'Imported $count file${count != 1 ? 's' : ''}'
          : 'No files imported',
          error: count == 0);
    } catch (e) {
      _setStatus('Import failed: ${e.runtimeType}', error: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _importFolderFromDevice() async {
    setState(() => _isLoading = true);
    try {
      final count =
          await vaultExplorerApi.importFolder(widget.container, _currentDirPath);
      if (count > 0) await _loadDirectoryContents(_currentDirPath);
      _setStatus(count > 0
          ? 'Imported $count item${count != 1 ? 's' : ''}'
          : 'No files imported',
          error: count == 0);
    } catch (e) {
      _setStatus('Folder import failed: ${e.runtimeType}', error: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final dirs = _currentItems.where((f) => f.startsWith('[DIR]')).toList()
      ..sort(compareItems);
    final files = _currentItems
        .where((f) => !f.startsWith('[DIR]') && !f.startsWith('System:'))
        .toList()
      ..sort(compareItems);

    final query = _searchQuery.trim().toLowerCase();
    final filteredDirs = query.isEmpty
        ? dirs
        : dirs
            .where((d) =>
                d.replaceFirst('[DIR] ', '').toLowerCase().contains(query))
            .toList();
    final filteredFiles = query.isEmpty
        ? files
        : files
            .where((f) => f.split('|').first.toLowerCase().contains(query))
            .toList();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        if (isSelectionMode) {
          exitSelectionMode();
        } else if (_clip.hasItems && _clip.isFromContainer(widget.container)) {
          _clip.clear();
          setState(() {});
        } else if (_isSearchActive) {
          setState(() => _clearSearch());
        } else if (!_atRoot) {
          _navigateUp();
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: _buildAppBar(context, filteredDirs, filteredFiles),
        body: Column(
          children: [
            BreadcrumbBar(stack: _pathStack, onTap: _jumpTo),
            _StatsBar(
              dirCount: filteredDirs.length,
              fileCount: filteredFiles.length,
              freeSpaceBytes: _freeSpace,
              isFiltered: query.isNotEmpty,
            ),
            
            const Divider(),
            Expanded(child: _buildBody(filteredDirs, filteredFiles)),
            if (_statusMessage != null)
              _StatusBar(
                message: _statusMessage!,
                isError: _statusIsError,
                onDismiss: _clearStatus,
              ),
          ],
        ),
      ),
    );
  }

  // ── App bar ───────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar(
      BuildContext context, List<String> dirs, List<String> files) {
    final cs = Theme.of(context).colorScheme;
    final allSelectable = [...dirs, ...files];

    if (isSelectionMode) {
      final single = selectedItems.length == 1;
      final singleFile = single && !selectedItems.first.startsWith('[DIR] ');
      return SelectionAppBar(
        selectedCount: selectedItems.length,
        singleSelected: single,
        singleFileSelected: singleFile,
        onClose: exitSelectionMode,
        onSelectAll: () => setState(() => selectedItems.addAll(allSelectable)),
        onRename: () {
          final raw = selectedItems.first;
          final isDir = raw.startsWith('[DIR] ');
          final name = isDir
              ? raw.replaceFirst('[DIR] ', '')
              : raw.split('|').first;
          BrowserDialogs.showRename(
            context,
            container: widget.container,
            oldName: name,
            currentDirPath: _currentDirPath,
            onSuccess: () => _loadDirectoryContents(_currentDirPath),
          );
          exitSelectionMode();
        },
        onCopy: () => _initClipboard(cut: false),
        onCut: () => _initClipboard(cut: true),
        onExport: _exportSelectedToStorage,
        onDelete: _batchDelete,
        onOpenWithApp: () {
          final raw = selectedItems.first;
          final name = raw.split('|').first;
          final path =
              _currentDirPath.isEmpty ? name : '$_currentDirPath/$name';
          vaultExplorerApi.openWithApp(widget.container, path);
          exitSelectionMode();
        },
      );
    }

    if (_clip.hasItems) {
      final fromHere = _clip.isFromContainer(widget.container);
      return ClipboardAppBar(
        isCutOperation: _clip.isCutOperation,
        itemCount: _clip.items.length,
        sourceLabel: fromHere ? null : _clip.sourceContainer?.displayName,
        onCancel: () => setState(() => _clip.clear()),
        onPaste: _paste,
        onBack: _atRoot
            ? () => Navigator.of(context).pop()
            : _navigateUp,
      );
    }

    if (_isSearchActive) {
      return AppBar(
        backgroundColor: cs.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Close search',
          onPressed: () => setState(() => _clearSearch()),
        ),
        title: TextField(
          controller: _searchController,
          autofocus: true,
          onChanged: (val) => setState(() => _searchQuery = val),
          style: TextStyle(fontSize: 14, color: cs.onSurface),
          decoration: InputDecoration(
            hintText: 'Search in this folder…',
            hintStyle: TextStyle(color: cs.outline, fontSize: 14),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        actions: [
          if (_searchQuery.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: 'Clear',
              onPressed: () => setState(() {
                _searchQuery = '';
                _searchController.clear();
              }),
            ),
        ],
      );
    }

    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        tooltip: _atRoot ? 'Back to dashboard' : 'Go up',
        onPressed:
            _atRoot ? () => Navigator.of(context).pop() : _navigateUp,
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.container.displayName,
              style: const TextStyle(fontSize: 14)),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Search in this folder',
          onPressed: () => setState(() => _isSearchActive = true),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.add),
          tooltip: 'New item',
          onSelected: (v) {
            switch (v) {
              case 'folder':
                BrowserDialogs.showCreateFolder(
                  context,
                  container: widget.container,
                  currentDirPath: _currentDirPath,
                  onSuccess: () => _loadDirectoryContents(_currentDirPath),
                );
              case 'file':
                BrowserDialogs.showCreateFile(
                  context,
                  container: widget.container,
                  currentDirPath: _currentDirPath,
                  onSuccess: () => _loadDirectoryContents(_currentDirPath),
                );
              case 'import':
                _importFilesFromDevice();
              case 'import_folder':
                _importFolderFromDevice();
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'folder',
              child: Row(children: [
                Icon(Icons.create_new_folder_outlined,
                    color: cs.onSurfaceVariant),
                const SizedBox(width: 12),
                const Text('New Folder'),
              ]),
            ),
            PopupMenuItem(
              value: 'file',
              child: Row(children: [
                Icon(Icons.insert_drive_file_outlined,
                    color: cs.onSurfaceVariant),
                const SizedBox(width: 12),
                const Text('New File'),
              ]),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'import',
              child: Row(children: [
                Icon(Icons.upload_file_outlined, color: cs.onSurfaceVariant),
                const SizedBox(width: 12),
                const Text('Import Files'),
              ]),
            ),
            PopupMenuItem(
              value: 'import_folder',
              child: Row(children: [
                Icon(Icons.drive_folder_upload_outlined,
                    color: cs.onSurfaceVariant),
                const SizedBox(width: 12),
                const Text('Import Folder'),
              ]),
            ),
          ],
        ),
        // Consolidated Options Overflow Menu
        PopupMenuButton<dynamic>(
          icon: const Icon(Icons.more_vert),
          tooltip: 'Folder options',
          onSelected: (value) {
            if (value is SortBy) {
              setSort(value);
            } else if (value is String) {
              switch (value) {
                case 'media_viewer':
                  _startMediaViewerFromCurrentLocation();
                  break;
                case 'toggle_layout':
                  setState(() {
                    _layoutMode = _layoutMode == BrowserLayoutMode.list
                        ? BrowserLayoutMode.grid
                        : BrowserLayoutMode.list;
                  });
                  break;
              }
            }
          },
          itemBuilder: (ctx) {
            final localCs = Theme.of(ctx).colorScheme;
            
            final hasLocalMedia = _currentItems
                .where((f) => !f.startsWith('[DIR]') && !f.startsWith('System:'))
                .map((f) => f.split('|').first)
                .where(_isSupportedMedia)
                .isNotEmpty;
                
            final hasSubfolders = _currentItems.any((f) => f.startsWith('[DIR] '));
            final canPlay = hasLocalMedia || hasSubfolders;

            return [
              PopupMenuItem<dynamic>(
                value: 'media_viewer',
                enabled: canPlay,
                child: Row(children: [
                  Icon(
                    Icons.play_circle_outline_rounded,
                    color: canPlay ? localCs.primary : localCs.error,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Play Media Here',
                    style: TextStyle(
                      color: canPlay ? null : localCs.error,
                    ),
                  ),
                ]),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<dynamic>(
                value: 'toggle_layout',
                child: Row(children: [
                  Icon(
                    _layoutMode == BrowserLayoutMode.list
                        ? Icons.grid_view_rounded
                        : Icons.view_list_rounded,
                    color: localCs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Text(_layoutMode == BrowserLayoutMode.list
                      ? 'Switch to Gallery'
                      : 'Switch to List'),
                ]),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<dynamic>(
                enabled: false,
                height: 28,
                child: Text(
                  'Sort By',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: localCs.outline,
                  ),
                ),
              ),
              buildSortMenuItem(SortBy.name, 'Name'),
              buildSortMenuItem(SortBy.size, 'Size'),
              buildSortMenuItem(SortBy.extension, 'Type'),
            ];
          },
        ),
      ],
    );
  }

  // ── Body ──────────────────────────────────────────────────────────────────

  Widget _buildBody(List<String> dirs, List<String> files) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_currentItems.isEmpty) {
      return _EmptyPlaceholder(onBack: _navigateUp, atRoot: _atRoot);
    }
    if (_searchQuery.trim().isNotEmpty && dirs.isEmpty && files.isEmpty) {
      return _SearchEmptyState(query: _searchQuery.trim());
    }
    if (_layoutMode == BrowserLayoutMode.grid) {
      return FileGridView(
        container: widget.container,
        dirs: dirs,
        files: files,
        isSelectionMode: isSelectionMode,
        selectedItems: selectedItems,
        currentDirPath: _currentDirPath,
        onDirTap: _handleDirTap,
        onFileTap: _handleFileTap,
        onItemLongPress: _handleItemLongPress,
      );
    }
    return FileListView(
      dirs: dirs,
      files: files,
      isSelectionMode: isSelectionMode,
      selectedItems: selectedItems,
      onDirTap: _handleDirTap,
      onFileTap: _handleFileTap,
      onItemLongPress: _handleItemLongPress,
    );
  }
}

// ── Inline status bar ─────────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  final String message;
  final bool isError;
  final VoidCallback onDismiss;

  const _StatusBar({
    required this.message,
    required this.isError,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = isError
        ? cs.error.withOpacity(0.12)
        : cs.primaryContainer.withOpacity(0.6);
    final fg = isError ? cs.error : cs.primary;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Container(
        key: ValueKey(message),
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.info_outline,
              size: 14,
              color: fg,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 12,
                  color: fg,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            GestureDetector(
              onTap: onDismiss,
              child: Icon(Icons.close, size: 14, color: fg),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Stats bar ─────────────────────────────────────────────────────────────────

class _StatsBar extends StatelessWidget {
  final int dirCount;
  final int fileCount;
  final int freeSpaceBytes;
  final bool isFiltered;

  const _StatsBar({
    required this.dirCount,
    required this.fileCount,
    required this.freeSpaceBytes,
    this.isFiltered = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: cs.surface,
      child: Row(
        children: [
          _Chip(
            icon: Icons.folder_outlined,
            label: '$dirCount folder${dirCount != 1 ? 's' : ''}',
          ),
          const SizedBox(width: 14),
          _Chip(
            icon: Icons.insert_drive_file_outlined,
            label: '$fileCount file${fileCount != 1 ? 's' : ''}',
          ),
          if (isFiltered) ...[
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'filtered',
                style: TextStyle(
                    fontSize: 9,
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4),
              ),
            ),
          ],
          const Spacer(),
          _Chip(
            icon: Icons.storage_outlined,
            label: '${formatBytes(freeSpaceBytes)} free',
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Chip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: cs.outline),
      const SizedBox(width: 4),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

// ── Empty states ──────────────────────────────────────────────────────────────

class _EmptyPlaceholder extends StatelessWidget {
  final VoidCallback onBack;
  final bool atRoot;
  const _EmptyPlaceholder({required this.onBack, required this.atRoot});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.folder_open_outlined, size: 48, color: cs.outline),
          const SizedBox(height: 16),
          Text('Empty Folder',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('Tap + to create files or import from device.',
              style: TextStyle(color: cs.outline, fontSize: 12),
              textAlign: TextAlign.center),
          if (!atRoot) ...[
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_upward, size: 16),
              label: const Text('Go back'),
            ),
          ],
        ]),
      ),
    );
  }
}

class _SearchEmptyState extends StatelessWidget {
  final String query;
  const _SearchEmptyState({required this.query});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.search_off_outlined, size: 48, color: cs.outline),
          const SizedBox(height: 16),
          Text('No results', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Nothing in this folder matches "$query".',
            style: TextStyle(color: cs.outline, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ]),
      ),
    );
  }
}