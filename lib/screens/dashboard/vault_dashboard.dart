import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/mounted_container.dart';
import '../../services/app_settings_service.dart';
import '../../services/container_repository.dart';
import '../../services/cross_container_clipboard.dart';
import '../../services/vaultexplorer_api.dart';
import '../settings/app_settings_screen.dart';
import '../unlock/unlock_sheet.dart';
import 'widgets/container_card.dart';
import 'widgets/container_config_sheet.dart';
import 'widgets/create_container_sheet.dart';
import 'widgets/empty_state.dart';

class VaultDashboard extends StatefulWidget {
  const VaultDashboard({Key? key}) : super(key: key);

  @override
  State<VaultDashboard> createState() => _VaultDashboardState();
}

class _VaultDashboardState extends State<VaultDashboard>
    with WidgetsBindingObserver {
  final List<MountedContainer> _mounted = [];
  Map<String, ContainerRecord> _records  = {};
  AppSettings _appSettings               = AppSettings();
  bool _actionInFlight                   = false;

  final Map<int, Timer> _autoCloseTimers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final t in _autoCloseTimers.values) t.cancel();
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

  Future<void> _loadAll() async {
    final settings = await AppSettingsService.loadSettings();
    final records  = await ContainerRepository.instance.loadAll();
    if (mounted) {
      setState(() {
        _appSettings = settings;
        _records     = Map.from(records);
      });
    }
  }

  // ── Auto-close ────────────────────────────────────────────────────────────

  void _scheduleAutoClose(MountedContainer container) {
    final record = _records[container.uri];
    final mins   = record?.autoCloseMins ?? 0;
    if (mins <= 0) return;

    _autoCloseTimers[container.volId]?.cancel();
    _autoCloseTimers[container.volId] = Timer(Duration(minutes: mins), () async {
      if (!mounted) return;

      // BUG-03 fix: acquireLockGuard is an atomic check-and-set in the Dart
      // event loop. If a batch begins between the check and the lock call in
      // the old code, the guard would have caught it.
      if (!vaultExplorerApi.acquireLockGuard(container.volId)) {
        // A batch is active or another lock is pending — retry after the
        // minimum auto-close interval to honour the intent without spinning.
        _scheduleAutoClose(container);
        return;
      }

      try {
        await vaultExplorerApi.lockContainer(container.uri);
        _onContainerLocked(container.volId);
      } finally {
        vaultExplorerApi.releaseLockGuard(container.volId);
      }
    });
  }

  void _cancelAutoClose(int volId) {
    _autoCloseTimers[volId]?.cancel();
    _autoCloseTimers.remove(volId);
  }

  // ── Container lifecycle ───────────────────────────────────────────────────

  void _onContainerMounted(MountedContainer container) {
    setState(() => _mounted.add(container));
    _scheduleAutoClose(container);

    if (!_records.containsKey(container.uri)) {
      final record = ContainerRecord(
        uri: container.uri,
        label: container.displayName,
        documentProvider: _appSettings.defaultDocumentProvider,
      );
      _records[container.uri] = record;
      ContainerRepository.instance.save(record);
    }
  }

  void _onContainerLocked(int volId) {
    _cancelAutoClose(volId);

    // SEC-05 fix: clear clipboard when the source container is locked so
    // stale paths from a now-locked container cannot be pasted.
    final clip = CrossContainerClipboard.instance;
    final locked = _mounted.firstWhere(
      (c) => c.volId == volId,
      orElse: () => _mounted.first, // fallback; checked below
    );
    if (clip.hasItems && clip.sourceContainer?.volId == volId) {
      clip.clear();
    }

    setState(() => _mounted.removeWhere((c) => c.volId == volId));
  }

  Future<void> _refreshContainerSpace(int volId) async {
    final idx = _mounted.indexWhere((c) => c.volId == volId);
    if (idx == -1) return;
    final container = _mounted[idx];
    try {
      final space = await vaultExplorerApi.getSpaceInfo(container);
      if (space != null && space.length > 1 && mounted) {
        setState(() {
          _mounted[idx] =
              container.copyWith(totalSpace: space[0], freeSpace: space[1]);
        });
      }
    } catch (_) {}
  }

  // ── Unlock ────────────────────────────────────────────────────────────────

  Future<void> _showUnlockSheet({String? uri, String? name}) async {
    if (_actionInFlight) return;
    setState(() => _actionInFlight = true);

    String? rememberedPassword;
    if (uri != null) {
      final record = _records[uri];
      if (record?.rememberPassword == true) {
        rememberedPassword =
            await ContainerRepository.instance.getPassword(uri);
      }
    }

    final record      = uri != null ? _records[uri] : null;
    final docProvider = record?.documentProvider ??
        _appSettings.defaultDocumentProvider;

    try {
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => UnlockSheet(
          onMounted: _onContainerMounted,
          initialUri: uri,
          initialName: name,
          prefillPassword: rememberedPassword,
          documentProvider: docProvider,
        ),
      );
      await _loadAll();
    } finally {
      if (mounted) setState(() => _actionInFlight = false);
    }
  }

  void _showCreateSheet() {
    if (_actionInFlight) return;
    setState(() => _actionInFlight = true);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const CreateContainerSheet(),
    ).whenComplete(() {
      if (mounted) setState(() => _actionInFlight = false);
    });
  }

  void _showContainerConfig({required String uri, required String currentLabel}) {
    HapticFeedback.mediumImpact();
    final existing = _records[uri];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => ContainerConfigSheet(
        uri: uri,
        currentLabel: currentLabel,
        existingRecord: existing,
        onSaved: (record) async {
          setState(() => _records[uri] = record);
          final idx = _mounted.indexWhere((m) => m.uri == uri);
          if (idx != -1) _scheduleAutoClose(_mounted[idx]);
        },
        onForget: _mounted.any((m) => m.uri == uri)
            ? null
            : () => _forgetContainer(uri, currentLabel),
      ),
    );
  }

  Future<void> _forgetContainer(String uri, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove container?'),
        content: Text('Remove "$name" from the dashboard? '
            'The container file is not deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Remove',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // ARCH-04 fix: single call handles JSON, config, and Keystore atomically.
    await ContainerRepository.instance.remove(uri);
    setState(() => _records.remove(uri));
  }

  @override
  Widget build(BuildContext context) {
    final cs        = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final clipboard = CrossContainerClipboard.instance;

    // Build display list: mounted containers first, then saved-but-locked.
    final displayItems = <dynamic>[];
    displayItems.addAll(_mounted);
    for (final entry in _records.entries) {
      if (!_mounted.any((m) => m.uri == entry.key)) {
        displayItems.add(entry.value);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock_outline, size: 20, color: cs.primary),
          const SizedBox(width: 8),
          Text('vaultexplorer',
              style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600, letterSpacing: -0.1)),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'App Settings',
            onPressed: () async {
              await Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const AppSettingsScreen()));
              _loadAll();
            },
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'mount') _showUnlockSheet();
                if (value == 'create') _showCreateSheet();
              },
              icon: const Icon(Icons.add),
              tooltip: 'Container options',
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'mount',
                  child: Row(children: [
                    Icon(Icons.lock_open, size: 18, color: cs.primary),
                    const SizedBox(width: 12),
                    const Text('Mount container'),
                  ]),
                ),
                PopupMenuItem(
                  value: 'create',
                  child: Row(children: [
                    Icon(Icons.add_box_outlined, size: 18, color: cs.primary),
                    const SizedBox(width: 12),
                    const Text('Create container'),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(children: [
        if (clipboard.hasItems)
          _ClipboardStatusStrip(
            clipboard: clipboard,
            onClear: () => setState(() => clipboard.clear()),
          ),
        Expanded(
          child: displayItems.isEmpty
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
                        onLongPress: () => _showContainerConfig(
                          uri: item.uri,
                          currentLabel: item.displayName,
                        ),
                      );
                    } else {
                      final record = item as ContainerRecord;
                      return SavedContainerCard(
                        name: record.label.isNotEmpty
                            ? record.label
                            : record.uri.split('/').last,
                        uri: record.uri,
                        onUnlock: () => _showUnlockSheet(
                            uri: record.uri, name: record.label),
                        onLongPress: () => _showContainerConfig(
                            uri: record.uri, currentLabel: record.label),
                        onForget: () =>
                            _forgetContainer(record.uri, record.label),
                      );
                    }
                  },
                ),
        ),
      ]),
    );
  }
}

// ── Clipboard status strip ────────────────────────────────────────────────────

class _ClipboardStatusStrip extends StatelessWidget {
  final CrossContainerClipboard clipboard;
  final VoidCallback onClear;
  const _ClipboardStatusStrip({required this.clipboard, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final cs        = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      color: cs.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        Icon(clipboard.isCutOperation ? Icons.cut : Icons.copy,
            size: 18, color: cs.onPrimaryContainer),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(clipboard.summary,
                  style: textTheme.labelLarge?.copyWith(
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text('Open a container and tap "Paste Here"',
                  style: textTheme.bodySmall?.copyWith(
                      color: cs.onPrimaryContainer.withOpacity(0.8))),
            ],
          ),
        ),
        TextButton(
          onPressed: onClear,
          style: TextButton.styleFrom(
            foregroundColor: cs.onPrimaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Cancel'),
        ),
      ]),
    );
  }
}