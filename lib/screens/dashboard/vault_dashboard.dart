import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/mounted_container.dart';
import '../../services/app_settings_service.dart';
import '../../services/cross_container_clipboard.dart';
import '../../services/saved_containers.dart';
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
  List<Map<String, String>> _saved      = [];
  Map<String, ContainerConfig> _configs  = {};
  AppSettings _appSettings               = AppSettings();
  bool _actionInFlight                   = false;

  final Map<int, Timer> _autoCloseTimers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSaved();
    _loadConfigs();
    _loadAppSettings();
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

  Future<void> _loadSaved() async {
    final saved = await SavedContainerService.loadContainers();
    if (mounted) setState(() => _saved = saved);
  }

  Future<void> _loadConfigs() async {
    final configs = await AppSettingsService.loadContainerConfigs();
    if (mounted) setState(() => _configs = configs);
  }

  Future<void> _loadAppSettings() async {
    final s = await AppSettingsService.loadSettings();
    if (mounted) setState(() => _appSettings = s);
  }

  // ── Auto-close ──────────────────────────────────────────────────────────

  void _scheduleAutoClose(MountedContainer container) {
    final cfg  = _configs[container.uri];
    final mins = cfg?.autoCloseMins ?? 0;
    if (mins <= 0) return;
    _autoCloseTimers[container.volId]?.cancel();
    _autoCloseTimers[container.volId] = Timer(Duration(minutes: mins), () async {
      if (!mounted) return;

      // FIX (Issue #5): don't lock while a multi-step operation (paste,
      // import) is in flight.  Re-schedule and check again after a short
      // delay so the timer still fires once the operation completes.
      if (vaultExplorerApi.hasActiveBatch(container.volId)) {
        _scheduleAutoClose(container);
        return;
      }

      await vaultExplorerApi.lockContainer(container.uri);
      _onContainerLocked(container.volId);
    });
  }

  void _cancelAutoClose(int volId) {
    _autoCloseTimers[volId]?.cancel();
    _autoCloseTimers.remove(volId);
  }

  // ── Container lifecycle ─────────────────────────────────────────────────

  void _onContainerMounted(MountedContainer container) {
    setState(() => _mounted.add(container));
    _scheduleAutoClose(container);
    if (!_configs.containsKey(container.uri)) {
      final defaultCfg = ContainerConfig(
        uri: container.uri,
        label: container.displayName,
        documentProvider: _appSettings.defaultDocumentProvider,
      );
      _configs[container.uri] = defaultCfg;
      AppSettingsService.saveContainerConfig(defaultCfg);
    }
  }

  void _onContainerLocked(int volId) {
    _cancelAutoClose(volId);
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

  // ── Unlock ──────────────────────────────────────────────────────────────

  Future<void> _showUnlockSheet({String? uri, String? name}) async {
    if (_actionInFlight) return;
    setState(() => _actionInFlight = true);

    String? rememberedPassword;
    if (uri != null) {
      final cfg = _configs[uri];
      // FIX: removed the now-deleted synchronous `hasPassword` getter;
      // simply try getPassword() — it returns null if nothing is stored.
      if (cfg?.rememberPassword == true) {
        rememberedPassword = await cfg!.getPassword();
      }
    }

    final cfg         = uri != null ? _configs[uri] : null;
    final docProvider = cfg?.documentProvider ?? _appSettings.defaultDocumentProvider;

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
      _loadSaved();
    } finally {
      setState(() => _actionInFlight = false);
    }
  }

  void _showCreateSheet() {
    if (_actionInFlight) return;
    setState(() => _actionInFlight = true);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const CreateContainerSheet(),
    ).whenComplete(() => setState(() => _actionInFlight = false));
  }

  void _showContainerConfig({required String uri, required String currentLabel}) {
    HapticFeedback.mediumImpact();
    final existing = _configs[uri];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => ContainerConfigSheet(
        uri: uri,
        currentLabel: currentLabel,
        existingConfig: existing,
        onSaved: (cfg) {
          setState(() => _configs[uri] = cfg);
          SavedContainerService.saveContainer(uri, cfg.label);
          _loadSaved();
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
    await SavedContainerService.removeContainer(uri);
    await AppSettingsService.removeContainerConfig(uri);
    setState(() => _configs.remove(uri));
    _loadSaved();
  }

  @override
  Widget build(BuildContext context) {
    final cs        = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final clipboard = CrossContainerClipboard.instance;

    final displayItems = <dynamic>[];
    displayItems.addAll(_mounted);
    for (final s in _saved) {
      if (!_mounted.any((m) => m.uri == s['uri'])) displayItems.add(s);
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
              _loadAppSettings();
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
                      final uri   = item['uri'] as String;
                      final name  = item['name'] as String;
                      final cfg   = _configs[uri];
                      final label = cfg?.label.isNotEmpty == true ? cfg!.label : name;
                      return SavedContainerCard(
                        name: label,
                        uri: uri,
                        onUnlock: () => _showUnlockSheet(uri: uri, name: name),
                        onLongPress: () =>
                            _showContainerConfig(uri: uri, currentLabel: label),
                        onForget: () => _forgetContainer(uri, label),
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
                      color: cs.onPrimaryContainer, fontWeight: FontWeight.w600)),
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