import 'package:flutter/material.dart';
import '../../../services/app_settings_service.dart';

class ContainerConfigSheet extends StatefulWidget {
  final String uri;
  final String currentLabel;
  final ContainerConfig? existingConfig;
  final void Function(ContainerConfig config) onSaved;

  const ContainerConfigSheet({
    Key? key,
    required this.uri,
    required this.currentLabel,
    this.existingConfig,
    required this.onSaved,
  }) : super(key: key);

  @override
  State<ContainerConfigSheet> createState() => _ContainerConfigSheetState();
}

class _ContainerConfigSheetState extends State<ContainerConfigSheet> {
  late TextEditingController _labelCtrl;
  late TextEditingController _passwordCtrl;
  late bool _rememberPassword;
  late bool _showPassword;
  late int _autoCloseMins;
  late bool _documentProvider;
  bool _saving = false;
  bool _loadingPassword = true;

  static const _autoCloseOptions = [0, 1, 2, 5, 10, 15, 30, 60];

  @override
  void initState() {
    super.initState();
    final cfg = widget.existingConfig;
    _labelCtrl = TextEditingController(
        text: cfg?.label.isNotEmpty == true ? cfg!.label : widget.currentLabel);
    _passwordCtrl = TextEditingController();
    _rememberPassword = cfg?.rememberPassword ?? false;
    _showPassword = false;
    _autoCloseMins = cfg?.autoCloseMins ?? 0;
    _documentProvider = cfg?.documentProvider ?? false;
    _loadSavedPassword();
  }

  Future<void> _loadSavedPassword() async {
    if (widget.existingConfig?.rememberPassword == true) {
      final plain = await widget.existingConfig!.getPassword();
      if (mounted) {
        _passwordCtrl.text = plain ?? '';
      }
    }
    if (mounted) setState(() => _loadingPassword = false);
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final config = ContainerConfig(
      uri: widget.uri,
      label: _labelCtrl.text.trim().isEmpty
          ? widget.currentLabel
          : _labelCtrl.text.trim(),
      rememberPassword: _rememberPassword,
      autoCloseMins: _autoCloseMins,
      documentProvider: _documentProvider,
    );
    // Obfuscate password before persisting.
    if (_rememberPassword && _passwordCtrl.text.isNotEmpty) {
      await config.setPassword(_passwordCtrl.text);
    }
    await AppSettingsService.saveContainerConfig(config);
    widget.onSaved(config);
    if (mounted) Navigator.pop(context);
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
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: SingleChildScrollView(
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
                  Icon(Icons.settings_outlined, size: 18, color: cs.primary),
                  const SizedBox(width: 10),
                  Text('Container Settings',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 16)),
                ]),
                const SizedBox(height: 20),

                // ── Label ──────────────────────────────────────────────────
                TextField(
                  controller: _labelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Display Name',
                    prefixIcon: Icon(Icons.label_outline, size: 18),
                    hintText: 'My Vault',
                  ),
                ),
                const SizedBox(height: 16),

                // ── Password ───────────────────────────────────────────────
                _SectionHeader('PASSWORD', cs),
                const SizedBox(height: 8),
                _ToggleRow(
                  icon: Icons.key_outlined,
                  title: 'Remember password',
                  subtitle: 'Obfuscated and stored in app data',
                  value: _rememberPassword,
                  cs: cs,
                  onChanged: (v) => setState(() {
                    _rememberPassword = v;
                    if (!v) _passwordCtrl.clear();
                  }),
                ),
                if (_rememberPassword) ...[
                  const SizedBox(height: 12),
                  if (_loadingPassword)
                    const Center(child: SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                  else
                    TextField(
                      controller: _passwordCtrl,
                      obscureText: !_showPassword,
                      decoration: InputDecoration(
                        labelText: 'Container password',
                        prefixIcon: const Icon(Icons.lock_outline, size: 18),
                        suffixIcon: IconButton(
                          icon: Icon(_showPassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined, size: 18),
                          onPressed: () => setState(() => _showPassword = !_showPassword),
                        ),
                        hintText: 'Enter container password',
                      ),
                    ),
                  const SizedBox(height: 6),
                  Row(children: [
                    Icon(Icons.security_outlined, size: 12, color: cs.outline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Stored obfuscated. Not cryptographically secure — '
                        'do not use if device root access is a concern.',
                        style: TextStyle(fontSize: 11, color: cs.outline),
                      ),
                    ),
                  ]),
                ],
                const SizedBox(height: 16),

                // ── Auto-lock ──────────────────────────────────────────────
                _SectionHeader('AUTO-LOCK', cs),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  value: _autoCloseMins,
                  decoration: const InputDecoration(
                    labelText: 'Lock container after',
                    prefixIcon: Icon(Icons.timer_outlined, size: 18),
                  ),
                  items: _autoCloseOptions.map((mins) {
                    final label = mins == 0 ? 'Never'
                        : mins == 1 ? '1 minute' : '$mins minutes';
                    return DropdownMenuItem(value: mins, child: Text(label));
                  }).toList(),
                  onChanged: (v) { if (v != null) setState(() => _autoCloseMins = v); },
                ),
                const SizedBox(height: 16),

                // ── Document Provider ──────────────────────────────────────
                _SectionHeader('ANDROID INTEGRATION', cs),
                const SizedBox(height: 8),
                _ToggleRow(
                  icon: Icons.folder_shared_outlined,
                  title: 'Expose as Document Provider',
                  subtitle: 'Makes this container visible in Android\'s '
                      'system file picker when unlocked',
                  value: _documentProvider,
                  cs: cs,
                  onChanged: (v) => setState(() => _documentProvider = v),
                ),
                const SizedBox(height: 24),

                // ── Save ───────────────────────────────────────────────────
                FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _saving
                      ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(Colors.white)))
                      : const Text('Save', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final ColorScheme cs;
  const _SectionHeader(this.label, this.cs);
  @override
  Widget build(BuildContext context) => Text(label.toUpperCase(),
      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
          letterSpacing: 1.2, color: cs.outline));
}

class _ToggleRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ColorScheme cs;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({required this.icon, required this.title,
      required this.subtitle, required this.value, required this.cs,
      required this.onChanged});
  @override
  Widget build(BuildContext context) => Row(children: [
    Icon(icon, size: 18, color: cs.onSurfaceVariant),
    const SizedBox(width: 12),
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      Text(subtitle, style: TextStyle(fontSize: 11, color: cs.outline)),
    ])),
    Switch(value: value, onChanged: onChanged, activeColor: cs.primary),
  ]);
}