import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import '../../services/app_settings_service.dart';
import '../../services/password_hasher.dart';
import '../dashboard/vault_dashboard.dart';

/// Shown at app start when a master password is configured.
/// Replaced by VaultDashboard on successful authentication.
class LockGateScreen extends StatefulWidget {
  const LockGateScreen({Key? key}) : super(key: key);

  @override
  State<LockGateScreen> createState() => _LockGateScreenState();
}

class _LockGateScreenState extends State<LockGateScreen> {
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _kFailedAttempts = 'lock_gate_failed_attempts_v1';
  static const _kLockedUntilMs = 'lock_gate_locked_until_ms_v1';

  AppSettings? _settings;
  bool _loading = true;

  final _pwCtrl = TextEditingController();
  bool _obscure = true;
  String? _error;
  bool _checking = false;

  int _failedAttempts = 0;
  DateTime? _lockedUntil;

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
    await _loadPersistedLockoutState();

    final s = await AppSettingsService.loadSettings();
    if (!mounted) return;

    if (!s.useMasterPassword || s.masterPasswordHash == null) {
      _goToDashboard();
      return;
    }

    setState(() {
      _settings = s;
      _loading = false;
    });

    if (s.masterPasswordIsFingerprint) {
      _tryBiometric();
    }
  }

  /// Restores [_failedAttempts] and [_lockedUntil] from secure storage.
  Future<void> _loadPersistedLockoutState() async {
    try {
      final storedAttempts = await _secure.read(key: _kFailedAttempts);
      final storedUntilMs = await _secure.read(key: _kLockedUntilMs);

      _failedAttempts = int.tryParse(storedAttempts ?? '') ?? 0;

      if (storedUntilMs != null) {
        final ms = int.tryParse(storedUntilMs);
        if (ms != null) {
          _lockedUntil = DateTime.fromMillisecondsSinceEpoch(ms);
          // Clear expired lockout from storage immediately
          if (_lockedUntil!.isBefore(DateTime.now())) {
            _lockedUntil = null;
            await _secure.delete(key: _kLockedUntilMs);
          }
        }
      }
    } catch (_) {
      // If secure storage read fails, start fresh rather than crashing
    }
  }

  Future<void> _tryBiometric() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isSupported = await _localAuth.isDeviceSupported();
      if (!canCheck || !isSupported) {
        if (mounted) {
          setState(() => _error = 'Biometric not available on this device');
        }
        return;
      }
      final ok = await _localAuth.authenticate(
        localizedReason: 'Unlock VaultExplorer',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
      if (ok && mounted) _goToDashboard();
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = 'Biometric error: ${e.message}');
    }
  }

  /// Returns remaining lockout duration, or null if not locked out.
  Duration? _currentLockout() {
    if (_lockedUntil == null) return null;
    final remaining = _lockedUntil!.difference(DateTime.now());
    if (remaining.isNegative) {
      _lockedUntil = null;
      // Clean up expired entry from storage (fire-and-forget)
      _secure.delete(key: _kLockedUntilMs).catchError((_) {});
      return null;
    }
    return remaining;
  }

  /// Records a failed attempt and applies exponential backoff lockout.
  ///
  /// Thresholds:
  ///   5 failures  → 30 s
  ///   6 failures  → 60 s
  ///   7 failures  → 120 s
  ///   8+ failures → 300 s (5 min)
  ///
  /// FIX: State is persisted to secure storage so killing the app
  /// between attempts does not reset the counter.
  Future<void> _recordFailure() async {
    _failedAttempts++;

    if (_failedAttempts >= 5) {
      final excess = _failedAttempts - 4;
      final seconds = (30 * excess).clamp(30, 300);
      _lockedUntil = DateTime.now().add(Duration(seconds: seconds));
    }

    // Persist atomically (best-effort — don't crash the UI on storage failure)
    try {
      await _secure.write(
        key: _kFailedAttempts,
        value: _failedAttempts.toString(),
      );
      if (_lockedUntil != null) {
        await _secure.write(
          key: _kLockedUntilMs,
          value: _lockedUntil!.millisecondsSinceEpoch.toString(),
        );
      }
    } catch (_) {}
  }

  /// Clears the persisted lockout state on successful authentication.
  Future<void> _clearLockoutState() async {
    _failedAttempts = 0;
    _lockedUntil = null;
    try {
      await _secure.delete(key: _kFailedAttempts);
      await _secure.delete(key: _kLockedUntilMs);
    } catch (_) {}
  }

  Future<void> _checkPassword() async {
    final s = _settings;
    if (s == null) return;

    // Enforce lockout before doing any work
    final lockout = _currentLockout();
    if (lockout != null) {
      setState(() {
        _error =
            'Too many failed attempts. '
            'Try again in ${lockout.inSeconds} second(s).';
      });
      return;
    }

    final pw = _pwCtrl.text;
    if (pw.isEmpty) {
      setState(() => _error = 'Enter your master password');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });

    // Small delay so the loading indicator renders before PBKDF2 blocking work.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;

    final ok = await PasswordHasher.verify(
      candidate: pw,
      hash: s.masterPasswordHash,
      salt: s.masterPasswordSalt,
    );
    if (!mounted) return;

    if (ok) {
      // FIX: Clear persisted counter on success
      await _clearLockoutState();

      if (s.needsHashUpgrade) {
        _upgradeMasterPasswordHashInBackground(s, pw);
      }
      _goToDashboard();
    } else {
      HapticFeedback.heavyImpact();
      // FIX: await the async persist
      await _recordFailure();
      if (!mounted) return;

      final newLockout = _currentLockout();
      setState(() {
        _checking = false;
        _error = newLockout != null
            ? 'Incorrect password. Locked for ${newLockout.inSeconds}s '
                  'due to $_failedAttempts failed attempts.'
            : 'Incorrect password ($_failedAttempts failed attempt'
                  '${_failedAttempts == 1 ? '' : 's'}).';
      });
      _pwCtrl.clear();
    }
  }

  void _upgradeMasterPasswordHashInBackground(AppSettings s, String pw) {
    PasswordHasher.deriveHash(pw)
        .then((result) async {
          await AppSettingsService.saveMasterPassword(
            s,
            result.hash,
            result.salt,
          );
        })
        .catchError((_) {});
  }

  void _goToDashboard() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const VaultDashboard()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    }

    final s = _settings!;
    final isLockedOut = _currentLockout() != null;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: AutofillGroup(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: cs.primaryContainer,
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: Icon(
                      Icons.lock_outline_rounded,
                      size: 32,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'VaultExplorer',
                    style: textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Enter your master password to continue',
                    style: textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 36),
                  TextField(
                    controller: _pwCtrl,
                    obscureText: _obscure,
                    enabled: !isLockedOut && !_checking,
                    autofocus: !s.masterPasswordIsFingerprint,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _checkPassword(),
                    decoration: InputDecoration(
                      labelText: 'Master Password',
                      prefixIcon: const Icon(Icons.key_rounded, size: 18),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: textTheme.bodySmall?.copyWith(color: cs.error),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: (_checking || isLockedOut)
                        ? null
                        : _checkPassword,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    child: _checking
                        ? SizedBox(
                            width: 20,
                            height: 20,
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
                      onPressed: isLockedOut ? null : _tryBiometric,
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
      ),
    );
  }
}
