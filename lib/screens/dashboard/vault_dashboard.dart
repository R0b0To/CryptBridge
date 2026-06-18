import 'package:flutter/material.dart';

import '../../models/mounted_container.dart';
import '../unlock/unlock_sheet.dart';
import 'widgets/container_card.dart';
import 'widgets/empty_state.dart';

class VaultDashboard extends StatefulWidget {
  const VaultDashboard({Key? key}) : super(key: key);

  @override
  State<VaultDashboard> createState() => _VaultDashboardState();
}

class _VaultDashboardState extends State<VaultDashboard> {
  final List<MountedContainer> _containers = [];

  void _onContainerMounted(MountedContainer container) {
    setState(() => _containers.add(container));
  }

  void _onContainerLocked(int volId) {
    setState(() => _containers.removeWhere((c) => c.volId == volId));
  }

  void _showUnlockSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => UnlockSheet(onMounted: _onContainerMounted),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final atLimit = _containers.length >= 4;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.lock_outline, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            const Text('CryptBridge'),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: atLimit
                ? Tooltip(
                    message: 'Maximum 4 containers',
                    child: Icon(Icons.add, color: cs.outline),
                  )
                : IconButton(
                    onPressed: _showUnlockSheet,
                    icon: const Icon(Icons.add),
                    tooltip: 'Mount container',
                  ),
          ),
        ],
      ),
      body: _containers.isEmpty
          ? EmptyState(onAdd: _showUnlockSheet)
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _containers.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => ContainerCard(
                container: _containers[i],
                onLocked: _onContainerLocked,
              ),
            ),
    );
  }
}
