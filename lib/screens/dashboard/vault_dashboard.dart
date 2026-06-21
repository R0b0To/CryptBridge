import 'package:flutter/material.dart';

import '../../models/mounted_container.dart';
import '../../services/saved_containers.dart';
import '../unlock/unlock_sheet.dart';
import 'widgets/container_card.dart';
import 'widgets/empty_state.dart';
import 'widgets/create_container_sheet.dart';
import '../../../services/vaultexplorer_api.dart';

class VaultDashboard extends StatefulWidget {
  const VaultDashboard({Key? key}) : super(key: key);

  @override
  State<VaultDashboard> createState() => _VaultDashboardState();
}

class _VaultDashboardState extends State<VaultDashboard> with WidgetsBindingObserver {
  final List<MountedContainer> _mounted = [];
  List<Map<String, String>> _saved = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSaved();
  }
   @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      for (final c in List<MountedContainer>.from(_mounted)) {
        _refreshContainerSpace(c.volId);
      }
    }
  }


  Future<void> _loadSaved() async {
    final saved = await SavedContainerService.loadContainers();
    if (mounted) setState(() => _saved = saved);
  }

  void _onContainerMounted(MountedContainer container) {
    setState(() => _mounted.add(container));
  }

  void _onContainerLocked(int volId) {
    setState(() => _mounted.removeWhere((c) => c.volId == volId));
  }
  Future<void> _refreshContainerSpace(int volId) async {
    final idx = _mounted.indexWhere((c) => c.volId == volId);
    if (idx == -1) return;
    final container = _mounted[idx];
    try {
      final space = await vaultexplorerApi.getSpaceInfo(container);
      if (space != null && space.length > 1 && mounted) {
        setState(() {
          _mounted[idx] = container.copyWith(totalSpace: space[0], freeSpace: space[1]);
        });
      }
    } catch (_) {}
  }
  Future<void> _showUnlockSheet({String? uri, String? name}) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => UnlockSheet(
        onMounted: _onContainerMounted,
        initialUri: uri,
        initialName: name,
      ),
    );
    _loadSaved();
  }

  void _showCreateSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const CreateContainerSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final displayItems = <dynamic>[];
    displayItems.addAll(_mounted);
    for (final s in _saved) {
      if (!_mounted.any((m) => m.uri == s['uri'])) {
        displayItems.add(s);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.lock_outline, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            const Text('vaultexplorer'),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'mount') {
                  _showUnlockSheet();
                } else if (value == 'create') {
                  _showCreateSheet();
                }
              },
              icon: const Icon(Icons.add),
              tooltip: 'Container options',
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'mount',
                  child: Row(
                    children: [
                      Icon(Icons.lock_open, size: 18, color: cs.primary),
                      const SizedBox(width: 12),
                      const Text('Mount container'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'create',
                  child: Row(
                    children: [
                      Icon(Icons.add_box_outlined, size: 18, color: cs.primary),
                      const SizedBox(width: 12),
                      const Text('Create container'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: displayItems.isEmpty
          ? EmptyState(onAdd: () => _showUnlockSheet())
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: displayItems.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final item = displayItems[i];
                if (item is MountedContainer) {
                  return ContainerCard(
                    container: item,
                    onLocked: _onContainerLocked,
                    onReturn: () => _refreshContainerSpace(item.volId),
                  );
                } else {
                  return SavedContainerCard(
                    name: item['name'] as String,
                    uri: item['uri'] as String,
                    onUnlock: () => _showUnlockSheet(
                      uri: item['uri'] as String,
                      name: item['name'] as String,
                    ),
                    onForget: () async {
                      await SavedContainerService.removeContainer(
                          item['uri'] as String);
                      _loadSaved();
                    },
                  );
                }
              },
            ),
    );
  }
}