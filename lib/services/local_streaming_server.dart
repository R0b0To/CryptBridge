import 'dart:io';
import 'package:flutter/material.dart';
import '../models/mounted_container.dart';
import '../services/vaultexplorer_api.dart';

/// A lightweight local HTTP server that serves decrypted file chunks from a
/// [MountedContainer] over the loopback interface.
///
/// Bind once per screen, reuse for the session lifetime.
///
/// Usage:
/// ```dart
/// final server = LocalStreamingServer(container);
/// final port   = await server.start();
/// // ...
/// await server.stop(); // in dispose()
/// ```
class LocalStreamingServer {
  HttpServer? _server;
  final MountedContainer container;

  LocalStreamingServer(this.container);

  /// Binds to an ephemeral loopback port and returns the port number.
  Future<int> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest);
    return _server!.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method != 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }

      final fileName = request.uri.queryParameters['file'];
      if (fileName == null) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }

      final fileSize = await vaultExplorerApi.getFileSize(container, fileName);
      if (fileSize <= 0) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final headers = request.response.headers;
      headers.set(HttpHeaders.contentTypeHeader, _getMimeType(fileName));
      headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);

      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        // ── Partial / range request ─────────────────────────────────────────
        final parts = rangeHeader.substring(6).split('-');
        final start = int.tryParse(parts[0]) ?? 0;
        var end = (parts.length > 1 && parts[1].isNotEmpty)
            ? int.tryParse(parts[1]) ?? (fileSize - 1)
            : (fileSize - 1);
        if (end >= fileSize) end = fileSize - 1;

        final contentLength = end - start + 1;
        request.response.statusCode = HttpStatus.partialContent;
        headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-$end/$fileSize');
        headers.set(
            HttpHeaders.contentLengthHeader, contentLength.toString());

        var position = start;
        const chunkSize = 524288; // 512 KB
        while (position <= end) {
          final remaining = end - position + 1;
          final chunk = remaining < chunkSize ? remaining : chunkSize;
          final bytes = await vaultExplorerApi.readFileChunk(
              container, fileName, position, chunk);
          if (bytes == null || bytes.isEmpty) break;
          request.response.add(bytes);
          await request.response.flush();
          position += bytes.length;
        }
      } else {
        // ── Full / sequential request ───────────────────────────────────────
        headers.set(HttpHeaders.contentLengthHeader, fileSize.toString());
        request.response.statusCode = HttpStatus.ok;

        var position = 0;
        const chunkSize = 131072; // 128 KB
        while (position < fileSize) {
          final remaining = fileSize - position;
          final chunk = remaining < chunkSize ? remaining : chunkSize;
          final bytes = await vaultExplorerApi.readFileChunk(
              container, fileName, position, chunk);
          if (bytes == null || bytes.isEmpty) break;
          request.response.add(bytes);
          await request.response.flush();
          position += bytes.length;
        }
      }
    } catch (e, stack) {
      debugPrint('LocalStreamingServer: $e\n$stack');
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  String _getMimeType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
      case 'mkv':
        return 'video/x-matroska';
      case 'mov':
        return 'video/quicktime';
      case 'avi':
        return 'video/x-msvideo';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      default:
        return 'application/octet-stream';
    }
  }
}