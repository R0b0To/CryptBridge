/// Formats a byte count into a human-readable string (e.g. "4.2 MB", "1 GB").
/// Shared across ContainerCard, FileBrowserScreen's _StatsBar, and any other
/// widget that previously carried its own copy of this logic.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
  double size = bytes.toDouble();
  int idx = 0;
  while (size >= 1024 && idx < suffixes.length - 1) {
    size /= 1024;
    idx++;
  }
  return '${size.toStringAsFixed(size < 10 ? 1 : 0)} ${suffixes[idx]}';
}