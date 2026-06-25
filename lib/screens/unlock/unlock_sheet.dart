import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/vaultexplorer_api.dart';
import '../../services/saved_containers.dart';
import '../../models/mounted_container.dart';
import '../../utils/validation_utils.dart';

class UnlockSheet extends StatefulWidget {
  final ValueChanged<MountedContainer> onMounted;
  final String? initialUri;
  final String? initialName;
  final String? prefillPassword;
  final bool documentProvider;

  const UnlockSheet({
    Key? key,
    required this.onMounted,
    this.initialUri,
    this.initialName,
    this.prefillPassword,
    this.documentProvider = false,
  }) : super(key: key);

  @override
  State<UnlockSheet> createState() => _UnlockSheetState();
}

class _UnlockSheetState extends State<UnlockSheet> {
  late TextEditingController _passwordCtrl;
  final _pimCtrl = TextEditingController();
  String? _selectedUri;
  String? _selectedName;
  bool _obscure = true;
  bool _loading = false;
  bool _remember = false;
  String? _error;

  bool get _passwordPrefilled =>
      widget.prefillPassword?.isNotEmpty == true &&
      _passwordCtrl.text == widget.prefillPassword;

  @override
  void initState() {
    super.initState();
    _passwordCtrl = TextEditingController(text: widget.prefillPassword ?? '');
    if (widget.initialUri != null) {
      _selectedUri = widget.initialUri;
      _selectedName = widget.initialName;
      _remember = true;
    }
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _pimCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    if (widget.initialUri != null) return;
    try {
      final result = await vaultExplorerApi.pickContainer();
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
    if (_selectedUri == null) { setState(() => _error = 'Select a container first'); return; }
    if (_passwordCtrl.text.isEmpty) { setState(() => _error = 'Password is required'); return; }
    setState(() { _loading = true; _error = null; });

    try {
      final pim = clampPim(_pimCtrl.text.isEmpty ? 0 : int.tryParse(_pimCtrl.text) ?? 0);
      final name = _selectedName ?? 'Container';

      final result = await vaultExplorerApi.unlockContainer(
        _selectedUri!,
        _passwordCtrl.text,
        pim,
        displayName: name,
        documentProvider: widget.documentProvider,
      );

      if (result != null) {
        if (_remember && widget.initialUri == null) {
          await SavedContainerService.saveContainer(_selectedUri!, name);
        }

        final tempContainer = MountedContainer(
          uri: _selectedUri!,
          displayName: name,
          volId: result.volId,
          rootFiles: result.files,
          mountedAt: DateTime.now(),
          totalSpace: 0,
          freeSpace: 0,
        );

        final space = await vaultExplorerApi.getSpaceInfo(tempContainer);
        final total = (space != null && space.isNotEmpty) ? space[0] : 0;
        final free  = (space != null && space.length > 1) ? space[1] : 0;

        widget.onMounted(MountedContainer(
          uri: _selectedUri!,
          displayName: name,
          volId: result.volId,
          rootFiles: result.files,
          mountedAt: DateTime.now(),
          totalSpace: total,
          freeSpace: free,
        ));

        HapticFeedback.lightImpact();
        if (mounted) Navigator.pop(context);
      } else {
        setState(() => _error ='Incorrect password or invalid container');
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
                  width: 36, height: 4,
                  decoration: BoxDecoration(color: cs.outline, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 20),
              Row(children: [
                Text(
                  widget.initialUri != null ? 'Unlock Container' : 'Mount Container',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 17),
                ),
              ]),
              const SizedBox(height: 12),

              // File picker
              GestureDetector(
                onTap: _pickFile,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  decoration: BoxDecoration(
                    color: cs.surfaceVariant,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _selectedUri != null ? cs.primary.withOpacity(0.5) : cs.outline,
                    ),
                  ),
                  child: Row(children: [
                    Icon(
                      _selectedUri != null ? Icons.description_outlined : Icons.folder_open,
                      size: 18,
                      color: _selectedUri != null ? cs.primary : cs.outline,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _selectedName ?? 'Select VeraCrypt container…',
                        style: TextStyle(
                          color: _selectedUri != null ? cs.onSurface : cs.outline,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_selectedUri != null && widget.initialUri == null) ...[
                      GestureDetector(
                        onTap: () => setState(() { _selectedUri = null; _selectedName = null; }),
                        child: const Icon(Icons.clear, size: 16, color: Colors.grey),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.check_circle, size: 16, color: cs.primary),
                    ] else if (_selectedUri != null && widget.initialUri != null) ...[
                      Icon(Icons.lock_outline, size: 16, color: cs.primary),
                    ],
                  ]),
                ),
              ),
              const SizedBox(height: 12),

              // Password
              TextField(
                controller: _passwordCtrl,
                obscureText: _obscure,
                autofocus: widget.initialUri != null && widget.prefillPassword?.isEmpty != false,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.key_outlined, size: 18),
                  suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (_passwordPrefilled)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Tooltip(
                          message: 'Using saved password',
                          child: Icon(Icons.bookmark, size: 16, color: cs.primary),
                        ),
                      ),
                    IconButton(
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                    ),
                  ]),
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

              if (widget.initialUri == null) ...[
                const SizedBox(height: 10),
                Row(children: [
                  Checkbox(
                    value: _remember,
                    onChanged: (val) => setState(() => _remember = val ?? false),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => setState(() => _remember = !_remember),
                    child: const Text('Remember container on dashboard',
                        style: TextStyle(fontSize: 13)),
                  ),
                ]),
              ],

              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cs.error.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: cs.error.withOpacity(0.4)),
                  ),
                  child: Row(children: [
                    Icon(Icons.error_outline, size: 16, color: cs.error),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, style: TextStyle(color: cs.error, fontSize: 12))),
                  ]),
                ),
              ],

              const SizedBox(height: 20),
              FilledButton(
                onPressed: _loading ? null : _unlock,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                child: _loading
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(Colors.white)))
                    : const Text('Unlock',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}