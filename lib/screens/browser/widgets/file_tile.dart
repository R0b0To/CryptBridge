import 'package:flutter/material.dart';

class FileTile extends StatelessWidget {
  final String name;
  final VoidCallback onTap;

  const FileTile({
    Key? key,
    required this.name,
    required this.onTap,
  }) : super(key: key);

  static IconData _iconFor(String name) {
    final ext = name.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
        return Icons.image_outlined;
      case 'mp4':
      case 'mov':
      case 'avi':
      case 'mkv':
        return Icons.ondemand_video_outlined;
      case 'mp3':
      case 'flac':
      case 'wav':
      case 'm4a':
        return Icons.audio_file_outlined;
      case 'txt':
      case 'md':
      case 'csv':
        return Icons.article_outlined;
      case 'zip':
      case 'gz':
      case 'tar':
      case '7z':
        return Icons.archive_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  static Color _colorFor(String name) {
    final ext = name.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return const Color(0xFFEF5350);
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
        return const Color(0xFF26C6DA);
      case 'mp4':
      case 'mov':
      case 'avi':
      case 'mkv':
        return const Color(0xFF7E57C2);
      case 'mp3':
      case 'flac':
      case 'wav':
      case 'm4a':
        return const Color(0xFF66BB6A);
      case 'txt':
      case 'md':
      case 'csv':
        return const Color(0xFF78909C);
      default:
        return const Color(0xFF546E7A);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Icon(_iconFor(name), size: 20, color: _colorFor(name)),
      title: Text(name, style: Theme.of(context).textTheme.bodyMedium),
      trailing: Icon(
        Icons.more_horiz,
        size: 16,
        color: Theme.of(context).colorScheme.outline,
      ),
      onTap: onTap,
    );
  }
}