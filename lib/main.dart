import 'package:flutter/material.dart';

import 'theme.dart';
import 'screens/dashboard/vault_dashboard.dart';

void main() {
  runApp(const CryptBridgeApp());
}

class CryptBridgeApp extends StatelessWidget {
  const CryptBridgeApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CryptBridge',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const VaultDashboard(),
    );
  }
}