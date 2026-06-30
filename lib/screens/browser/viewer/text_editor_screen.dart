import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vaultexplorer/models/mounted_container.dart';
import 'package:vaultexplorer/services/vaultexplorer_api.dart';

class TextEditorScreen extends StatefulWidget {
  final MountedContainer container;
  final String filePath;

  const TextEditorScreen({
    Key? key,
    required this.container,
    required this.filePath,
  }) : super(key: key);

  @override
  State<TextEditorScreen> createState() => _TextEditorScreenState();
}

class _TextEditorScreenState extends State<TextEditorScreen> {
  final TextEditingController _textController = TextEditingController();
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isDirty = false;
  bool _hasError = false;
  String _errorMessage = '';
  File? _tempFile;

  int _lineCount = 0;
  int _charCount = 0;

  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onTextChanged);
    _loadFile();
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _focusNode.dispose();
    _cleanTempFile();
    super.dispose();
  }

  void _onTextChanged() {
    final text = _textController.text;
    final lines = text.isEmpty ? 0 : text.split('\n').length;
    setState(() {
      _isDirty = true;
      _lineCount = lines;
      _charCount = text.length;
    });
  }

  Future<void> _cleanTempFile() async {
    if (_tempFile != null && await _tempFile!.exists()) {
      try {
        await _tempFile!.delete();
      } catch (e) {
        debugPrint('Error deleting temp file: $e');
      }
    }
  }

  Future<void> _loadFile() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
      _errorMessage = '';
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final extension = widget.filePath.split('.').last;
      _tempFile = File(
        '${tempDir.path}/cb_edit_${DateTime.now().microsecondsSinceEpoch}.$extension',
      );

      final ok = await vaultExplorerApi.decryptFile(
        widget.container,
        widget.filePath,
        _tempFile!.path,
      );

      if (!ok) {
        throw Exception('Failed to decrypt file from vault.');
      }

      final bytes = await _tempFile!.readAsBytes();
      String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        throw const FormatException(
          'The file does not appear to be a valid text file.',
        );
      }

      _textController.text = text;
      final lines = text.isEmpty ? 0 : text.split('\n').length;

      setState(() {
        _isLoading = false;
        _isDirty = false;
        _lineCount = lines;
        _charCount = text.length;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _hasError = true;
        _errorMessage = e.toString();
      });
    }
  }

  Future<bool> _saveFile() async {
    if (_tempFile == null) return false;
    setState(() {
      _isSaving = true;
    });

    try {
      final content = _textController.text;
      await _tempFile!.writeAsString(content, encoding: utf8);

      final ok = await vaultExplorerApi.writeBackFile(
        widget.container,
        widget.filePath,
        _tempFile!.path,
      );

      if (!ok) {
        throw Exception('Failed to write file back to vault.');
      }

      setState(() {
        _isSaving = false;
        _isDirty = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Changes saved successfully')),
        );
      }
      return true;
    } catch (e) {
      setState(() {
        _isSaving = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
      return false;
    }
  }

  Future<bool> _onWillPop() async {
    if (!_isDirty) return true;

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unsaved Changes'),
        content: const Text(
          'You have unsaved changes. Would you like to save before closing?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('discard'),
            child: Text(
              'Discard',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('cancel'),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == 'save') {
      final saved = await _saveFile();
      return saved;
    } else if (result == 'discard') {
      return true;
    }

    return false;
  }

  String get _fileName => widget.filePath.split('/').last;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_fileName),
          actions: [
            if (!_isLoading && !_hasError)
              IconButton(
                icon: _isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        Icons.save_rounded,
                        color: _isDirty ? cs.primary : cs.outline,
                      ),
                tooltip: 'Save changes',
                onPressed: (_isDirty && !_isSaving) ? _saveFile : null,
              ),
          ],
        ),
        body: _buildBody(cs, Theme.of(context).textTheme),
        bottomNavigationBar: _isLoading || _hasError
            ? null
            : _buildBottomBar(cs),
      ),
    );
  }

  Widget _buildBody(ColorScheme cs, TextTheme textTheme) {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(strokeWidth: 2.5),
            SizedBox(height: 16),
            Text('Decrypting file content...'),
          ],
        ),
      );
    }

    if (_hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline_rounded, color: cs.error, size: 48),
              const SizedBox(height: 16),
              Text(
                'Cannot open file',
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('Go back'),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        if (!_focusNode.hasFocus) {
          _focusNode.requestFocus();
        }
      },
      child: Container(
        color: Colors.transparent,
        height: double.infinity,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: SingleChildScrollView(
          child: TextField(
            controller: _textController,
            focusNode: _focusNode,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(ColorScheme cs) {
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            'Lines: $_lineCount  |  Chars: $_charCount',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
          const Spacer(),
          if (_isDirty)
            Text(
              'Unsaved Changes',
              style: TextStyle(
                color: Colors.amber[300],
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            )
          else
            Text(
              'Saved to vault',
              style: TextStyle(
                color: Colors.green[300],
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
        ],
      ),
    );
  }
}
