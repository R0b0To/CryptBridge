import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/mounted_container.dart';
import '../../services/local_streaming_server.dart';
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

  // ── Core state ───────────────────────────────────────────────────────────────
  final List<PathSegment> _pathStack = [const PathSegment('Root', '')];
  List<String> _currentItems = [];
  bool _isLoading = false;
  int _freeSpace = 0;

  // ── Clipboard state ──────────────────────────────────────────────────────────
  bool _isClipboardMode = false;
  bool _isCutOperation = false;
  List<Map<String, dynamic>> _clipboardSourceItems = [];

  // ── Search state ─────────────────────────────────────────────────────────────
  bool _isSearchActive = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  // ── Layout state ─────────────────────────────────────────────────────────────
  BrowserLayoutMode _layoutMode = BrowserLayoutMode.list;

  // ── Streaming server (gallery thumbnails) ────────────────────────────────────
  LocalStreamingServer? _streamingServer;
  int? _streamingServerPort;

  // ── Convenience getters ───────────────────────────────────────────────────────
  bool get _atRoot => _pathStack.length == 1;
  String get _currentDirPath => _pathStack.last.fatPath;

  // ── Lifecycle ─────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _freeSpace = widget.container.freeSpace;
    _loadDirectoryContents('');
    _startStreamingServer();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _streamingServer?.stop();
    super.dispose();
  }

  // ── Streaming server ──────────────────────────────────────────────────────────

  Future<void> _startStreamingServer() async {
    try {
      _streamingServer = LocalStreamingServer(widget.container);
      final port = await _streamingServer!.start().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw Exception('Streaming server timed out'),
      );
      if (mounted) setState(() => _streamingServerPort = port);
    } catch (e) {
      debugPrint('FileBrowser: streaming server failed to start – $e');
    }
  }

  // ── Directory loading ─────────────────────────────────────────────────────────
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed loading folder: ${e.runtimeType}'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    }
  }

  // ── Search helpers ────────────────────────────────────────────────────────────

  void _clearSearch() {
    _isSearchActive = false;
    _searchQuery = '';
    _searchController.clear();
  }

  // ── Navigation ────────────────────────────────────────────────────────────────
  void _enterDirectory(String rawDirEntry) {
    final name = rawDirEntry.replaceFirst('[DIR] ', '');
    final newPath =
        _currentDirPath.isEmpty ? name : '$_currentDirPath/$name';
    setState(() {
      _pathStack.add(PathSegment(name, newPath));
      _clearSearch(); // search resets when entering a subfolder
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

  // ── Item tap / long-press ─────────────────────────────────────────────────────
  void _handleDirTap(String rawItem) {
    if (isSelectionMode) {
      toggleSelectItem(rawItem);
    } else {
      _enterDirectory(rawItem);
    }
  }

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
          ),
        ),
      );
    } else {
      _openFileWithApp(cleanName, fullPath);
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

  // ── Media helpers ─────────────────────────────────────────────────────────────
  bool _isSupportedMedia(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return const {
      'jpg', 'jpeg', 'png', 'gif', 'webp',
      'mp4', 'm4v', 'webm', 'mov', 'avi', 'mkv'
    }.contains(ext);
  }

  Future<void> _openFileWithApp(String cleanName, String fullPath) async {
    try {
      final ok =
          await vaultExplorerApi.openWithApp(widget.container, fullPath);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No app found for this file type'),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not open "$cleanName"'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    }
  }



  // ── Clipboard ─────────────────────────────────────────────────────────────────
  void _initClipboard({required bool cut}) {
    final sources = selectedItems.map((item) {
      final isDir = item.startsWith('[DIR] ');
      final name =
          isDir ? item.replaceFirst('[DIR] ', '') : item.split('|').first;
      final path =
          _currentDirPath.isEmpty ? name : '$_currentDirPath/$name';
      return <String, dynamic>{'path': path, 'isDir': isDir};
    }).toList();

    setState(() {
      _isClipboardMode = true;
      _isCutOperation = cut;
      _clipboardSourceItems = sources;
      isSelectionMode = false;
      selectedItems.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(cut
          ? 'Cut ${sources.length} item(s) — navigate and tap Paste'
          : 'Copied ${sources.length} item(s) — navigate and tap Paste'),
      duration: const Duration(seconds: 4),
    ));
  }

  void _cancelClipboard() => setState(() {
        _isClipboardMode = false;
        _clipboardSourceItems.clear();
      });

  Future<void> _copyEntryRecursive(
    String srcPath,
    String destPath,
    bool isDir,
    Directory tmpDir,
  ) async {
    if (!isDir) {
      final tempFile =
          File(TempFileUtils.uniquePath(tmpDir, prefix: 'cb_copy'));
      try {
        final ok = await vaultExplorerApi.decryptFile(
            widget.container, srcPath, tempFile.path);
        if (ok) {
          await vaultExplorerApi.writeBackFile(
              widget.container, destPath, tempFile.path);
        }
      } finally {
        if (await tempFile.exists()) await tempFile.delete();
      }
      return;
    }

    await vaultExplorerApi.createDirectory(widget.container, destPath);
    final children =
        await vaultExplorerApi.listDirectory(widget.container, srcPath) ?? [];
    for (final entry in children) {
      if (entry.startsWith('System:')) continue;
      final childIsDir = entry.startsWith('[DIR] ');
      final childName = childIsDir
          ? entry.replaceFirst('[DIR] ', '')
          : entry.split('|').first;
      await _copyEntryRecursive(
        '$srcPath/$childName',
        '$destPath/$childName',
        childIsDir,
        tmpDir,
      );
    }
  }

  Future<void> _pasteClipboard() async {
    setState(() => _isLoading = true);
    final tmpDir = await getTemporaryDirectory();
    try {
      for (final src in _clipboardSourceItems) {
        final srcPath = src['path'] as String;
        final isDir = src['isDir'] as bool;
        final fileName = srcPath.split('/').last;
        final destPath = _currentDirPath.isEmpty
            ? fileName
            : '$_currentDirPath/$fileName';
        if (srcPath == destPath) continue;
        if (_isCutOperation) {
          await vaultExplorerApi.renameFile(
              widget.container, srcPath, destPath);
        } else {
          await _copyEntryRecursive(srcPath, destPath, isDir, tmpDir);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Operation failed: ${e.runtimeType}'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    } finally {
      setState(() {
        _isClipboardMode = false;
        _clipboardSourceItems.clear();
        _isLoading = false;
      });
      _loadDirectoryContents(_currentDirPath);
    }
  }

  // ── Import / Export ───────────────────────────────────────────────────────────
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

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Preparing export for ${items.length} item(s)…')));
    setState(() => _isLoading = true);
    try {
      final count = await vaultExplorerApi.exportSelectedToFolder(
          widget.container, items);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(count > 0
              ? 'Exported $count file(s)'
              : 'Export cancelled or failed'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Export error: ${e.runtimeType}'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
    exitSelectionMode();
  }

  Future<void> _importFilesFromDevice() async {
    setState(() => _isLoading = true);
    try {
      final count = await vaultExplorerApi.importFiles(
          widget.container, _currentDirPath);
      if (count > 0) _loadDirectoryContents(_currentDirPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(count > 0
              ? 'Imported $count file${count != 1 ? 's' : ''}'
              : 'No files imported'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Import failed: ${e.runtimeType}'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _importFolderFromDevice() async {
    setState(() => _isLoading = true);
    try {
      final count = await vaultExplorerApi.importFolder(
          widget.container, _currentDirPath);
      if (count > 0) _loadDirectoryContents(_currentDirPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(count > 0
              ? 'Imported $count item${count != 1 ? 's' : ''}'
              : 'No files imported'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Folder import failed: ${e.runtimeType}'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Batch delete ──────────────────────────────────────────────────────────────
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
            final full = _currentDirPath.isEmpty
                ? name
                : '$_currentDirPath/$name';
            if (!await vaultExplorerApi.deleteFile(widget.container, full)) {
              failCount++;
            }
          }
        } finally {
          exitSelectionMode();
          _loadDirectoryContents(_currentDirPath);
          if (mounted) {
            final successCount = items.length - failCount;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(failCount == 0
                  ? 'Deleted $successCount item(s)'
                  : '$successCount deleted — $failCount failed'),
              backgroundColor: failCount == 0
                  ? null
                  : Theme.of(context).colorScheme.error,
            ));
          }
        }
      },
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // Sort full list first
    final dirs = _currentItems.where((f) => f.startsWith('[DIR]')).toList()
      ..sort(compareItems);
    final files = _currentItems
        .where((f) => !f.startsWith('[DIR]') && !f.startsWith('System:'))
        .toList()
      ..sort(compareItems);

    // Apply in-folder search filter
    final query = _searchQuery.trim().toLowerCase();
    final filteredDirs = query.isEmpty
        ? dirs
        : dirs
            .where((d) => d
                .replaceFirst('[DIR] ', '')
                .toLowerCase()
                .contains(query))
            .toList();
    final filteredFiles = query.isEmpty
        ? files
        : files
            .where((f) => f.split('|').first.toLowerCase().contains(query))
            .toList();

    return Scaffold(
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
        ],
      ),
    );
  }

  // ── App bar ───────────────────────────────────────────────────────────────────
  PreferredSizeWidget _buildAppBar(
      BuildContext context, List<String> dirs, List<String> files) {
    final cs = Theme.of(context).colorScheme;
    final allSelectable = [...dirs, ...files];

    // ── Selection mode ──────────────────────────────────────────────────────
    if (isSelectionMode) {
      final single = selectedItems.length == 1;
      final singleFile =
          single && !selectedItems.first.startsWith('[DIR] ');
      return SelectionAppBar(
        selectedCount: selectedItems.length,
        singleSelected: single,
        singleFileSelected: singleFile,
        onClose: exitSelectionMode,
        onSelectAll: () =>
            setState(() => selectedItems.addAll(allSelectable)),
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

    // ── Clipboard mode ──────────────────────────────────────────────────────
    if (_isClipboardMode) {
      return ClipboardAppBar(
        isCutOperation: _isCutOperation,
        itemCount: _clipboardSourceItems.length,
        onCancel: _cancelClipboard,
        onPaste: _pasteClipboard,
      );
    }

    // ── Search mode ─────────────────────────────────────────────────────────
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

    // ── Normal app bar ──────────────────────────────────────────────────────
    return AppBar(
      leading: _atRoot
          ? null
          : IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Go up',
              onPressed: _navigateUp,
            ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.container.displayName,
              style: const TextStyle(fontSize: 14)),
        ],
      ),
      actions: [
        // Search
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Search in this folder',
          onPressed: () => setState(() => _isSearchActive = true),
        ),
        // Layout toggle: list ↔ gallery
        IconButton(
          icon: Icon(
            _layoutMode == BrowserLayoutMode.list
                ? Icons.grid_view_rounded
                : Icons.view_list_rounded,
          ),
          tooltip: _layoutMode == BrowserLayoutMode.list
              ? 'Gallery view'
              : 'List view',
          onPressed: () => setState(() {
            _layoutMode = _layoutMode == BrowserLayoutMode.list
                ? BrowserLayoutMode.grid
                : BrowserLayoutMode.list;
          }),
        ),
        // Sort
        PopupMenuButton<SortBy>(
          icon: const Icon(Icons.sort),
          tooltip: 'Sort by',
          onSelected: setSort,
          itemBuilder: (_) => [
            buildSortMenuItem(SortBy.name, 'Name'),
            buildSortMenuItem(SortBy.size, 'Size'),
            buildSortMenuItem(SortBy.extension, 'Type'),
          ],
        ),
        // New / import
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
                  onSuccess: () =>
                      _loadDirectoryContents(_currentDirPath),
                );
              case 'file':
                BrowserDialogs.showCreateFile(
                  context,
                  container: widget.container,
                  currentDirPath: _currentDirPath,
                  onSuccess: () =>
                      _loadDirectoryContents(_currentDirPath),
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
                Icon(Icons.upload_file_outlined,
                    color: cs.onSurfaceVariant),
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
      ],
    );
  }

  // ── Body ──────────────────────────────────────────────────────────────────────
  Widget _buildBody(List<String> dirs, List<String> files) {
    if (_isLoading) {
      return const Center(
          child: CircularProgressIndicator(strokeWidth: 2));
    }

    // Real empty directory (not just an empty search result)
    if (_currentItems.isEmpty) {
      return _EmptyPlaceholder(onBack: _navigateUp, atRoot: _atRoot);
    }

    // Search active but nothing matched
    if (_searchQuery.trim().isNotEmpty &&
        dirs.isEmpty &&
        files.isEmpty) {
      return _SearchEmptyState(query: _searchQuery.trim());
    }

    if (_layoutMode == BrowserLayoutMode.grid) {
      return FileGridView(
        dirs: dirs,
        files: files,
        isSelectionMode: isSelectionMode,
        selectedItems: selectedItems,
        currentDirPath: _currentDirPath,
        streamingServerPort: _streamingServerPort,
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

// ── Stats bar ──────────────────────────────────────────────────────────────────

class _StatsBar extends StatelessWidget {
  final int dirCount;
  final int fileCount;
  final int freeSpaceBytes;

  /// True when the counts reflect a search filter rather than the full directory.
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
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

// ── Empty states ───────────────────────────────────────────────────────────────

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
          Text(
            'No results',
            style: Theme.of(context).textTheme.titleMedium,
          ),
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