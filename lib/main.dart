import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'theme.dart';
import 'screens/lock/lock_gate_screen.dart';

void main() {
  PlatformDispatcher.instance.onError = (error, stack) {
    final errStr = error.toString();
    if (errStr.contains('Cannot add event after closing') ||
        errStr.contains('video_player_mdk')) {
      return true;
    }
    return false;
  };

  fvp.registerWith(options: {
    'platforms': ['android'],
  });

  runApp(const VaultExplorerApp());
}

class VaultExplorerApp extends StatelessWidget {
  const VaultExplorerApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VaultExplorer',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      // LockGateScreen checks settings and either goes to dashboard directly
      // (no master password set) or shows the unlock UI.
      home: const LockGateScreen(),
    );
  }
}