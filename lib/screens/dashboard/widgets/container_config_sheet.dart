import 'package:flutter/material.dart';
import '../../../services/container_repository.dart';

class ContainerConfigSheet extends StatefulWidget {
  final String uri;
  final String currentLabel;
  final ContainerRecord? existingRecord;
  final void Function(ContainerRecord record) onSaved;
  final VoidCallback? onForget;

  const ContainerConfigSheet({
    Key? key,
    required this.uri,
    required this.currentLabel,
    this.existingRecord,
    required this.onSaved,
    this.onForget,
  }) : super(key: key);

  @override
  State<ContainerConfigSheet> createState() => _ContainerConfigSheetState();
}

class _ContainerConfigSheetState extends State<ContainerConfigSheet> {
  late TextEditingController _labelCtrl;
  late TextEditingController _passwordCtrl;
  late bool _rememberPassword;
  late bool _showPassword;
  late int  _autoCloseMins;
  late bool _documentProvider;
  bool _saving          = false;
  bool _loadingPassword = true;

  static const _autoCloseOptions = [0, 1, 2, 5, 10, 15, 30, 60];

  @override
  void initState() {
    super.initState();
    final rec       = widget.existingRecord;
    _labelCtrl      = TextEditingController(
        text: rec?.label.isNotEmpty == true ? rec!.label : widget.currentLabel);
    _passwordCtrl   = TextEditingController();
    _rememberPassword = rec?.rememberPassword ?? false;
    _showPassword   = false;
    _autoCloseMins  = rec?.autoCloseMins ?? 0;
    _documentProvider = rec?.documentProvider ?? false;
    _loadSavedPassword();
  }

  Future<void> _loadSavedPassword() async {
    if (widget.existingRecord?.rememberPassword == true) {
      final plain =
          await ContainerRepository.instance.getPassword(widget.uri);
      if (mounted) _passwordCtrl.text = plain ?? '';
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

    final label = _labelCtrl.text.trim().isEmpty
        ? widget.currentLabel
        : _labelCtrl.text.trim();

    // Build the record. pendingPassword is set only when the user has
    // explicitly entered/changed a password with rememberPassword enabled.
    final record = ContainerRecord(
      uri: widget.uri,
      label: label,
      rememberPassword: _rememberPassword,
      autoCloseMins: _autoCloseMins,
      documentProvider: _documentProvider,
      pendingPassword: _rememberPassword && _passwordCtrl.text.isNotEmpty
          ? _passwordCtrl.text
          : null,
    );

    // ContainerRepository.save handles Keystore write/delete atomically.
    await ContainerRepository.instance.save(record);

    widget.onSaved(record);
    if (mounted) Navigator.pop(context);
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
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Icon(Icons.settings_rounded, size: 20, color: cs.primary),
                  const SizedBox(width: 10),
                  Text('Container Settings',
                      style: textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 20),

                // ── Label ───────────────────────────────────────────────────
                TextField(
                  controller: _labelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Display Name',
                    prefixIcon:
                        Icon(Icons.label_outline_rounded, size: 18),
                    hintText: 'My Vault',
                  ),
                ),
                const SizedBox(height: 16),

                // ── Password ────────────────────────────────────────────────
                _SectionHeader('PASSWORD', cs),
                const SizedBox(height: 10),
                _ToggleRow(
                  icon: Icons.key_rounded,
                  title: 'Remember password',
                  subtitle: 'Stored securely in Android Keystore',
                  value: _rememberPassword,
                  cs: cs,
                  onChanged: (v) => setState(() {
                    _rememberPassword = v;
                    if (!v) _passwordCtrl.clear();
                  }),
                ),
                if (_rememberPassword) ...[
                  const SizedBox(height: 14),
                  if (_loadingPassword)
                    const Center(
                        child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2)))
                  else
                    TextField(
                      controller: _passwordCtrl,
                      obscureText: !_showPassword,
                      // SEC-07 fix: no autofill hints for container passwords.
                      autofillHints: null,
                      decoration: InputDecoration(
                        labelText: 'Container password',
                        prefixIcon: const Icon(Icons.lock_rounded, size: 18),
                        suffixIcon: IconButton(
                          icon: Icon(
                              _showPassword
                                  ? Icons.visibility_off_rounded
                                  : Icons.visibility_rounded,
                              size: 18),
                          onPressed: () =>
                              setState(() => _showPassword = !_showPassword),
                        ),
                        hintText: 'Enter container password',
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(children: [
                    Icon(Icons.security_rounded,
                        size: 14, color: cs.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Password is encrypted with a device-bound key in Android '
                        'Keystore. It is protected even if the APK is extracted, '
                        'but not if the device is rooted and the Keystore is bypassed.',
                        style: textTheme.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                  ]),
                ],
                const SizedBox(height: 16),

                // ── Auto-lock ───────────────────────────────────────────────
                _SectionHeader('AUTO-LOCK', cs),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  value: _autoCloseMins,
                  decoration: const InputDecoration(
                    labelText: 'Lock container after',
                    prefixIcon: Icon(Icons.timer_rounded, size: 18),
                  ),
                  items: _autoCloseOptions.map((mins) {
                    final label = mins == 0
                        ? 'Never'
                        : mins == 1
                            ? '1 minute'
                            : '$mins minutes';
                    return DropdownMenuItem(value: mins, child: Text(label));
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _autoCloseMins = v);
                  },
                ),
                const SizedBox(height: 16),

                // ── Document Provider ───────────────────────────────────────
                _SectionHeader('ANDROID INTEGRATION', cs),
                const SizedBox(height: 10),
                _ToggleRow(
                  icon: Icons.folder_shared_rounded,
                  title: 'Expose as Document Provider',
                  subtitle:
                      'Makes this container visible in Android\'s system file '
                      'picker when unlocked',
                  value: _documentProvider,
                  cs: cs,
                  onChanged: (v) =>
                      setState(() => _documentProvider = v),
                ),
                const SizedBox(height: 24),

                if (widget.onForget != null) ...[
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onForget!();
                    },
                    icon: Icon(Icons.delete_outline_rounded,
                        size: 18, color: cs.error),
                    label: Text('Remove from dashboard',
                        style:
                            textTheme.labelLarge?.copyWith(color: cs.error)),
                  ),
                  const SizedBox(height: 12),
                ],

                FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48)),
                  child: _saving
                      ? SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor:
                                  AlwaysStoppedAnimation(cs.onPrimary)))
                      : const Text('Save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final ColorScheme cs;
  const _SectionHeader(this.label, this.cs);

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(label.toUpperCase(),
          style: textTheme.labelSmall?.copyWith(
            color: cs.primary,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          )),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ColorScheme cs;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.cs,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        Icon(icon, size: 20, color: cs.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant)),
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}