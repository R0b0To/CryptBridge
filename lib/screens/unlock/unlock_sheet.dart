import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '/models/mounted_container.dart';
import '/services/cryptbridge_api.dart';

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

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _pimCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final uri = await CryptBridgeApi.pickContainer();
      if (uri != null) {
        setState(() {
          _selectedUri = uri;
          _selectedName = uri.split('/').last.split('%2F').last;
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
      final pim = int.tryParse(_pimCtrl.text) ?? 0;
      final result = await CryptBridgeApi.unlockContainer(
        _selectedUri!,
        _passwordCtrl.text,
        pim,
      );

      if (result != null) {
        final name = Uri.decodeFull(_selectedName ?? 'Container');
        widget.onMounted(MountedContainer(
          uri: _selectedUri!,
          displayName: name,
          volId: result.volId,
          password: _passwordCtrl.text,
          pim: pim,
          rootFiles: result.files,
          mountedAt: DateTime.now(),
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
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      margin: EdgeInsets.only(bottom: bottomInset),
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
              _Handle(),
              const SizedBox(height: 20),
              Text(
                'Mount Container',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontSize: 17),
              ),
              const SizedBox(height: 20),
              _FilePicker(
                selectedName: _selectedName,
                onTap: _pickFile,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordCtrl,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.key_outlined, size: 18),
                  suffixIcon: IconButton(
                    onPressed: () =>
                        setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 18,
                    ),
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
                _ErrorBanner(message: _error!),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _loading ? null : _unlock,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation(Colors.white),
                        ),
                      )
                    : const Text(
                        'Unlock',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Small private sub-widgets ────────────────────────────────────────────────

class _Handle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.outline,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _FilePicker extends StatelessWidget {
  final String? selectedName;
  final VoidCallback onTap;
  const _FilePicker({required this.selectedName, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasFile = selectedName != null;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: cs.surfaceVariant,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: hasFile ? cs.primary.withOpacity(0.5) : cs.outline,
          ),
        ),
        child: Row(
          children: [
            Icon(
              hasFile ? Icons.description_outlined : Icons.folder_open,
              size: 18,
              color: hasFile ? cs.primary : cs.outline,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                selectedName ?? 'Select VeraCrypt container…',
                style: TextStyle(
                  color: hasFile ? cs.onSurface : cs.outline,
                  fontSize: 13,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (hasFile)
              Icon(Icons.check_circle, size: 16, color: cs.primary),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.error.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.error.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: cs.error, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
