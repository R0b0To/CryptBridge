import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/clipboard_item.dart';
import '../../models/file_operation.dart'; // also exports FileOperationService, ConflictPlan, enums
import '../../models/mounted_container.dart';
import '../../models/thumbnail_cache_mode.dart';
import '../../services/app_settings_service.dart';
import '../../services/cross_container_clipboard.dart';
import '../../services/vaultexplorer_api.dart';
import '../../utils/format_utils.dart';
import '../../utils/raw_entry.dart';
import 'browser_dialogs.dart';
import 'viewer/media_viewer_constants.dart';
import 'viewer/media_viewer_screen.dart';
import 'viewer/text_editor_screen.dart';
import 'mixins/selection_mixin.dart';
import 'mixins/sort_mixin.dart';
import 'widgets/breadcrumb_bar.dart';
import 'widgets/clipboard_banner.dart';
import 'widgets/conflict_resolution_sheet.dart';
import 'widgets/file_grid_view.dart';
import 'widgets/file_list_view.dart';
import 'widgets/operation_progress_bar.dart';
import 'widgets/selection_app_bar.dart';

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
  final MountedContainer? Function(int volId)? resolveContainer;
  final ThumbnailCacheMode? thumbnailCacheMode;
  final VoidCallback? onUserActivity;

  const FileBrowserScreen({
    super.key,
    required this.container,
    this.thumbnailCacheMode,
    this.onUserActivity,
    this.resolveContainer,
  });

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen>
    with SelectionMixin<FileBrowserScreen>, SortMixin<FileBrowserScreen> {
  final List<PathSegment> _pathStack = [const PathSegment('Root', '')];
  List<String> _currentItems = [];
  bool _isLoading = false;
  int _freeSpace = 0;
  bool _isListingTruncated = false;
  String? _statusMessage;
  bool _statusIsError = false;

  CrossContainerClipboard get _clip => CrossContainerClipboard.instance;
  FileOperationService get _opSvc => FileOperationService.instance;

  bool _isSearchActive = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  BrowserLayoutMode _layoutMode = BrowserLayoutMode.list;
  String? _currentFilter;

  ThumbnailCacheMode _resolvedThumbnailCacheMode = ThumbnailCacheMode.appCache;

  static const int _maxScanDepth = 20;

  // Document-type extensions used only by _matchesFilter; has no media
  // equivalent in MediaViewerConstants so it stays local.
  static const _documentExts = {
    'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf',
    'csv', 'zip', 'tar', 'gz', 'json', 'xml',
  };

  bool get _atRoot => _pathStack.length == 1;
  String get _currentDirPath => _pathStack.last.fatPath;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _freeSpace = widget.container.freeSpace;
    _initSettingsAndContents();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _signalActivity() => widget.onUserActivity?.call();

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> _initSettingsAndContents() async {
    setState(() => _isLoading = true);
    try {
      if (widget.thumbnailCacheMode != null) {
        _resolvedThumbnailCacheMode = widget.thumbnailCacheMode!;
      } else {
        final appSettings = await AppSettingsService.loadSettings();
        final records = await ContainerRepository.instance.loadAll();
        final record = records[widget.container.uri];
        if (mounted) {
          setState(() {
            _resolvedThumbnailCacheMode =
                record?.thumbnailCacheMode ??
                appSettings.defaultThumbnailCacheMode;
          });
        }
      }
    } catch (e) {
      debugPrint('Failed to resolve thumbnail cache mode: $e');
    }
    await _loadDirectoryContents(_currentDirPath);
  }

  // ── Inline status ─────────────────────────────────────────────────────────

  void _setStatus(String msg, {bool error = false, Duration? autoClear}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = msg;
      _statusIsError = error;
    });
    final delay =
        autoClear ??
        (error ? const Duration(seconds: 5) : const Duration(seconds: 3));
    Future.delayed(delay, () {
      if (mounted && _statusMessage == msg)
        setState(() => _statusMessage = null);
    });
  }

  void _clearStatus() {
    if (mounted) setState(() => _statusMessage = null);
  }

  // ── Directory loading ─────────────────────────────────────────────────────

  Future<void> _loadDirectoryContents(String path) async {
    setState(() => _isLoading = true);
    _signalActivity();
    try {
      final items = await vaultExplorerApi.listDirectory(
        widget.container,
        path,
      );
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

  // ── Search ────────────────────────────────────────────────────────────────

  void _clearSearch() {
    _isSearchActive = false;
    _searchQuery = '';
    _searchController.clear();
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _enterDirectory(String rawDirEntry) {
    final entry = RawEntry.parse(rawDirEntry);
    final newPath = _currentDirPath.isEmpty
        ? entry.name
        : '$_currentDirPath/${entry.name}';
    setState(() {
      _pathStack.add(PathSegment(entry.name, newPath));
      _clearSearch();
      _currentFilter = null;
    });
    _loadDirectoryContents(newPath);
  }

  void _navigateUp() {
    if (_atRoot) return;
    setState(() {
      _pathStack.removeLast();
      _clearSearch();
      _currentFilter = null;
    });
    _loadDirectoryContents(_currentDirPath);
  }

  void _jumpTo(int index) {
    if (index == _pathStack.length - 1) return;
    setState(() {
      _pathStack.removeRange(index + 1, _pathStack.length);
      _clearSearch();
      _currentFilter = null;
    });
    _loadDirectoryContents(_currentDirPath);
  }

  // ── SelectionMixin override ───────────────────────────────────────────────

  @override
  void toggleSelectItem(String item) {
    super.toggleSelectItem(item);
    if (selectedFolderCount > 0) {
      fetchFolderSizes(widget.container, _currentDirPath);
    }
  }

  // ── Item interaction ──────────────────────────────────────────────────────

  void _handleDirTap(String rawItem) {
    _signalActivity();
    if (isSelectionMode)
      toggleSelectItem(rawItem);
    else
      _enterDirectory(rawItem);
  }

  Future<void> _handleFileTap(String rawItem) async {
    _signalActivity();
    if (isSelectionMode) {
      toggleSelectItem(rawItem);
      return;
    }
    final entry = RawEntry.parse(rawItem);
    final fullPath = _currentDirPath.isEmpty
        ? entry.name
        : '$_currentDirPath/${entry.name}';

    final parts = entry.name.split('.');
    final ext = parts.length > 1 ? parts.last.toLowerCase() : '';

    final settings = await AppSettingsService.loadSettings();
    final pref = settings.extensionPreferences[ext];

    if (pref == 'editor') {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              TextEditorScreen(container: widget.container, filePath: fullPath),
        ),
      );
      _loadDirectoryContents(_currentDirPath);
    } else if (pref == 'media') {
      _openMediaViewer(entry.name, fullPath);
    } else if (pref != null && pref.startsWith('package:')) {
      _openFileWithApp(entry.name, fullPath, packageName: pref.substring(8));
    } else if (pref == 'external') {
      _openFileWithApp(entry.name, fullPath);
    } else {
      // pref is null
      if (_isSupportedMedia(entry.name)) {
        _openMediaViewer(entry.name, fullPath);
      } else {
        if (!mounted) return;
        await _showOpenWithDialog(entry.name, fullPath, ext, settings);
      }
    }
  }

  void _openMediaViewer(String fileName, String fullPath) {
    final mediaEntries = _currentItems
        .where((f) => !f.startsWith('[DIR]') && !f.startsWith('System:'))
        .map((f) => RawEntry.parse(f).name)
        .where(_isSupportedMedia)
        .toList();
    final resolvedPaths = mediaEntries
        .map((f) => _currentDirPath.isEmpty ? f : '$_currentDirPath/$f')
        .toList();

    final index = mediaEntries.indexOf(fileName);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MediaViewerScreen(
          container: widget.container,
          mediaFiles: resolvedPaths.isNotEmpty ? resolvedPaths : [fullPath],
          initialIndex: index >= 0 ? index : 0,
          startingFolder: _currentDirPath,
        ),
      ),
    );
  }

  Future<void> _showOpenWithDialog(
    String fileName,
    String fullPath,
    String ext,
    AppSettings settings,
  ) async {
    bool remember = false;
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final isMedia = _isSupportedMedia(fileName);

    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Open File'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Choose how to open "$fileName":',
                    style: textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  InkWell(
                    onTap: () =>
                        Navigator.of(context).pop(isMedia ? 'media' : 'editor'),
                    borderRadius: BorderRadius.circular(12),
                    child: Ink(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerLow,
                        border: Border.all(color: cs.outlineVariant),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isMedia
                                ? Icons.play_circle_outline_rounded
                                : Icons.edit_note_rounded,
                            color: cs.primary,
                            size: 28,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isMedia
                                      ? 'In-app Media Viewer'
                                      : 'In-app Text Editor',
                                  style: textTheme.bodyLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  isMedia
                                      ? 'Play video/audio or view image in-app'
                                      : 'View/edit text, markdown, code',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: cs.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: () => Navigator.of(context).pop('external'),
                    borderRadius: BorderRadius.circular(12),
                    child: Ink(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerLow,
                        border: Border.all(color: cs.outlineVariant),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.open_in_new_rounded,
                            color: cs.secondary,
                            size: 28,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'External App',
                                  style: textTheme.bodyLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  'Send file to third-party app',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: cs.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Checkbox(
                        value: remember,
                        onChanged: (val) {
                          setDialogState(() {
                            remember = val ?? false;
                          });
                        },
                      ),
                      Expanded(
                        child: Text(
                          ext.isNotEmpty
                              ? 'Always remember choice for .$ext files'
                              : 'Always remember choice for files without extension',
                          style: textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == 'editor') {
      if (remember) {
        settings.extensionPreferences[ext] = 'editor';
        await AppSettingsService.saveSettings(settings);
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              TextEditorScreen(container: widget.container, filePath: fullPath),
        ),
      );
      _loadDirectoryContents(_currentDirPath);
    } else if (result == 'media') {
      if (remember) {
        settings.extensionPreferences[ext] = 'media';
        await AppSettingsService.saveSettings(settings);
      }
      _openMediaViewer(fileName, fullPath);
    } else if (result == 'external') {
      if (remember) {
        VaultExplorerApi.onAppSelectedCallback = (selectedExt, pkg) {
          if (selectedExt.toLowerCase() == ext.toLowerCase()) {
            settings.extensionPreferences[ext] = 'package:$pkg';
            AppSettingsService.saveSettings(settings);
            VaultExplorerApi.onAppSelectedCallback = null;
          }
        };
      }
      _openFileWithApp(fileName, fullPath);
    }
  }

  Future<void> _startMediaViewerFromCurrentLocation() async {
    _signalActivity();
    final localMedia = _currentItems
        .where((f) => !f.startsWith('[DIR]') && !f.startsWith('System:'))
        .map((f) => RawEntry.parse(f).name)
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
            startingFolder: _currentDirPath,
          ),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    _setStatus(
      'Scanning subfolders for media…',
      autoClear: const Duration(seconds: 15),
    );
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
              startingFolder: _currentDirPath,
            ),
          ),
        );
      } else {
        _setStatus(
          'No media files found in this folder or its subfolders',
          error: true,
        );
      }
    } catch (e) {
      _setStatus('Failed to scan subfolders: $e', error: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _handleItemLongPress(String rawItem) {
    HapticFeedback.selectionClick();
    _signalActivity();
    if (!isSelectionMode) {
      setState(() {
        isSelectionMode = true;
        selectedItems.add(rawItem);
      });
      if (selectedFolderCount > 0) {
        fetchFolderSizes(widget.container, _currentDirPath);
      }
    } else {
      toggleSelectItem(rawItem);
    }
  }

  // ── Media helpers ─────────────────────────────────────────────────────────

  /// Delegates to [MediaViewerConstants] — the single source of truth for
  /// supported media extensions across the entire viewer stack.
  bool _isSupportedMedia(String fileName) =>
      MediaViewerConstants.isSupported(fileName);

  Future<List<String>> _scanMediaRecursively(
    String dirPath, {
    int depth = 0,
  }) async {
    if (depth > _maxScanDepth) return [];
    final foundFiles = <String>[];
    final subdirNames = <String>[];
    try {
      final items = await vaultExplorerApi.listDirectory(
        widget.container,
        dirPath,
      );
      if (items != null) {
        for (final item in items) {
          if (item.startsWith('System:')) continue;
          final e = RawEntry.parse(item);
          if (e.isDir) {
            subdirNames.add(e.name);
          } else if (_isSupportedMedia(e.name)) {
            foundFiles.add(dirPath.isEmpty ? e.name : '$dirPath/${e.name}');
          }
        }
        if (subdirNames.isNotEmpty) {
          final nested = await Future.wait(
            subdirNames.map((name) {
              final subPath = dirPath.isEmpty ? name : '$dirPath/$name';
              return _scanMediaRecursively(subPath, depth: depth + 1);
            }),
          );
          for (final list in nested) {
            foundFiles.addAll(list);
          }
        }
      }
    } catch (e) {
      debugPrint('Error scanning subfolder for media: $e');
    }
    return foundFiles;
  }

  Future<void> _openFileWithApp(
    String cleanName,
    String fullPath, {
    String? packageName,
  }) async {
    _signalActivity();
    try {
      final ok = await vaultExplorerApi.openWithApp(
        widget.container,
        fullPath,
        packageName: packageName,
      );
      if (!ok && mounted) {
        _setStatus('No app found for this file type', error: true);
      }
    } catch (_) {
      if (mounted) _setStatus('Could not open "$cleanName"', error: true);
    }
  }

  // ── Clipboard init ────────────────────────────────────────────────────────

  void _initClipboard({required bool cut}) {
    _signalActivity();

    final clipItems = selectedItems.map((rawItem) {
      final entry = RawEntry.parse(rawItem);
      final path = _currentDirPath.isEmpty
          ? entry.name
          : '$_currentDirPath/${entry.name}';
      return ClipboardItem(
        path: path,
        isDir: entry.isDir,
        sizeBytes: entry.isDir ? 0 : entry.sizeBytes,
      );
    }).toList();

    _clip.set(
      volId: widget.container.volId,
      displayName: widget.container.displayName,
      cut: cut,
      clipItems: clipItems,
    );
    exitSelectionMode();
  }

  // ── Paste ─────────────────────────────────────────────────────────────────

  Future<void> _paste() async {
    if (!_clip.hasItems) return;
    _signalActivity();

    final srcVolId = _clip.sourceVolId;
    if (srcVolId == null) {
      _setStatus('Clipboard source is invalid', error: true);
      _clip.clear();
      return;
    }

    final isCrossContainer = !_clip.isFromVolume(widget.container.volId);
    MountedContainer? srcContainer;

    if (isCrossContainer) {
      if (widget.resolveContainer == null) {
        _setStatus('Cross-container paste is not configured.', error: true);
        return;
      }
      srcContainer = widget.resolveContainer!(srcVolId);
      if (srcContainer == null) {
        _setStatus(
          'Cross-container paste requires both containers to remain mounted.',
          error: true,
          autoClear: const Duration(seconds: 6),
        );
        _clip.clear();
        return;
      }
    } else {
      srcContainer = widget.container;
    }

    final items = List<ClipboardItem>.from(_clip.items);
    final isCut = _clip.isCutOperation;

    final existingRaw =
        await vaultExplorerApi.listDirectory(
          widget.container,
          _currentDirPath,
        ) ??
        [];
    if (!mounted) return;

    final existingNames = <String>{};
    final existingDirs = <String>{};
    for (final raw in existingRaw) {
      final e = RawEntry.parse(raw);
      existingNames.add(e.name.toLowerCase());
      if (e.isDir) existingDirs.add(e.name.toLowerCase());
    }

    final conflicts = <ConflictEntry>[];
    for (final item in items) {
      final fileName = item.name;
      if (!existingNames.contains(fileName.toLowerCase())) continue;

      final wouldBeSamePath =
          !isCrossContainer &&
          item.path ==
              (_currentDirPath.isEmpty
                  ? fileName
                  : '$_currentDirPath/$fileName');
      if (wouldBeSamePath) continue;

      conflicts.add(
        ConflictEntry(
          item: item,
          destIsDir: existingDirs.contains(fileName.toLowerCase()),
        ),
      );
    }

    ConflictPlan conflictPlan = const {};
    if (conflicts.isNotEmpty) {
      if (!mounted) return;
      final result = await ConflictResolutionSheet.show(
        context,
        conflicts: conflicts,
      );
      if (!mounted) return;
      if (result == null) return;
      conflictPlan = result;
    }

    final op = _opSvc.enqueue(
      isCut: isCut,
      source: srcContainer,
      dest: widget.container,
      destDirPath: _currentDirPath,
      items: items,
      conflictPlan: conflictPlan,
    );

    _clip.clear();

    void listener() {
      if (!mounted) {
        op.removeListener(listener);
        return;
      }
      final done =
          op.status != FileOperationStatus.pending &&
          op.status != FileOperationStatus.running;
      if (done) {
        op.removeListener(listener);
        _loadDirectoryContents(_currentDirPath);
      }
    }

    op.addListener(listener);
  }

  // ── Batch delete ──────────────────────────────────────────────────────────

  void _batchDelete() {
    HapticFeedback.heavyImpact();
    _signalActivity();
    BrowserDialogs.showBatchDelete(
      context,
      toDelete: List<String>.from(selectedItems),
      onConfirmed: (rawItems) async {
        setState(() => _isLoading = true);

        final clipItems = rawItems.map((raw) {
          final e = RawEntry.parse(raw);
          final path = _currentDirPath.isEmpty
              ? e.name
              : '$_currentDirPath/${e.name}';
          return ClipboardItem(path: path, isDir: e.isDir);
        }).toList();

        int failCount = 0;
        final deleted = await _opSvc.deleteItems(
          container: widget.container,
          items: clipItems,
          onProgress: (done, total) {},
        );
        failCount = clipItems.length - deleted;

        exitSelectionMode();
        await _loadDirectoryContents(_currentDirPath);
        _setStatus(
          failCount == 0
              ? 'Deleted $deleted item(s)'
              : '$deleted deleted · $failCount failed',
          error: failCount > 0,
        );
      },
    );
  }

  // ── Import / Export ───────────────────────────────────────────────────────

  Future<void> _exportSelectedToStorage() async {
    _signalActivity();
    final items = selectedItems.map((raw) {
      final e = RawEntry.parse(raw);
      final path = _currentDirPath.isEmpty
          ? e.name
          : '$_currentDirPath/${e.name}';
      return <String, dynamic>{'path': path, 'isDir': e.isDir};
    }).toList();
    if (items.isEmpty) return;

    setState(() => _isLoading = true);
    try {
      final count = await vaultExplorerApi.exportSelectedToFolder(
        widget.container,
        items,
      );
      _setStatus(
        count > 0 ? 'Exported $count file(s)' : 'Export cancelled or failed',
        error: count == 0,
      );
    } catch (e) {
      _setStatus('Export error: ${e.runtimeType}', error: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
    exitSelectionMode();
  }

  Future<void> _importFilesFromDevice() async {
    _signalActivity();
    setState(() => _isLoading = true);
    try {
      final count = await vaultExplorerApi.importFiles(
        widget.container,
        _currentDirPath,
      );
      if (count > 0) await _loadDirectoryContents(_currentDirPath);
      _setStatus(
        count > 0
            ? 'Imported $count file${count != 1 ? 's' : ''}'
            : 'No files imported',
        error: count == 0,
      );
    } catch (e) {
      _setStatus('Import failed: ${e.runtimeType}', error: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _importFolderFromDevice() async {
    _signalActivity();
    setState(() => _isLoading = true);
    try {
      final count = await vaultExplorerApi.importFolder(
        widget.container,
        _currentDirPath,
      );
      if (count > 0) await _loadDirectoryContents(_currentDirPath);
      _setStatus(
        count > 0
            ? 'Imported $count item${count != 1 ? 's' : ''}'
            : 'No files imported',
        error: count == 0,
      );
    } catch (e) {
      _setStatus('Folder import failed: ${e.runtimeType}', error: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Filter helpers ────────────────────────────────────────────────────────

  bool _matchesFilter(String fileName) {
    if (_currentFilter == null) return true;
    switch (_currentFilter) {
      case 'image':
        return MediaViewerConstants.isImage(fileName);
      case 'video':
        return MediaViewerConstants.isVideo(fileName);
      case 'audio':
        return MediaViewerConstants.isAudio(fileName);
      case 'document':
        return _documentExts
            .contains(fileName.split('.').last.toLowerCase());
      default:
        return true;
    }
  }

  Widget _buildSortMenuButton(
    SortBy value,
    String label,
    ColorScheme cs,
    TextTheme textTheme,
  ) {
    final isActive = sortBy == value;
    return MenuItemButton(
      onPressed: () => setSort(value),
      leadingIcon: Icon(
        isActive
            ? (sortAscending
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded)
            : Icons.sort_rounded,
        size: 16,
        color: isActive ? cs.primary : cs.onSurfaceVariant,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontWeight: isActive ? FontWeight.w700 : FontWeight.normal,
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final dirs = _currentItems.where((f) => f.startsWith('[DIR]')).toList()
      ..sort(compareItems);
    final files =
        _currentItems
            .where((f) => !f.startsWith('[DIR]') && !f.startsWith('System:'))
            .toList()
          ..sort(compareItems);

    final query = _searchQuery.trim().toLowerCase();

    final filteredDirs = (query.isEmpty && _currentFilter == null)
        ? dirs
        : (query.isEmpty
              ? <String>[]
              : dirs
                    .where(
                      (d) =>
                          RawEntry.parse(d).name.toLowerCase().contains(query),
                    )
                    .toList());

    final filteredFiles = files.where((f) {
      final name = RawEntry.parse(f).name;
      if (query.isNotEmpty && !name.toLowerCase().contains(query)) return false;
      return _matchesFilter(name);
    }).toList();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        if (isSelectionMode) {
          exitSelectionMode();
        } else if (_clip.hasItems &&
            _clip.isFromVolume(widget.container.volId)) {
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
            if (_clip.hasItems)
              ClipboardBanner(
                isCutOperation: _clip.isCutOperation,
                itemCount: _clip.items.length,
                sourceLabel: _clip.isFromVolume(widget.container.volId)
                    ? null
                    : _clip.sourceDisplayName,
                onCancel: () => setState(() => _clip.clear()),
                onPaste: _paste,
              ),
            _StatsBar(
              dirCount: filteredDirs.length,
              fileCount: filteredFiles.length,
              freeSpaceBytes: _freeSpace,
              isFiltered: query.isNotEmpty || _currentFilter != null,
            ),
            _FilterChipsBar(
              currentFilter: _currentFilter,
              onFilterChanged: (filter) =>
                  setState(() => _currentFilter = filter),
            ),
            const Divider(),
            Expanded(child: _buildBody(filteredDirs, filteredFiles)),
            const OperationProgressBar(),
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
    BuildContext context,
    List<String> dirs,
    List<String> files,
  ) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final allItems = [...dirs, ...files];

    if (isSelectionMode) {
      final single = selectedItems.length == 1;
      final singleFile = single && !selectedItems.first.startsWith('[DIR] ');

      final totalBytes = selectedTotalBytes;
      final isPending = hasPendingFolderSizes;
      final sizeLabel = isPending
          ? (totalBytes > 0
                ? '${formatBytes(totalBytes)} (calculating…)'
                : 'calculating…')
          : formatBytes(totalBytes);

      return SelectionAppBar(
        selectedCount: selectedItems.length,
        selectionLabel: sizeLabel,
        singleSelected: single,
        singleFileSelected: singleFile,
        onClose: exitSelectionMode,
        onSelectAll: () => setState(() => selectedItems.addAll(allItems)),
        onRename: () {
          final entry = RawEntry.parse(selectedItems.first);
          BrowserDialogs.showRename(
            context,
            container: widget.container,
            oldName: entry.name,
            currentDirPath: _currentDirPath,
            onSuccess: () => _loadDirectoryContents(_currentDirPath),
          );
          exitSelectionMode();
        },
        onCopy: () => _initClipboard(cut: false),
        onCut: () => _initClipboard(cut: true),
        onExport: _exportSelectedToStorage,
        onDelete: _batchDelete,
        onOpenWithApp: () async {
          final entry = RawEntry.parse(selectedItems.first);
          final path = _currentDirPath.isEmpty
              ? entry.name
              : '$_currentDirPath/${entry.name}';
          final parts = entry.name.split('.');
          final ext = parts.length > 1 ? parts.last.toLowerCase() : '';
          exitSelectionMode();
          final settings = await AppSettingsService.loadSettings();
          if (mounted) {
            await _showOpenWithDialog(entry.name, path, ext, settings);
          }
        },
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
          style: textTheme.bodyMedium?.copyWith(color: cs.onSurface),
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
        onPressed: _atRoot ? () => Navigator.of(context).pop() : _navigateUp,
      ),
      title: Text(widget.container.displayName),
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
            _signalActivity();
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
              child: Row(
                children: [
                  Icon(
                    Icons.create_new_folder_outlined,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  const Text('New Folder'),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'file',
              child: Row(
                children: [
                  Icon(
                    Icons.insert_drive_file_outlined,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  const Text('New File'),
                ],
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'import',
              child: Row(
                children: [
                  Icon(Icons.upload_file_outlined, color: cs.onSurfaceVariant),
                  const SizedBox(width: 12),
                  const Text('Import Files'),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'import_folder',
              child: Row(
                children: [
                  Icon(
                    Icons.drive_folder_upload_outlined,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  const Text('Import Folder'),
                ],
              ),
            ),
          ],
        ),
        MenuAnchor(
          builder: (ctx, controller, child) => IconButton(
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.more_vert_rounded),
            tooltip: 'Folder options',
          ),
          menuChildren: [
            MenuItemButton(
              onPressed: () {
                final hasLocalMedia = _currentItems
                    .where(
                      (f) => !f.startsWith('[DIR]') && !f.startsWith('System:'),
                    )
                    .map((f) => RawEntry.parse(f).name)
                    .any(_isSupportedMedia);
                final hasSubfolders = _currentItems.any(
                  (f) => f.startsWith('[DIR] '),
                );
                if (hasLocalMedia || hasSubfolders) {
                  _startMediaViewerFromCurrentLocation();
                }
              },
              leadingIcon: Icon(
                Icons.play_circle_outline_rounded,
                color: cs.primary,
              ),
              child: const Text('Play Media Here'),
            ),
            const PopupMenuDivider(),
            MenuItemButton(
              onPressed: () => setState(() {
                _layoutMode = _layoutMode == BrowserLayoutMode.list
                    ? BrowserLayoutMode.grid
                    : BrowserLayoutMode.list;
              }),
              leadingIcon: Icon(
                _layoutMode == BrowserLayoutMode.list
                    ? Icons.grid_view_rounded
                    : Icons.view_list_rounded,
              ),
              child: Text(
                _layoutMode == BrowserLayoutMode.list
                    ? 'Switch to Gallery'
                    : 'Switch to List',
              ),
            ),
            const PopupMenuDivider(),
            SubmenuButton(
              menuChildren: [
                _buildSortMenuButton(SortBy.name, 'Name', cs, textTheme),
                _buildSortMenuButton(SortBy.size, 'Size', cs, textTheme),
                _buildSortMenuButton(SortBy.extension, 'Type', cs, textTheme),
                _buildSortMenuButton(SortBy.date, 'Date', cs, textTheme),
              ],
              child: const Text('Sort By'),
            ),
          ],
        ),
      ],
    );
  }

  // ── Body ──────────────────────────────────────────────────────────────────

  Widget _buildBody(List<String> dirs, List<String> files) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_currentItems.isEmpty) {
      return _EmptyPlaceholder(onBack: _navigateUp, atRoot: _atRoot);
    }
    if (_searchQuery.trim().isNotEmpty && dirs.isEmpty && files.isEmpty) {
      return _SearchEmptyState(query: _searchQuery.trim());
    }

    if (_isListingTruncated) {
      _TruncatedBanner();
    }

    if (_layoutMode == BrowserLayoutMode.grid) {
      return FileGridView(
        container: widget.container,
        dirs: dirs,
        files: files,
        isSelectionMode: isSelectionMode,
        selectedItems: selectedItems,
        currentDirPath: _currentDirPath,
        thumbnailCacheMode: _resolvedThumbnailCacheMode,
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
// New widget — same visual language as _StatusBar:
class _TruncatedBanner extends StatelessWidget {
  const _TruncatedBanner();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      color: cs.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, size: 16,
             color: cs.onTertiaryContainer),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Showing first 50,000 items — this folder has more files.',
            style: textTheme.bodySmall?.copyWith(
              color: cs.onTertiaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ]),
    );
  }
}
// ── Filter chips bar ──────────────────────────────────────────────────────────

class _FilterChipsBar extends StatelessWidget {
  final String? currentFilter;
  final ValueChanged<String?> onFilterChanged;
  const _FilterChipsBar({
    required this.currentFilter,
    required this.onFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      color: cs.surface,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        children: [
          _chip(context, null, 'All Files', Icons.all_inclusive_rounded),
          const SizedBox(width: 8),
          _chip(context, 'image', 'Images', Icons.image_outlined),
          const SizedBox(width: 8),
          _chip(context, 'video', 'Videos', Icons.videocam_outlined),
          const SizedBox(width: 8),
          _chip(context, 'audio', 'Audio', Icons.audiotrack_rounded),
          const SizedBox(width: 8),
          _chip(context, 'document', 'Documents', Icons.description_outlined),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    String? filter,
    String label,
    IconData icon,
  ) {
    final cs = Theme.of(context).colorScheme;
    final isSelected = currentFilter == filter;
    return FilterChip(
      showCheckmark: false,
      avatar: Icon(
        icon,
        size: 16,
        color: isSelected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
      ),
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) => onFilterChanged(selected ? filter : null),
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
    final textTheme = Theme.of(context).textTheme;
    final bg = isError ? cs.errorContainer : cs.primaryContainer;
    final fg = isError ? cs.onErrorContainer : cs.onPrimaryContainer;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Container(
        key: ValueKey(message),
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : Icons.info_outline_rounded,
              size: 16,
              color: fg,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: textTheme.bodySmall?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            GestureDetector(
              onTap: onDismiss,
              child: Icon(Icons.close_rounded, size: 16, color: fg),
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
    final textTheme = Theme.of(context).textTheme;
    return Container(
      color: cs.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          _stat(context, Icons.folder_rounded, '$dirCount folders'),
          const SizedBox(width: 12),
          _stat(context, Icons.description_rounded, '$fileCount files'),
          const Spacer(),
          if (isFiltered) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(100),
              ),
              child: Text(
                'filtered',
                style: textTheme.labelSmall?.copyWith(
                  color: cs.onPrimaryContainer,
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          _stat(
            context,
            Icons.storage_rounded,
            '${formatBytes(freeSpaceBytes)} free',
          ),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, IconData icon, String text) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          text,
          style: textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
    );
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
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_rounded, size: 48, color: cs.outline),
            const SizedBox(height: 16),
            Text(
              'Empty Folder',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap + to create files or import from device.',
              style: textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            if (!atRoot) ...[
              const SizedBox(height: 20),
              TextButton.icon(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_upward_rounded, size: 16),
                label: const Text('Go back'),
              ),
            ],
          ],
        ),
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
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, size: 48, color: cs.outline),
            const SizedBox(height: 16),
            Text(
              'No results',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Nothing in this folder matches "$query".',
              style: textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}