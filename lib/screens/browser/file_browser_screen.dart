import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/mounted_container.dart';
import '../../services/vaultexplorer_api.dart';
import '../../utils/format_utils.dart';
import 'widgets/breadcrumb_bar.dart';
import 'widgets/directory_tile.dart';
import 'widgets/file_tile.dart';
import 'media_viewer_screen.dart';

class PathSegment {
  final String label;
  final String fatPath;
  const PathSegment(this.label, this.fatPath);
}

enum _SortBy { name, size, extension }

class FileBrowserScreen extends StatefulWidget {
  final MountedContainer container;
  const FileBrowserScreen({Key? key, required this.container})
      : super(key: key);

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  final List<PathSegment> _pathStack = [const PathSegment('Root', '')];

  List<String> _currentItems = [];
  bool _isLoading = false;
  int _freeSpace = 0;

  bool _isSelectionMode = false;
  final Set<String> _selectedItems = {};

  bool _isClipboardMode = false;
  bool _isCutOperation = false;

  // Each entry: {'path': String, 'isDir': bool}
  List<Map<String, dynamic>> _clipboardSourceItems = [];

  _SortBy _sortBy = _SortBy.name;
  bool _sortAscending = true;

  @override
  void initState() {
    super.initState();
    _freeSpace = widget.container.freeSpace;
    _loadDirectoryContents('');
  }

  bool get _atRoot => _pathStack.length == 1;

  // ---------------------------------------------------------------------------
  // Directory loading
  // ---------------------------------------------------------------------------

  Future<void> _loadDirectoryContents(String path) async {
    setState(() => _isLoading = true);
    try {
      final items =
          await vaultExplorerApi.listDirectory(widget.container, path);
      final space =
          await vaultExplorerApi.getSpaceInfo(widget.container);
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed loading folder: $e'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Selection
  // ---------------------------------------------------------------------------

  void _toggleSelectItem(String item) => setState(() {
        if (_selectedItems.contains(item)) {
          _selectedItems.remove(item);
          if (_selectedItems.isEmpty) _isSelectionMode = false;
        } else {
          _selectedItems.add(item);
        }
      });

  void _exitSelectionMode() => setState(() {
        _isSelectionMode = false;
        _selectedItems.clear();
      });

  // ---------------------------------------------------------------------------
  // Clipboard — supports recursive folder copy (fix for issue #4)
  // ---------------------------------------------------------------------------

  void _initClipboard({required bool cut}) {
    final currentDir = _pathStack.last.fatPath;
    final sources = <Map<String, dynamic>>[];
    for (final item in _selectedItems) {
      final isDir = item.startsWith('[DIR] ');
      final name = isDir
          ? item.replaceFirst('[DIR] ', '')
          : item.split('|').first;
      final path =
          currentDir.isEmpty ? name : '$currentDir/$name';
      sources.add({'path': path, 'isDir': isDir});
    }
    setState(() {
      _isClipboardMode = true;
      _isCutOperation = cut;
      _clipboardSourceItems = sources;
      _isSelectionMode = false;
      _selectedItems.clear();
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

  /// Recursively copies [srcPath] to [destPath] inside the container.
  /// Handles both individual files and entire directory trees.
  Future<void> _copyEntryRecursive(
    String srcPath,
    String destPath,
    bool isDir,
    Directory tmpDir,
  ) async {
    if (!isDir) {
      final tempFile = File(
          '${tmpDir.path}/cb_${DateTime.now().microsecondsSinceEpoch}_${srcPath.hashCode}');
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

    // Directory: create the destination folder then recurse into children.
    await vaultExplorerApi.createDirectory(widget.container, destPath);
    final children =
        await vaultExplorerApi.listDirectory(widget.container, srcPath) ??
            [];
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
    final targetDir = _pathStack.last.fatPath;
    setState(() => _isLoading = true);
    final tmpDir = await getTemporaryDirectory();

    try {
      for (final src in _clipboardSourceItems) {
        final srcPath = src['path'] as String;
        final isDir = src['isDir'] as bool;
        final fileName = srcPath.split('/').last;
        final destPath =
            targetDir.isEmpty ? fileName : '$targetDir/$fileName';
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Operation failed: $e'),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() {
        _isClipboardMode = false;
        _clipboardSourceItems.clear();
        _isLoading = false;
      });
      _loadDirectoryContents(_pathStack.last.fatPath);
    }
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _enterDirectory(String rawDirEntry) {
    final name = rawDirEntry.replaceFirst('[DIR] ', '');
    final newPath = _pathStack.last.fatPath.isEmpty
        ? name
        : '${_pathStack.last.fatPath}/$name';
    setState(() => _pathStack.add(PathSegment(name, newPath)));
    _loadDirectoryContents(newPath);
  }

  void _navigateUp() {
    if (_atRoot) return;
    setState(() => _pathStack.removeLast());
    _loadDirectoryContents(_pathStack.last.fatPath);
  }

  void _jumpTo(int index) {
    if (index == _pathStack.length - 1) return;
    setState(() =>
        _pathStack.removeRange(index + 1, _pathStack.length));
    _loadDirectoryContents(_pathStack.last.fatPath);
  }

  bool _isSupportedMedia(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return [
      'jpg', 'jpeg', 'png', 'gif', 'webp',
      'mp4', 'm4v', 'webm', 'mov', 'avi', 'mkv',
    ].contains(ext);
  }

  // ---------------------------------------------------------------------------
  // Open with external app
  // ---------------------------------------------------------------------------

  Future<void> _openFileWithApp(
      String cleanName, String fullPath) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await vaultExplorerApi.openWithApp(
          widget.container, fullPath);
      if (!ok && mounted) {
        messenger.showSnackBar(const SnackBar(
          content:
              Text('No app found that can open this file type'),
        ));
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text('Could not open "$cleanName": $e'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // CRUD dialogs
  // ---------------------------------------------------------------------------

  void _showCreateFolderDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New Folder',
            style: TextStyle(fontSize: 16)),
        content: TextField(
            controller: ctrl,
            decoration:
                const InputDecoration(hintText: 'Folder name'),
            autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(context);
              final full = _pathStack.last.fatPath.isEmpty
                  ? name
                  : '${_pathStack.last.fatPath}/$name';
              if (await vaultExplorerApi.createDirectory(
                  widget.container, full)) {
                _loadDirectoryContents(_pathStack.last.fatPath);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showCreateFileDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New Text File',
            style: TextStyle(fontSize: 16)),
        content: TextField(
            controller: ctrl,
            decoration:
                const InputDecoration(hintText: 'filename.txt'),
            autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(context);
              final full = _pathStack.last.fatPath.isEmpty
                  ? name
                  : '${_pathStack.last.fatPath}/$name';
              if (await vaultExplorerApi.createEmptyFile(
                  widget.container, full)) {
                _loadDirectoryContents(_pathStack.last.fatPath);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(String oldName) {
    final ctrl = TextEditingController(text: oldName);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title:
            const Text('Rename', style: TextStyle(fontSize: 16)),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final newName = ctrl.text.trim();
              if (newName.isEmpty || newName == oldName) return;
              Navigator.pop(context);
              final dir = _pathStack.last.fatPath;
              final oldFull =
                  dir.isEmpty ? oldName : '$dir/$oldName';
              final newFull =
                  dir.isEmpty ? newName : '$dir/$newName';
              if (await vaultExplorerApi.renameFile(
                  widget.container, oldFull, newFull)) {
                _loadDirectoryContents(dir);
              }
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportSelectedToStorage() async {
    final currentDir = _pathStack.last.fatPath;
    final items = _selectedItems.map((item) {
      final isDir = item.startsWith('[DIR] ');
      final name = isDir
          ? item.replaceFirst('[DIR] ', '')
          : item.split('|').first;
      final path =
          currentDir.isEmpty ? name : '$currentDir/$name';
      return {'path': path, 'isDir': isDir};
    }).toList();
    if (items.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
        content: Text(
            'Preparing export for ${items.length} item(s)…')));
    setState(() => _isLoading = true);
    try {
      final count = await vaultExplorerApi.exportSelectedToFolder(
          widget.container, items);
      messenger.showSnackBar(SnackBar(
        content: Text(count > 0
            ? 'Exported $count file(s)'
            : 'Export cancelled or failed'),
        backgroundColor:
            count > 0 ? const Color(0xFF1A3A2A) : null,
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
    _exitSelectionMode();
  }

  Future<void> _importFilesFromDevice() async {
    final currentDir = _pathStack.last.fatPath;
    setState(() => _isLoading = true);
    try {
      final count = await vaultExplorerApi.importFiles(
          widget.container, currentDir);
      if (count > 0) _loadDirectoryContents(currentDir);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(count > 0
                ? 'Imported $count file${count != 1 ? 's' : ''}'
                : 'No files imported')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _importFolderFromDevice() async {
    final currentDir = _pathStack.last.fatPath;
    setState(() => _isLoading = true);
    try {
      final count = await vaultExplorerApi.importFolder(
          widget.container, currentDir);
      if (count > 0) _loadDirectoryContents(currentDir);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(count > 0
                ? 'Imported $count file${count != 1 ? 's' : ''}'
                : 'No files imported')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Folder import failed: $e'),
            backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Batch-deletes all selected items; reports aggregated failures (fix #9).
  Future<void> _batchDelete() async {
    final currentDir = _pathStack.last.fatPath;
    final toDelete = List<String>.from(_selectedItems);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${toDelete.length} item(s)?',
            style: const TextStyle(fontSize: 16)),
        content: const Text(
            'These items will be permanently erased from your encrypted volume.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              setState(() => _isLoading = true);
              int failCount = 0;
              try {
                for (final item in toDelete) {
                  final isDir = item.startsWith('[DIR] ');
                  final name = isDir
                      ? item.replaceFirst('[DIR] ', '')
                      : item.split('|').first;
                  final full = currentDir.isEmpty
                      ? name
                      : '$currentDir/$name';
                  final ok = await vaultExplorerApi.deleteFile(
                      widget.container, full);
                  if (!ok) failCount++;
                }
              } finally {
                _exitSelectionMode();
                _loadDirectoryContents(currentDir);
                if (mounted) {
                  final total = toDelete.length;
                  final successCount = total - failCount;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(failCount == 0
                          ? 'Deleted $successCount item(s)'
                          : 'Deleted $successCount of $total — $failCount failed'),
                      backgroundColor: failCount == 0
                          ? const Color(0xFF1A3A2A)
                          : Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('Delete',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Sorting
  // ---------------------------------------------------------------------------

  void _setSort(_SortBy by) {
    setState(() {
      if (_sortBy == by) {
        _sortAscending = !_sortAscending;
      } else {
        _sortBy = by;
        _sortAscending = true;
      }
    });
  }

  int _compareItems(String a, String b) {
    String nameOf(String raw) => raw.startsWith('[DIR] ')
        ? raw.replaceFirst('[DIR] ', '')
        : raw.split('|').first;
    int sizeOf(String raw) {
      if (raw.startsWith('[DIR] ')) return 0;
      final p = raw.split('|');
      return p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0;
    }

    final aName = nameOf(a), bName = nameOf(b);
    int result;
    switch (_sortBy) {
      case _SortBy.name:
        result =
            aName.toLowerCase().compareTo(bName.toLowerCase());
        break;
      case _SortBy.size:
        result = sizeOf(a).compareTo(sizeOf(b));
        break;
      case _SortBy.extension:
        String extOf(String n) =>
            n.contains('.') ? n.split('.').last.toLowerCase() : '';
        result = extOf(aName).compareTo(extOf(bName));
        if (result == 0)
          result =
              aName.toLowerCase().compareTo(bName.toLowerCase());
        break;
    }
    return _sortAscending ? result : -result;
  }

  PopupMenuItem<_SortBy> _sortMenuItem(
      _SortBy value, String label) {
    final cs = Theme.of(context).colorScheme;
    final isActive = _sortBy == value;
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(
            isActive
                ? (_sortAscending
                    ? Icons.arrow_upward
                    : Icons.arrow_downward)
                : Icons.sort,
            size: 16,
            color: isActive ? cs.primary : null,
          ),
          const SizedBox(width: 10),
          Text(label,
              style: TextStyle(
                  fontWeight: isActive
                      ? FontWeight.w700
                      : FontWeight.normal)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // AppBars
  // ---------------------------------------------------------------------------

  AppBar _buildSelectionAppBar(ColorScheme cs) {
    final single = _selectedItems.length == 1;
    final singleFile =
        single && !_selectedItems.first.startsWith('[DIR] ');

    return AppBar(
      backgroundColor: cs.surface,
      foregroundColor: cs.onSurface,
      elevation: 0,
      shape: Border(
          bottom:
              BorderSide(color: cs.primary.withOpacity(0.4))),
      leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _exitSelectionMode),
      titleSpacing: 0,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('${_selectedItems.length}',
                style: TextStyle(
                    color: cs.primary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          const Text('selected',
              style: TextStyle(fontSize: 13)),
          const Spacer(),
          TextButton(
            onPressed: () =>
                setState(() => _selectedItems.addAll(_currentItems)),
            child: const Text('All',
                style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
      actions: [
        if (single)
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Rename',
            onPressed: () {
              final raw = _selectedItems.first;
              final isDir = raw.startsWith('[DIR] ');
              final name = isDir
                  ? raw.replaceFirst('[DIR] ', '')
                  : raw.split('|').first;
              _showRenameDialog(name);
              _exitSelectionMode();
            },
          ),
        IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Copy',
            onPressed: () => _initClipboard(cut: false)),
        IconButton(
            icon: const Icon(Icons.cut_outlined),
            tooltip: 'Cut',
            onPressed: () => _initClipboard(cut: true)),
        IconButton(
            icon: const Icon(
                Icons.drive_folder_upload_outlined),
            tooltip: 'Export',
            onPressed: _exportSelectedToStorage),
        IconButton(
            icon: Icon(Icons.delete_outline, color: cs.error),
            tooltip: 'Delete',
            onPressed: _batchDelete),
        if (singleFile)
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: 'Open with App',
            onPressed: () {
              final raw = _selectedItems.first;
              final name = raw.split('|').first;
              final path = _pathStack.last.fatPath.isEmpty
                  ? name
                  : '${_pathStack.last.fatPath}/$name';
              vaultExplorerApi.openWithApp(
                  widget.container, path);
              _exitSelectionMode();
            },
          ),
        const SizedBox(width: 4),
      ],
    );
  }

  AppBar _buildClipboardAppBar(ColorScheme cs) => AppBar(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        elevation: 0,
        shape: Border(
            bottom:
                BorderSide(color: cs.primary.withOpacity(0.4))),
        leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Cancel',
            onPressed: _cancelClipboard),
        title: Row(
          children: [
            Icon(
                _isCutOperation ? Icons.cut : Icons.copy,
                size: 16,
                color: cs.primary),
            const SizedBox(width: 8),
            Text(
              _isCutOperation
                  ? 'Moving ${_clipboardSourceItems.length} item(s)'
                  : 'Copying ${_clipboardSourceItems.length} item(s)',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            style: TextButton.styleFrom(
                foregroundColor: cs.primary),
            onPressed: _pasteClipboard,
            icon: const Icon(Icons.paste, size: 16),
            label: const Text('Paste Here',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 12),
        ],
      );

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dirs = _currentItems
        .where((f) => f.startsWith('[DIR]'))
        .toList()
      ..sort(_compareItems);
    final files = _currentItems
        .where((f) =>
            !f.startsWith('[DIR]') && !f.startsWith('System:'))
        .toList()
      ..sort(_compareItems);

    final PreferredSizeWidget activeAppBar =
        _isSelectionMode
            ? _buildSelectionAppBar(cs)
            : _isClipboardMode
                ? _buildClipboardAppBar(cs)
                : AppBar(
                    leading: _atRoot
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.arrow_back),
                            onPressed: _navigateUp,
                          ),
                    title: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(widget.container.displayName,
                            style: const TextStyle(
                                fontSize: 14)),
                        if (!_atRoot)
                          Text(
                            _pathStack
                                .skip(1)
                                .map((s) => s.label)
                                .join(' / '),
                            style: TextStyle(
                                fontSize: 11,
                                color: cs.primary,
                                height: 1.3),
                          ),
                      ],
                    ),
                    actions: [
                      PopupMenuButton<_SortBy>(
                        icon: const Icon(Icons.sort),
                        tooltip: 'Sort by',
                        onSelected: _setSort,
                        itemBuilder: (_) => [
                          _sortMenuItem(
                              _SortBy.name, 'Name'),
                          _sortMenuItem(
                              _SortBy.size, 'Size'),
                          _sortMenuItem(
                              _SortBy.extension, 'Type'),
                        ],
                      ),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.add),
                        onSelected: (v) {
                          if (v == 'folder')
                            _showCreateFolderDialog();
                          else if (v == 'file')
                            _showCreateFileDialog();
                          else if (v == 'import')
                            _importFilesFromDevice();
                          else if (v == 'import_folder')
                            _importFolderFromDevice();
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'folder',
                              child: ListTile(
                                  leading: Icon(
                                      Icons
                                          .create_new_folder),
                                  title:
                                      Text('New Folder'))),
                          PopupMenuItem(
                              value: 'file',
                              child: ListTile(
                                  leading: Icon(Icons
                                      .insert_drive_file),
                                  title: Text('New File'))),
                          PopupMenuItem(
                              value: 'import',
                              child: ListTile(
                                  leading: Icon(Icons
                                      .drive_folder_upload),
                                  title: Text(
                                      'Import Files from Device'))),
                          PopupMenuItem(
                              value: 'import_folder',
                              child: ListTile(
                                  leading: Icon(Icons
                                      .create_new_folder_outlined),
                                  title: Text(
                                      'Import Folder from Device'))),
                        ],
                      ),
                    ],
                  );

    return Scaffold(
      appBar: activeAppBar,
      body: Column(
        children: [
          if (_pathStack.length > 1)
            BreadcrumbBar(
                stack: _pathStack, onTap: _jumpTo),
          _StatsBar(
              dirCount: dirs.length,
              fileCount: files.length,
              freeSpaceBytes: _freeSpace),
          const Divider(),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                        strokeWidth: 2))
                : _currentItems.isEmpty
                    ? _EmptyPlaceholder(
                        onBack: _navigateUp,
                        atRoot: _atRoot)
                    : ListView.builder(
                        itemCount:
                            dirs.length + files.length,
                        itemBuilder: (_, index) {
                          final isDir =
                              index < dirs.length;
                          final rawItem = isDir
                              ? dirs[index]
                              : files[
                                  index - dirs.length];
                          String cleanName;
                          int fileSize = 0;
                          if (isDir) {
                            cleanName = rawItem
                                .replaceFirst('[DIR] ', '');
                          } else {
                            final p = rawItem.split('|');
                            cleanName = p.first;
                            fileSize = p.length > 1
                                ? int.tryParse(p[1]) ?? 0
                                : 0;
                          }
                          final isSelected = _selectedItems
                              .contains(rawItem);

                          void handleTap() {
                            if (_isSelectionMode) {
                              _toggleSelectItem(rawItem);
                              return;
                            }
                            if (isDir) {
                              _enterDirectory(rawItem);
                              return;
                            }
                            final dir =
                                _pathStack.last.fatPath;
                            final fullPath = dir.isEmpty
                                ? cleanName
                                : '$dir/$cleanName';
                            if (_isSupportedMedia(
                                cleanName)) {
                              final mediaList = files
                                  .map((f) =>
                                      f.split('|').first)
                                  .where(_isSupportedMedia)
                                  .toList();
                              final resolved = mediaList
                                  .map((f) => dir.isEmpty
                                      ? f
                                      : '$dir/$f')
                                  .toList();
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      MediaViewerScreen(
                                    container:
                                        widget.container,
                                    mediaFiles: resolved,
                                    initialIndex: mediaList
                                        .indexOf(cleanName),
                                  ),
                                ),
                              );
                            } else {
                              _openFileWithApp(
                                  cleanName, fullPath);
                            }
                          }

                          void handleLongPress() {
                            if (!_isSelectionMode) {
                              setState(() {
                                _isSelectionMode = true;
                                _selectedItems.add(rawItem);
                              });
                            } else {
                              _toggleSelectItem(rawItem);
                            }
                          }

                          return isDir
                              ? DirectoryTile(
                                  key: ValueKey(rawItem),
                                  name: cleanName,
                                  selectionMode:
                                      _isSelectionMode,
                                  selected: isSelected,
                                  onTap: handleTap,
                                  onLongPress:
                                      handleLongPress,
                                )
                              : FileTile(
                                  key: ValueKey(rawItem),
                                  name: cleanName,
                                  subtitle: formatBytes(
                                      fileSize),
                                  selectionMode:
                                      _isSelectionMode,
                                  selected: isSelected,
                                  onTap: handleTap,
                                  onLongPress:
                                      handleLongPress,
                                );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// ── Stats bar ─────────────────────────────────────────────────────────────────

class _StatsBar extends StatelessWidget {
  final int dirCount;
  final int fileCount;
  final int freeSpaceBytes;

  const _StatsBar({
    Key? key,
    required this.dirCount,
    required this.fileCount,
    required this.freeSpaceBytes,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 16, vertical: 10),
      color: cs.surface,
      child: Row(
        children: [
          _Chip(
              icon: Icons.folder_outlined,
              label:
                  '$dirCount folder${dirCount != 1 ? 's' : ''}'),
          const SizedBox(width: 14),
          _Chip(
              icon: Icons.insert_drive_file_outlined,
              label:
                  '$fileCount file${fileCount != 1 ? 's' : ''}'),
          const Spacer(),
          _Chip(
              icon: Icons.storage_outlined,
              label: '${formatBytes(freeSpaceBytes)} free'),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Chip(
      {Key? key, required this.icon, required this.label})
      : super(key: key);
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

// ── Empty placeholder ─────────────────────────────────────────────────────────

class _EmptyPlaceholder extends StatelessWidget {
  final VoidCallback onBack;
  final bool atRoot;
  const _EmptyPlaceholder(
      {Key? key, required this.onBack, required this.atRoot})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.folder_open, size: 40, color: cs.outline),
        const SizedBox(height: 12),
        Text('Empty Folder',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        const Text('Tap + to create files or folders.',
            style: TextStyle(color: Colors.grey, fontSize: 11)),
        if (!atRoot) ...[
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('Go back'),
          ),
        ],
      ]),
    );
  }
}