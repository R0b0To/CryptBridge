import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';

void main() {
  runApp(const CryptBridgeApp());
}

class CryptBridgeApp extends StatelessWidget {
  const CryptBridgeApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CryptBridge',
      theme: ThemeData(
        primarySwatch: Colors.blueGrey,
        brightness: Brightness.dark,
      ),
      home: const VaultScreen(),
    );
  }
}

class VaultScreen extends StatefulWidget {
  const VaultScreen({Key? key}) : super(key: key);

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  static const platform = MethodChannel('com.example.cryptbridge/engine');
  
  String? _selectedFilePath;
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _pimController = TextEditingController();
  
  bool _isUnlocked = false;
  bool _isUnlocking = false;
  List<String> _decryptedFiles = [];

Future<void> _pickContainer() async {
    try {
      // Invoke native System SAF Picker
      final String? uri = await platform.invokeMethod('pickContainer');
      if (uri != null) {
        setState(() {
          _selectedFilePath = uri;
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error picking container: $e')),
      );
    }
  }

  Future<void> _unlockContainer() async {
    if (_selectedFilePath == null || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a file and enter a password')),
      );
      return;
    }

    setState(() {
      _isUnlocking = true;
      _decryptedFiles = [];
    });

    try {
      final List<dynamic>? files = await platform.invokeMethod('unlockContainer', {
        'filePath': _selectedFilePath,
        'password': _passwordController.text,
        'pim': _pimController.text.isEmpty ? 0 : int.parse(_pimController.text),
      });

      if (files != null) {
        setState(() {
          _decryptedFiles = files.cast<String>();
          _isUnlocked = true; // Mark as unlocked!
        });
      }
    } on PlatformException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: ${e.message}")));
    } finally {
      setState(() { _isUnlocking = false; });
    }
  }

  Future<void> _lockContainer() async {
    if (_selectedFilePath == null) return;
    
    setState(() { _isUnlocking = true; });

    try {
      final bool success = await platform.invokeMethod('lockContainer', {
        'filePath': _selectedFilePath,
      });

      if (success) {
        setState(() {
          _decryptedFiles = [];
          _isUnlocked = false; // Mark as locked!
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('🔒 Container safely unmounted/locked.'), backgroundColor: Colors.amber),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lock error: $e')));
    } finally {
      setState(() { _isUnlocking = false; });
    }
  }
  Future<void> _extractAndOpenFile(String fileName) async {
    // Ignore folder items or system labels
    if (fileName.startsWith("[DIR]") || fileName.startsWith("System:")) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Exporting $fileName to Downloads...')),
    );

    try {
      // 1. Point directly to the phone's public Downloads directory
      final publicDownloadsDir = Directory('/storage/emulated/0/Download');
      
      // Ensure the directory exists (it always does, but safe design first)
      if (!await publicDownloadsDir.exists()) {
        await publicDownloadsDir.create(recursive: true);
      }

      final targetFilePath = "${publicDownloadsDir.path}/$fileName";

      // 2. Ask C++ to decrypt the file directly into that public path
      final bool success = await platform.invokeMethod('decryptFile', {
        'filePath': _selectedFilePath,
        'password': _passwordController.text,
        'pim': _pimController.text.isEmpty ? 0 : int.parse(_pimController.text),
        'fileName': fileName,
        'destPath': targetFilePath,
      });

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully exported to Downloads: $fileName'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 5),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to decrypt file (Internal cluster read error)')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Extraction error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CryptBridge')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('Select VeraCrypt Container'),
              onPressed: _pickContainer,
            ),
            if (_selectedFilePath != null) ...[
              const SizedBox(height: 10),
              Text('Selected: $_selectedFilePath', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
            const SizedBox(height: 20),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _pimController,
              decoration: const InputDecoration(
                labelText: 'PIM (Leave empty for default)',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isUnlocking || _isUnlocked ? null : _unlockContainer,
                    child: _isUnlocking && !_isUnlocked
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Unlock Container'),
                  ),
                ),
                if (_isUnlocked) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red[900]),
                      onPressed: _isUnlocking ? null : _lockContainer,
                      child: const Text('Lock/Unmount'),
                    ),
                  ),
                ],
              ],
            ),
            const Divider(height: 40),
            const Text('Container Contents:', style: TextStyle(fontWeight: FontWeight.bold)),
            Expanded(
              child: ListView.builder(
                itemCount: _decryptedFiles.length,
                itemBuilder: (context, index) {
                  final item = _decryptedFiles[index];
                  final isDir = item.startsWith("[DIR]");
                  final isHeader = item.startsWith("System:");

                  return ListTile(
                    leading: Icon(
                      isHeader
                          ? Icons.info_outline
                          : isDir
                              ? Icons.folder
                              : Icons.insert_drive_file,
                      color: isHeader 
                          ? Colors.blue 
                          : (isDir ? Colors.amber : Colors.grey),
                    ),
                    title: Text(item),
                    onTap: () => _extractAndOpenFile(item),
                  );
                },
              ),
            )
          ],
        ),
      ),
    );
  }
}