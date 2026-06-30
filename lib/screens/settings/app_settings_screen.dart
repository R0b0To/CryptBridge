import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vaultexplorer/main.dart';
import '../../models/thumbnail_cache_mode.dart';
import '../../services/app_settings_service.dart';
import '../../services/password_hasher.dart';

class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({Key? key}) : super(key: key);

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  AppSettings _settings = AppSettings();
  bool _loading = true;
  bool _saving  = false;

  bool _showPwFields    = false;
  final _pwCtrl         = TextEditingController();
  final _pwConfirmCtrl  = TextEditingController();
  bool _obscurePw       = true;
  bool _obscureConfirm  = true;
  String? _pwError;

  bool _biometricAvailable = false;
  final _localAuth = LocalAuthentication();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pwCtrl.dispose();
    _pwConfirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await AppSettingsService.loadSettings();
    bool bioAvail = false;
    try {
      bioAvail = await _localAuth.canCheckBiometrics &&
          await _localAuth.isDeviceSupported();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _settings            = s;
        _biometricAvailable  = bioAvail;
        _loading             = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await AppSettingsService.saveSettings(_settings);
    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    }
  }

  void _toggleMasterPassword(bool enabled) {
    setState(() {
      _settings.useMasterPassword = enabled;
      if (!enabled) {
        AppSettingsService.clearMasterPassword(_settings);
        _settings.masterPasswordIsFingerprint = false;
        _showPwFields = false;
        _pwCtrl.clear();
        _pwConfirmCtrl.clear();
        _pwError = null;
      } else {
        _showPwFields = true;
      }
    });
  }

  /// Derives PBKDF2-SHA512 via [PasswordHasher] and persists hash to Android Keystore.
  Future<void> _confirmPassword() async {
    final pw      = _pwCtrl.text;
    final confirm = _pwConfirmCtrl.text;
    if (pw.isEmpty) {
      setState(() => _pwError = 'Password cannot be empty');
      return;
    }
    if (pw.length < 4) {
      setState(() => _pwError = 'At least 4 characters required');
      return;
    }
    if (pw != confirm) {
      setState(() => _pwError = 'Passwords do not match');
      return;
    }

    setState(() { _saving = true; _pwError = null; });

    try {
      final (:hash, :salt) = await PasswordHasher.deriveHash(pw);
      if (!mounted) return;

      await AppSettingsService.saveMasterPassword(_settings, hash, salt);

      setState(() {
        _showPwFields = false;
        _pwCtrl.clear();
        _pwConfirmCtrl.clear();
        _saving = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Master password set')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _pwError = 'Failed to hash password — please try again';
          _saving  = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs        = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('App Settings'),
        actions: [
          if (!_loading && !_showPwFields)
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.5,
                          color: cs.primary),
                    )
                  : Text('Save',
                      style: TextStyle(color: cs.primary,
                          fontWeight: FontWeight.bold)),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [

                _SectionLabel('SECURITY', cs),
                const SizedBox(height: 8),
                _Card(cs: cs, children: [

                  _ToggleRow(
                    icon: Icons.lock_person_rounded,
                    title: 'Master Password',
                    subtitle: _settings.useMasterPassword &&
                            _settings.masterPasswordHash != null
                        ? 'Active — tap toggle to remove'
                        : 'Require a password to open the app',
                    value: _settings.useMasterPassword,
                    cs: cs,
                    onChanged: _toggleMasterPassword,
                  ),

                  if (_settings.useMasterPassword && _showPwFields) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _pwCtrl,
                      obscureText: _obscurePw,
                      autofillHints: null,
                      decoration: InputDecoration(
                        labelText: _settings.masterPasswordHash != null
                            ? 'New password'
                            : 'Master password',
                        prefixIcon: const Icon(Icons.password_rounded, size: 18),
                        suffixIcon: IconButton(
                          icon: Icon(
                              _obscurePw
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 18),
                          onPressed: () =>
                              setState(() => _obscurePw = !_obscurePw),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pwConfirmCtrl,
                      obscureText: _obscureConfirm,
                      autofillHints: null,
                      decoration: InputDecoration(
                        labelText: 'Confirm password',
                        prefixIcon: const Icon(Icons.password_rounded, size: 18),
                        suffixIcon: IconButton(
                          icon: Icon(
                              _obscureConfirm
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 18),
                          onPressed: () =>
                              setState(
                                  () => _obscureConfirm = !_obscureConfirm),
                        ),
                      ),
                    ),
                    if (_pwError != null) ...[
                      const SizedBox(height: 10),
                      Text(_pwError!,
                          style: textTheme.bodySmall
                              ?.copyWith(color: cs.error)),
                    ],
                    const SizedBox(height: 16),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _saving
                              ? null
                              : () => setState(() {
                                    _showPwFields = false;
                                    _pwCtrl.clear();
                                    _pwConfirmCtrl.clear();
                                    _pwError = null;
                                    if (_settings.masterPasswordHash == null) {
                                      _settings.useMasterPassword = false;
                                    }
                                  }),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 40)),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _saving ? null : _confirmPassword,
                          style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 40)),
                          child: _saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : Text(_settings.masterPasswordHash != null
                                  ? 'Update'
                                  : 'Set Password'),
                        ),
                      ),
                    ]),
                  ],

                  if (_settings.useMasterPassword &&
                      _settings.masterPasswordHash != null &&
                      !_showPwFields) ...[
                    const Divider(height: 24),

                    if (_biometricAvailable)
                      _ToggleRow(
                        icon: Icons.fingerprint_rounded,
                        title: 'Biometric Unlock',
                        subtitle: 'Use fingerprint or face instead of typing',
                        value: _settings.masterPasswordIsFingerprint,
                        cs: cs,
                        onChanged: (v) => setState(
                            () => _settings.masterPasswordIsFingerprint = v),
                      ),
                    if (!_biometricAvailable)
                      Padding(
                        padding: const EdgeInsets.only(left: 32, top: 4),
                        child: Text(
                          'Biometric not available on this device',
                          style: textTheme.bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ),

                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: () => setState(
                          () { _showPwFields = true; _pwError = null; }),
                      icon: const Icon(Icons.edit_rounded, size: 16),
                      label: const Text('Change password'),
                    ),
                  ],
                ]),

                const SizedBox(height: 24),

                _SectionLabel('INTEGRATION', cs),
                const SizedBox(height: 8),
                _Card(cs: cs, children: [
                  _ToggleRow(
                    icon: Icons.folder_shared_rounded,
                    title: 'Document Provider (default)',
                    subtitle:
                        'New containers will be exposed in Android\'s file '
                        'picker by default.',
                    value: _settings.defaultDocumentProvider,
                    cs: cs,
                    onChanged: (v) =>
                        setState(() => _settings.defaultDocumentProvider = v),
                  ),
                  const Divider(height: 24),
                  DropdownButtonFormField<ThumbnailCacheMode>(
                    value: _settings.defaultThumbnailCacheMode,
                    decoration: const InputDecoration(
                      labelText: 'Thumbnail Caching (default)',
                      prefixIcon: Icon(Icons.cached_rounded, size: 18),
                    ),
                    items: ThumbnailCacheMode.values.map((mode) {
                      return DropdownMenuItem(
                        value: mode,
                        child: Text(mode.label),
                      );
                    }).toList(),
                    onChanged: (v) {
                      if (v != null) {
                        setState(() => _settings.defaultThumbnailCacheMode = v);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      _settings.defaultThumbnailCacheMode.description,
                      style: textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant, height: 1.4),
                    ),
                  ),
                ]),

                const SizedBox(height: 24),

                _SectionLabel('ABOUT', cs),
                const SizedBox(height: 8),
                _Card(cs: cs, children: [
                  _InfoRow('Version',        appVersion,                  cs),
                  const Divider(),
                  _InfoRow('Encryption',     'AES-256-XTS (VeraCrypt)', cs),
                  const Divider(),
                  _InfoRow('Key derivation', 'PBKDF2-SHA512',           cs),
                  const Divider(),
                  _InfoRow('Filesystem',     'FAT32 / exFAT via FatFs', cs),
                  const Divider(),
                  GestureDetector(
                  onTap: () => launchUrl(Uri.parse('https://github.com/R0b0To/VaultExplorer')),
                  child: _InfoRow('GitHub', 'https://github.com/R0b0To/VaultExplorer', cs),
                    ),
                ]),

                const SizedBox(height: 32),
              ],
            ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String label;
  final ColorScheme cs;
  const _SectionLabel(this.label, this.cs);

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Text(label,
          style: textTheme.labelSmall?.copyWith(
            color: cs.primary,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.4,
          )),
    );
  }
}

class _Card extends StatelessWidget {
  final List<Widget> children;
  final ColorScheme cs;
  const _Card({required this.children, required this.cs});

  @override
  Widget build(BuildContext context) => Card(
        color: cs.surfaceContainerLow,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children),
        ),
      );
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 20, color: cs.onSurfaceVariant),
          ),
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
                    style: textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant, height: 1.4)),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final ColorScheme cs;
  const _InfoRow(this.label, this.value, this.cs);

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Text(label,
              style: textTheme.bodyMedium
                  ?.copyWith(color: cs.onSurfaceVariant)),
          const Spacer(),
          Text(value,
              style: textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}