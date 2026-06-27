import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/vaultexplorer_api.dart';
import '../../services/container_repository.dart';
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
      _selectedUri  = widget.initialUri;
      _selectedName = widget.initialName;
      _remember     = true;
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
          _selectedUri  = result.uri;
          _selectedName = result.displayName;
          _error        = null;
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
    setState(() { _loading = true; _error = null; });

    try {
      final pim  = clampPim(
          _pimCtrl.text.isEmpty ? 0 : int.tryParse(_pimCtrl.text) ?? 0);
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
          final record = ContainerRecord(
            uri: _selectedUri!,
            label: name,
            rememberPassword: false,
          );
          await ContainerRepository.instance.save(record);
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

        TextInput.finishAutofillContext(shouldSave: false);

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
    final cs        = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final mq        = MediaQuery.of(context);

    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Text(
                  widget.initialUri != null
                      ? 'Unlock Container'
                      : 'Mount Container',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ]),
              const SizedBox(height: 16),

              // File picker
              GestureDetector(
                onTap: _pickFile,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 16),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _selectedUri != null
                          ? cs.primary
                          : cs.outlineVariant,
                      width: _selectedUri != null ? 1.5 : 1,
                    ),
                  ),
                  child: Row(children: [
                    Icon(
                      _selectedUri != null
                          ? Icons.description_outlined
                          : Icons.folder_open_rounded,
                      size: 20,
                      color: _selectedUri != null
                          ? cs.primary
                          : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _selectedName ?? 'Select VeraCrypt container…',
                        style: textTheme.bodyMedium?.copyWith(
                          color: _selectedUri != null
                              ? cs.onSurface
                              : cs.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_selectedUri != null &&
                        widget.initialUri == null) ...[
                      GestureDetector(
                        onTap: () => setState(
                            () { _selectedUri = null; _selectedName = null; }),
                        child: Icon(Icons.clear_rounded,
                            size: 18, color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.check_circle_rounded,
                          size: 18, color: cs.primary),
                    ] else if (_selectedUri != null &&
                        widget.initialUri != null) ...[
                      Icon(Icons.lock_outline_rounded,
                          size: 18, color: cs.primary),
                    ],
                  ]),
                ),
              ),
              const SizedBox(height: 16),

              TextField(
                controller: _passwordCtrl,
                obscureText: _obscure,
                autofocus: widget.initialUri != null &&
                    widget.prefillPassword?.isEmpty != false,
                onChanged: (_) => setState(() {}),
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.key_outlined, size: 18),
                  suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (_passwordPrefilled)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Tooltip(
                          message: 'Using saved password',
                          child: Icon(Icons.bookmark_rounded,
                              size: 18, color: cs.primary),
                        ),
                      ),
                    IconButton(
                      onPressed: () =>
                          setState(() => _obscure = !_obscure),
                      icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 12),

              TextField(
                controller: _pimCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'PIM  (leave blank for default)',
                  prefixIcon: Icon(Icons.tune_rounded, size: 18),
                ),
              ),

              if (widget.initialUri == null) ...[
                const SizedBox(height: 10),
                Row(children: [
                  Checkbox(
                    value: _remember,
                    onChanged: (val) =>
                        setState(() => _remember = val ?? false),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () => setState(() => _remember = !_remember),
                    child: Text(
                      'Remember container on dashboard',
                      style: textTheme.bodyMedium,
                    ),
                  ),
                ]),
              ],

              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    Icon(Icons.error_outline_rounded,
                        size: 20, color: cs.onErrorContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _error!,
                        style: textTheme.bodySmall?.copyWith(
                          color: cs.onErrorContainer,
                        ),
                      ),
                    ),
                  ]),
                ),
              ],

              const SizedBox(height: 24),
              FilledButton(
                onPressed: _loading ? null : _unlock,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
                child: _loading
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor:
                              AlwaysStoppedAnimation(cs.onPrimary),
                        ),
                      )
                    : const Text('Unlock'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}