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

    setState(() { _settings = s; _loading = false; });

    if (s.masterPasswordIsFingerprint) {
      _tryBiometric();
    }
  }

  Future<void> _tryBiometric() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
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

  void _checkPassword() {
    final s = _settings;
    if (s == null) return;
    final pw = _pwCtrl.text;
    if (pw.isEmpty) { setState(() => _error = 'Enter your master password'); return; }
    setState(() { _checking = true; _error = null; });
    Future.delayed(const Duration(milliseconds: 80), () {
      if (!mounted) return;
      if (s.checkPassword(pw)) {
        _goToDashboard();
      } else {
        HapticFeedback.heavyImpact();
        setState(() { _error = 'Incorrect password'; _checking = false; });
        _pwCtrl.clear();
      }
    });
  }

  void _goToDashboard() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const VaultDashboard()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(strokeWidth: 2)));
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
                    border: Border.all(color: cs.primary.withOpacity(0.3)),
                  ),
                  child: Icon(Icons.lock_outline, size: 32, color: cs.primary),
                ),
                const SizedBox(height: 28),
                Text('VaultExplorer',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 22, letterSpacing: 0.5)),
                const SizedBox(height: 6),
                Text('Enter your master password to continue',
                    style: TextStyle(fontSize: 13, color: cs.outline)),
                const SizedBox(height: 36),
                TextField(
                  controller: _pwCtrl,
                  obscureText: _obscure,
                  autofocus: !s.masterPasswordIsFingerprint,
                  onSubmitted: (_) => _checkPassword(),
                  decoration: InputDecoration(
                    labelText: 'Master Password',
                    prefixIcon: const Icon(Icons.key_outlined, size: 18),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: TextStyle(color: cs.error, fontSize: 12)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _checking ? null : _checkPassword,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _checking
                      ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)))
                      : const Text('Unlock', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                if (s.masterPasswordIsFingerprint) ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _tryBiometric,
                    icon: const Icon(Icons.fingerprint, size: 20),
                    label: const Text('Use Biometric'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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