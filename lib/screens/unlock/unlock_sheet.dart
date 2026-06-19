import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/vaultexplorer_api.dart';
import '../../services/saved_containers.dart';
import '../../models/mounted_container.dart';

class UnlockSheet extends StatefulWidget {
  final ValueChanged<MountedContainer> onMounted;
  const UnlockSheet({Key? key, required this.onMounted}) : super(key: key);

  @override
  State<UnlockSheet> createState() => _UnlockSheetState();
}

class _UnlockSheetState extends State<UnlockSheet> {
  final _passwordCtrl = TextEditingController();
  final _pimCtrl = TextEditingController();
  String? _selectedUri;
  String? _selectedName;
  bool _obscure = true;
  bool _loading = false;
  String? _error;
  List<Map<String, String>> _recentContainers = [];

  @override
  void initState() {
    super.initState();
    _loadRecents();
  }

  Future<void> _loadRecents() async {
    final list = await SavedContainerService.loadContainers();
    if (mounted) setState(() => _recentContainers = list);
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _pimCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final result = await vaultexplorerApi.pickContainer();
      if (result != null) {
        setState(() {
          _selectedUri = result.uri;
          _selectedName = result.displayName;
          _error = null;
        });
      }
    } catch (e) {
      setState(() => _error = 'File picker failed: $e');
    }
  }

  Future<void> _unlock() async {
    if (_selectedUri == null) {
      setState(() => _error = 'Select a container first');
      return;
    }
    if (_passwordCtrl.text.isEmpty) {
      setState(() => _error = 'Password is required');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final pim =
          _pimCtrl.text.isEmpty ? 0 : int.tryParse(_pimCtrl.text) ?? 0;
      final name = _selectedName ?? 'Container';

      final result = await vaultexplorerApi.unlockContainer(
        _selectedUri!,
        _passwordCtrl.text,
        pim,
        displayName: name,
      );

      if (result != null) {
        await SavedContainerService.saveContainer(_selectedUri!, name);

        final tempContainer = MountedContainer(
          uri: _selectedUri!,
          displayName: name,
          volId: result.volId,
          password: _passwordCtrl.text,
          pim: pim,
          rootFiles: result.files,
          mountedAt: DateTime.now(),
          totalSpace: 0,
          freeSpace: 0,
        );

        final space = await vaultexplorerApi.getSpaceInfo(tempContainer);
        final total =
            (space != null && space.isNotEmpty) ? space[0] : 0;
        final free =
            (space != null && space.length > 1) ? space[1] : 0;

        widget.onMounted(MountedContainer(
          uri: _selectedUri!,
          displayName: name,
          volId: result.volId,
          password: _passwordCtrl.text,
          pim: pim,
          rootFiles: result.files,
          mountedAt: DateTime.now(),
          totalSpace: total,
          freeSpace: free,
        ));

        if (mounted) Navigator.pop(context);
      } else {
        setState(() => _error = 'Incorrect password or invalid container');
      }
    } on PlatformException catch (e) {
      setState(() => _error = e.message ?? 'Unknown error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mq = MediaQuery.of(context);

    return Container(
      margin: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        border: Border.all(color: cs.outline.withOpacity(0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.outline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text('Mount Container',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontSize: 17)),
              const SizedBox(height: 12),

              // Saved Containers
              if (_recentContainers.isNotEmpty && _selectedUri == null) ...[
                const Text('Saved Containers:',
                    style: TextStyle(
                        color: Color(0xFF7A8899), fontSize: 11)),
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _recentContainers.length,
                    itemBuilder: (context, idx) {
                      final item = _recentContainers[idx];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.history,
                            size: 16, color: Color(0xFF4FC3F7)),
                        title: Text(item['name']!,
                            style: const TextStyle(
                                fontSize: 13, color: Colors.white)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline,
                              size: 16, color: Colors.red),
                          onPressed: () async {
                            await SavedContainerService.removeContainer(
                                item['uri']!);
                            _loadRecents();
                          },
                        ),
                        onTap: () => setState(() {
                          _selectedUri = item['uri'];
                          _selectedName = item['name'];
                        }),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // File picker row
              GestureDetector(
                onTap: _pickFile,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 14),
                  decoration: BoxDecoration(
                    color: cs.surfaceVariant,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _selectedUri != null
                          ? cs.primary.withOpacity(0.5)
                          : cs.outline,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _selectedUri != null
                            ? Icons.description_outlined
                            : Icons.folder_open,
                        size: 18,
                        color: _selectedUri != null
                            ? cs.primary
                            : cs.outline,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _selectedName ??
                              'Select VeraCrypt container…',
                          style: TextStyle(
                              color: _selectedUri != null
                                  ? cs.onSurface
                                  : cs.outline,
                              fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_selectedUri != null) ...[
                        GestureDetector(
                          onTap: () => setState(() {
                            _selectedUri = null;
                            _selectedName = null;
                          }),
                          child: const Icon(Icons.clear,
                              size: 16, color: Colors.grey),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.check_circle,
                            size: 16, color: cs.primary),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              TextField(
                controller: _passwordCtrl,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon:
                      const Icon(Icons.key_outlined, size: 18),
                  suffixIcon: IconButton(
                    onPressed: () =>
                        setState(() => _obscure = !_obscure),
                    icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 18),
                  ),
                ),
              ),
              const SizedBox(height: 10),

              TextField(
                controller: _pimCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'PIM  (leave blank for default)',
                  prefixIcon: Icon(Icons.tune, size: 18),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cs.error.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                    border:
                        Border.all(color: cs.error.withOpacity(0.4)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          size: 16, color: cs.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_error!,
                            style: TextStyle(
                                color: cs.error, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 20),
              FilledButton(
                onPressed: _loading ? null : _unlock,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                ),
                child: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(
                                Colors.white)),
                      )
                    : const Text('Unlock',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}