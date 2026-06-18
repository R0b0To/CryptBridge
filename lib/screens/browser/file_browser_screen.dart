import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/mounted_container.dart';
import '../../services/cryptbridge_api.dart';
import 'widgets/breadcrumb_bar.dart';
import 'widgets/directory_tile.dart';
import 'widgets/file_actions_sheet.dart';
import 'widgets/file_tile.dart';

/// One level in the in-app navigation stack.
class PathSegment {
  final String label;

  /// FAT path relative to the container root, e.g. "Documents/Work".
  final String fatPath;
  const PathSegment(this.label, this.fatPath);
}

class FileBrowserScreen extends StatefulWidget {
  final MountedContainer container;
  const FileBrowserScreen({Key? key, required this.container})
      : super(key: key);

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  final List<PathSegment> _pathStack = [
    const PathSegment('Root', ''),
  ];

  late List<String> _currentItems;

  @override
  void initState() {
    super.initState();
    _currentItems = widget.container.rootFiles;
  }

  bool get _atRoot => _pathStack.length == 1;

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _enterDirectory(String rawDirEntry) {
    final cleanName = rawDirEntry.replaceFirst('[DIR] ', '');
    final newPath = _pathStack.last.fatPath.isEmpty
        ? cleanName
        : '${_pathStack.last.fatPath}/$cleanName';

    setState(() {
      _pathStack.add(PathSegment(cleanName, newPath));
      // TODO: replace with real async call once listDirectoryNative is wired:
      // _currentItems = await CryptBridgeApi.listDirectory(widget.container, newPath);
      _currentItems = [];
    });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Pass "$newPath" to f_opendir to list this directory'),
      duration: const Duration(seconds: 3),
    ));
  }

  void _navigateUp() {
    if (_atRoot) return;
    setState(() {
      _pathStack.removeLast();
      _currentItems =
          _atRoot ? widget.container.rootFiles : [];
    });
  }

  void _jumpTo(int index) {
    if (index == _pathStack.length - 1) return;
    setState(() {
      _pathStack.removeRange(index + 1, _pathStack.length);
      _currentItems =
          index == 0 ? widget.container.rootFiles : [];
    });
  }

  // ---------------------------------------------------------------------------
  // File export
  // ---------------------------------------------------------------------------

  Future<void> _exportFile(String fileName) async {
    final downloads = Directory('/storage/emulated/0/Download');
    if (!await downloads.exists()) await downloads.create(recursive: true);

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text('Exporting $fileName…')),
    );

    try {
      final success = await CryptBridgeApi.decryptFile(
        widget.container,
        fileName,
        '${downloads.path}/$fileName',
      );
      messenger.showSnackBar(SnackBar(
        content: Text(
            success ? 'Saved to Downloads/$fileName' : 'Export failed'),
        backgroundColor: success ? const Color(0xFF1A3A2A) : null,
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  void _showFileActions(String fileName) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (_) => FileActionsSheet(
        fileName: fileName,
        onExport: () {
          Navigator.pop(context);
          _exportFile(fileName);
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dirs =
        _currentItems.where((f) => f.startsWith('[DIR]')).toList();
    final files = _currentItems
        .where((f) => !f.startsWith('[DIR]') && !f.startsWith('System:'))
        .toList();

    return Scaffold(
      appBar: AppBar(
        leading: _atRoot
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _navigateUp,
              ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.container.displayName,
                style: const TextStyle(fontSize: 14)),
            if (!_atRoot)
              Text(
                _pathStack.skip(1).map((s) => s.label).join(' / '),
                style:
                    TextStyle(fontSize: 11, color: cs.primary, height: 1.3),
              ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'VOL ${widget.container.volId}',
                style: TextStyle(
                  color: cs.primary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_pathStack.length > 1)
            BreadcrumbBar(stack: _pathStack, onTap: _jumpTo),
          _StatsBar(dirCount: dirs.length, fileCount: files.length),
          const Divider(),
          Expanded(
            child: _currentItems.isEmpty && !_atRoot
                ? _DirectoryPlaceholder(onBack: _navigateUp)
                : ListView.builder(
                    itemCount: dirs.length + files.length,
                    itemBuilder: (_, index) {
                      if (index < dirs.length) {
                        return DirectoryTile(
                          name: dirs[index].replaceFirst('[DIR] ', ''),
                          onTap: () => _enterDirectory(dirs[index]),
                        );
                      }
                      final file = files[index - dirs.length];
                      return FileTile(
                        name: file,
                        onTap: () => _showFileActions(file),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Small private widgets used only in this screen ───────────────────────────

class _StatsBar extends StatelessWidget {
  final int dirCount;
  final int fileCount;
  const _StatsBar({required this.dirCount, required this.fileCount});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: cs.surface,
      child: Row(
        children: [
          _Chip(
              icon: Icons.folder_outlined,
              label: '$dirCount folder${dirCount != 1 ? 's' : ''}'),
          const SizedBox(width: 14),
          _Chip(
              icon: Icons.insert_drive_file_outlined,
              label: '$fileCount file${fileCount != 1 ? 's' : ''}'),
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: cs.outline),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _DirectoryPlaceholder extends StatelessWidget {
  final VoidCallback onBack;
  const _DirectoryPlaceholder({required this.onBack});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_open, size: 40, color: cs.outline),
          const SizedBox(height: 12),
          Text('Subdirectory browsing',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Wire listDirectory() in the native layer to pass '
              'the path to f_opendir. See the inline TODO.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('Go back'),
          ),
        ],
      ),
    );
  }
}
