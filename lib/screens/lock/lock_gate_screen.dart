import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import '../../services/app_settings_service.dart';
import '../dashboard/vault_dashboard.dart';

/// Shown at app start when a master password is configured.
/// Replaced by VaultDashboard on successful authentication.
class LockGateScreen extends StatefulWidget {
  const LockGateScreen({Key? key}) : super(key: key);

  @override
  State<LockGateScreen> createState() => _LockGateScreenState();
}

class _LockGateScreenState extends State<LockGateScreen> {
  AppSettings? _settings;
  bool _loading = true;

  final _pwCtrl = TextEditingController();
  bool _obscure = true;
  String? _error;
  bool _checking = false;

  final _localAuth = LocalAuthentication();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final s = await AppSettingsService.loadSettings();
    if (!mounted) return;

    if (!s.useMasterPassword || s.masterPasswordHash == null) {
      _goToDashboard();
      return;
    }

    setState(() {
      _settings = s;
      _loading  = false;
    });

    if (s.masterPasswordIsFingerprint) {
      _tryBiometric();
    }
  }

  Future<void> _tryBiometric() async {
    try {
      final canCheck   = await _localAuth.canCheckBiometrics;
      final isSupported = await _localAuth.isDeviceSupported();
      if (!canCheck || !isSupported) {
        if (mounted) setState(() => _error = 'Biometric not available on this device');
        return;
      }
      final ok = await _localAuth.authenticate(
        localizedReason: 'Unlock VaultExplorer',
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
      if (ok && mounted) _goToDashboard();
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = 'Biometric error: ${e.message}');
    }
  }

  // FIX: now async — checkPassword calls PBKDF2 via the C++ layer.
  Future<void> _checkPassword() async {
    final s = _settings;
    if (s == null) return;
    final pw = _pwCtrl.text;
    if (pw.isEmpty) {
      setState(() => _error = 'Enter your master password');
      return;
    }
    setState(() { _checking = true; _error = null; });

    // Small delay so the loading indicator renders before the PBKDF2 call
    // consumes the thread for ~100 ms.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;

    final ok = await s.checkPassword(pw);
    if (!mounted) return;

    if (ok) {
      // FIX: silently upgrade legacy 32-bit hash to PBKDF2-SHA512 on first
      // successful login so the user is not locked out during the transition.
      if (s.needsHashUpgrade) {
        _upgradeMasterPasswordHashInBackground(s, pw);
      }
      _goToDashboard();
    } else {
      HapticFeedback.heavyImpact();
      setState(() { _error = 'Incorrect password'; _checking = false; });
      _pwCtrl.clear();
    }
  }

  /// Runs the PBKDF2 key-derivation and persists the upgraded hash in the
  /// background so it doesn't block navigation.  Non-fatal on failure —
  /// the user will be prompted again on the next launch.
  void _upgradeMasterPasswordHashInBackground(AppSettings s, String pw) {
    AppSettings.derivePasswordHash(pw).then((hashSalt) async {
      s.masterPasswordHash = hashSalt.$1;
      s.masterPasswordSalt = hashSalt.$2;
      await AppSettingsService.saveSettings(s);
    }).catchError((_) {});
  }

  void _goToDashboard() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const VaultDashboard()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs        = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    }

    final s = _settings!;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.primaryContainer,
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: Icon(Icons.lock_outline_rounded, size: 32, color: cs.primary),
                ),
                const SizedBox(height: 28),
                Text(
                  'VaultExplorer',
                  style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold, letterSpacing: -0.2),
                ),
                const SizedBox(height: 8),
                Text(
                  'Enter your master password to continue',
                  style: textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 36),
                TextField(
                  controller: _pwCtrl,
                  obscureText: _obscure,
                  autofocus: !s.masterPasswordIsFingerprint,
                  onSubmitted: (_) => _checkPassword(),
                  decoration: InputDecoration(
                    labelText: 'Master Password',
                    prefixIcon: const Icon(Icons.key_rounded, size: 18),
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: textTheme.bodySmall?.copyWith(color: cs.error)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _checking ? null : _checkPassword,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                  ),
                  child: _checking
                      ? SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor: AlwaysStoppedAnimation(cs.onPrimary),
                          ),
                        )
                      : const Text('Unlock'),
                ),
                if (s.masterPasswordIsFingerprint) ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _tryBiometric,
                    icon: const Icon(Icons.fingerprint_rounded, size: 20),
                    label: const Text('Use Biometric'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}