import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import '../../services/vaultexplorer_api.dart';
import '../../services/container_repository.dart';
import '../../models/mounted_container.dart';
import '../../utils/validation_utils.dart';
import '../lock/pattern_lock_view.dart';

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

  // ── Unlock method state ──────────────────────────────────────────────────
  ContainerUnlockMethod _unlockMethod = ContainerUnlockMethod.password;
  bool _showPasswordFallback = false;
  bool _patternError = false;
  int _patternResetKey = 0;
  String? _storedPatternHash;
  bool _loadingAuth = true;

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
    _initUnlockMethod();
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _pimCtrl.dispose();
    super.dispose();
  }

  /// Loads the container record and prepares the appropriate unlock flow.
  Future<void> _initUnlockMethod() async {
    if (widget.initialUri == null) {
      // Fresh mount — no saved record, just show password field.
      if (mounted) setState(() => _loadingAuth = false);
      return;
    }

    try {
      final records = await ContainerRepository.instance.loadAll();
      final record = records[widget.initialUri];
      if (record == null) {
        if (mounted) setState(() => _loadingAuth = false);
        return;
      }

      _unlockMethod = record.unlockMethod;

      if (_unlockMethod == ContainerUnlockMethod.pattern) {
        _storedPatternHash = await ContainerRepository.instance.getPatternHash(
          widget.initialUri!,
        );
      }

      if (mounted) setState(() => _loadingAuth = false);

      // Auto-trigger biometric prompt.
      if (_unlockMethod == ContainerUnlockMethod.biometrics) {
        _tryBiometric();
      }
    } catch (_) {
      if (mounted) setState(() => _loadingAuth = false);
    }
  }

  // ── Biometric ────────────────────────────────────────────────────────────

  Future<void> _tryBiometric() async {
    try {
      final localAuth = LocalAuthentication();
      final ok = await localAuth.authenticate(
        localizedReason: 'Authenticate to unlock container',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
      if (ok && mounted) {
        // Fetch saved password and auto-unlock.
        final pw = await ContainerRepository.instance.getPassword(
          widget.initialUri!,
        );
        if (pw != null && pw.isNotEmpty) {
          _passwordCtrl.text = pw;
          _unlock();
        } else {
          setState(() {
            _error = 'No saved password found. Please enter it manually.';
            _showPasswordFallback = true;
          });
        }
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Biometric error: ${e.message}';
          _showPasswordFallback = true;
        });
      }
    }
  }

  // ── Pattern ──────────────────────────────────────────────────────────────

  Future<void> _onPatternComplete(List<int> pattern) async {
    if (_storedPatternHash == null) {
      setState(() {
        _error = 'No pattern configured. Please enter password manually.';
        _showPasswordFallback = true;
      });
      return;
    }

    final attempt = hashPattern(pattern);
    if (attempt == _storedPatternHash) {
      // Pattern matches — fetch saved password and unlock.
      final pw = await ContainerRepository.instance.getPassword(
        widget.initialUri!,
      );
      if (pw != null && pw.isNotEmpty) {
        _passwordCtrl.text = pw;
        _unlock();
      } else {
        setState(() {
          _error = 'No saved password found. Please enter it manually.';
          _showPasswordFallback = true;
        });
      }
    } else {
      setState(() {
        _patternError = true;
      });
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) {
          setState(() {
            _patternError = false;
            _patternResetKey++;
          });
        }
      });
    }
  }

  // ── File picking ─────────────────────────────────────────────────────────

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
      final pim = clampPim(
        _pimCtrl.text.isEmpty ? 0 : int.tryParse(_pimCtrl.text) ?? 0,
      );
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
        final free = (space != null && space.length > 1) ? space[1] : 0;

        widget.onMounted(
          MountedContainer(
            uri: _selectedUri!,
            displayName: name,
            volId: result.volId,
            rootFiles: result.files,
            mountedAt: DateTime.now(),
            totalSpace: total,
            freeSpace: free,
          ),
        );

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

  // ── Whether to show the standard password UI ────────────────────────────

  bool get _showPasswordUI {
    if (_showPasswordFallback) return true;
    if (widget.initialUri == null) return true; // fresh mount — always show
    return _unlockMethod == ContainerUnlockMethod.password ||
        _unlockMethod == ContainerUnlockMethod.rememberPassword;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final mq = MediaQuery.of(context);

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
              Row(
                children: [
                  Text(
                    widget.initialUri != null
                        ? 'Unlock Container'
                        : 'Mount Container',
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // File picker
              GestureDetector(
                onTap: _pickFile,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 16,
                  ),
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
                  child: Row(
                    children: [
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
                          onTap: () => setState(() {
                            _selectedUri = null;
                            _selectedName = null;
                          }),
                          child: Icon(
                            Icons.clear_rounded,
                            size: 18,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.check_circle_rounded,
                          size: 18,
                          color: cs.primary,
                        ),
                      ] else if (_selectedUri != null &&
                          widget.initialUri != null) ...[
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 18,
                          color: cs.primary,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ── Auth-specific UI ──────────────────────────────────────────
              if (_loadingAuth)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              // ── Biometric prompt feedback ──────────────────────────────
              else if (_unlockMethod == ContainerUnlockMethod.biometrics &&
                  !_showPasswordFallback) ...[
                Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.fingerprint_rounded,
                        size: 56,
                        color: cs.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Waiting for biometric...',
                        style: textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: _tryBiometric,
                        child: const Text('Retry'),
                      ),
                      TextButton(
                        onPressed: () =>
                            setState(() => _showPasswordFallback = true),
                        child: const Text('Use Password'),
                      ),
                    ],
                  ),
                ),
              ]
              // ── Pattern grid ───────────────────────────────────────────
              else if (_unlockMethod == ContainerUnlockMethod.pattern &&
                  !_showPasswordFallback) ...[
                Center(
                  child: Column(
                    children: [
                      Text(
                        _patternError
                            ? 'Wrong pattern — try again'
                            : 'Draw your unlock pattern',
                        style: textTheme.bodyMedium?.copyWith(
                          color: _patternError ? cs.error : cs.onSurfaceVariant,
                          fontWeight: _patternError ? FontWeight.bold : null,
                        ),
                      ),
                      const SizedBox(height: 16),
                      PatternLockView(
                        key: ValueKey(_patternResetKey),
                        onPatternComplete: _onPatternComplete,
                        showError: _patternError,
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () =>
                            setState(() => _showPasswordFallback = true),
                        child: const Text('Use Password'),
                      ),
                    ],
                  ),
                ),
              ]
              // ── Standard password fields ───────────────────────────────
              else if (_showPasswordUI) ...[
                AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _passwordCtrl,
                        obscureText: _obscure,
                        autofocus:
                            widget.initialUri != null &&
                            widget.prefillPassword?.isEmpty != false,
                        onChanged: (_) => setState(() {}),
                        keyboardType: TextInputType.visiblePassword,
                        autofillHints: const [AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.key_outlined, size: 18),
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_passwordPrefilled)
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Tooltip(
                                    message: 'Using saved password',
                                    child: Icon(
                                      Icons.bookmark_rounded,
                                      size: 18,
                                      color: cs.primary,
                                    ),
                                  ),
                                ),
                              IconButton(
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                                icon: Icon(
                                  _obscure
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                  size: 18,
                                ),
                              ),
                            ],
                          ),
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
                        Row(
                          children: [
                            Checkbox(
                              value: _remember,
                              onChanged: (val) =>
                                  setState(() => _remember = val ?? false),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                            const SizedBox(width: 10),
                            GestureDetector(
                              onTap: () =>
                                  setState(() => _remember = !_remember),
                              child: Text(
                                'Remember container on dashboard',
                                style: textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],

              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        size: 20,
                        color: cs.onErrorContainer,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _error!,
                          style: textTheme.bodySmall?.copyWith(
                            color: cs.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Only show the unlock button when password UI is visible.
              if (_showPasswordUI) ...[
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
                            valueColor: AlwaysStoppedAnimation(cs.onPrimary),
                          ),
                        )
                      : const Text('Unlock'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
