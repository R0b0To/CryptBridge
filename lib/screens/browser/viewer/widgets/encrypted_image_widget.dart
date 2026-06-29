import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '/../../models/mounted_container.dart';
import '/../../services/vaultexplorer_api.dart';

class EncryptedImageWidget extends StatefulWidget {
  final MountedContainer container;
  final String fileName;
  final Uint8List? prefetchedBytes;
  final BoxFit fit;

  const EncryptedImageWidget({
    Key? key,
    required this.container,
    required this.fileName,
    this.prefetchedBytes,
    required this.fit,
  }) : super(key: key);

  @override
  State<EncryptedImageWidget> createState() => _EncryptedImageWidgetState();
}

class _EncryptedImageWidgetState extends State<EncryptedImageWidget> {
  Uint8List? _bytes;
  String? _error;
  bool _isFullResLoaded = false;
  String? _currentlyLoadingFile;

  @override
  void initState() {
    super.initState();
    _bytes = widget.prefetchedBytes;
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant EncryptedImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fileName != oldWidget.fileName) {
      _isFullResLoaded = false;
      _bytes = widget.prefetchedBytes;
      _error = null;
      _loadImage();
    } else if (!_isFullResLoaded && widget.prefetchedBytes != null && _bytes == null) {
      setState(() => _bytes = widget.prefetchedBytes);
    }
  }

  Future<void> _loadImage() async {
    final targetFile = widget.fileName;
    _currentlyLoadingFile = targetFile;

    try {
      final size = await vaultExplorerApi.getFileSize(widget.container, targetFile);
      if (size <= 0) throw Exception('File size is empty');

      final data = await vaultExplorerApi.readFileChunk(widget.container, targetFile, 0, size);
      
      if (!mounted || _currentlyLoadingFile != targetFile) return;

      if (data == null || data.isEmpty) {
        throw Exception('File returned no content bytes');
      }

      setState(() {
        _bytes = data;
        _isFullResLoaded = true;
      });
    } catch (e) {
      if (mounted && _currentlyLoadingFile == targetFile && _bytes == null) {
        setState(() => _error = 'Failed to load encrypted image: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            _error!,
            style: TextStyle(color: cs.error, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    
    if (_bytes == null) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
        ),
      );
    }
    
    return Image.memory(
      _bytes!,
      fit: widget.fit,
      errorBuilder: (context, error, stackTrace) => Center(
        child: Text(
          'Invalid or corrupted image format.',
          style: TextStyle(color: cs.error),
        ),
      ),
    );
  }
}