import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../services/vaultexplorer_api.dart';
import '../../../utils/validation_utils.dart';

class CreateContainerSheet extends StatefulWidget {
  const CreateContainerSheet({Key? key}) : super(key: key);

  @override
  State<CreateContainerSheet> createState() =>
      _CreateContainerSheetState();
}

class _CreateContainerSheetState extends State<CreateContainerSheet> {
  final _nameCtrl = TextEditingController(text: 'vault.tc');
  final _sizeCtrl = TextEditingController(text: '10');
  final _passwordCtrl = TextEditingController();
  final _pimCtrl = TextEditingController();

  String _sizeUnit = 'MB';
  String _fileSystem = 'FAT'; // FAT (FAT32) or exFAT
  bool _obscure = true;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _sizeCtrl.dispose();
    _passwordCtrl.dispose();
    _pimCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_nameCtrl.text.isEmpty) {
      setState(() => _error = 'Container name is required');
      return;
    }
    final sizeVal = double.tryParse(_sizeCtrl.text);
    if (sizeVal == null || sizeVal <= 0) {
      setState(() => _error = 'Enter a valid size greater than 0');
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
      final multiplier =
          _sizeUnit == 'GB' ? 1024 * 1024 * 1024 : 1024 * 1024;
      final sizeBytes = (sizeVal * multiplier).round();

      // clampPim guards against absurdly large PBKDF2 iteration counts.
      final pim = clampPim(
          _pimCtrl.text.isEmpty ? 0 : int.tryParse(_pimCtrl.text) ?? 0);

      final success = await vaultExplorerApi.createContainer(
        displayName: _nameCtrl.text,
        sizeBytes: sizeBytes,
        password: _passwordCtrl.text,
        pim: pim,
        fileSystem: _fileSystem.toLowerCase(),
      );

      if (success) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Container file created successfully.')),
          );
        }
      } else {
        setState(
            () => _error = 'Container creation cancelled or failed.');
      }
    } on PlatformException catch (e) {
      setState(() => _error = e.message ?? 'Unknown error occurred');
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
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(16)),
        border: Border.all(color: cs.outline.withOpacity(0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: SingleChildScrollView(
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
                Text('Create VeraCrypt Container',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontSize: 17)),
                const SizedBox(height: 16),

                // File name
                TextField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'File Name',
                    prefixIcon: Icon(Icons.drive_file_rename_outline,
                        size: 18),
                  ),
                ),
                const SizedBox(height: 12),

                // Size and unit selection
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _sizeCtrl,
                        keyboardType:
                            const TextInputType.numberWithOptions(
                                decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Container Size',
                          prefixIcon:
                              Icon(Icons.sd_storage_outlined, size: 18),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _sizeUnit,
                        decoration:
                            const InputDecoration(labelText: 'Unit'),
                        items: const [
                          DropdownMenuItem(
                              value: 'MB', child: Text('MB')),
                          DropdownMenuItem(
                              value: 'GB', child: Text('GB')),
                        ],
                        onChanged: (val) {
                          if (val != null)
                            setState(() => _sizeUnit = val);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Password
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
                const SizedBox(height: 12),

                // PIM
                TextField(
                  controller: _pimCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'PIM  (leave blank for default)',
                    prefixIcon: Icon(Icons.tune, size: 18),
                  ),
                ),
                const SizedBox(height: 12),

                // File System selection
                DropdownButtonFormField<String>(
                  value: _fileSystem,
                  decoration: const InputDecoration(
                    labelText: 'Format File System',
                    prefixIcon: Icon(Icons.dns_outlined, size: 18),
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: 'FAT', child: Text('FAT (FAT32)')),
                    DropdownMenuItem(
                        value: 'exFAT', child: Text('exFAT')),
                  ],
                  onChanged: (val) {
                    if (val != null) setState(() => _fileSystem = val);
                  },
                ),

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: cs.error.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: cs.error.withOpacity(0.4)),
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
                  onPressed: _loading ? null : _create,
                  style: FilledButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(vertical: 14),
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
                      : const Text('Create Container',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}