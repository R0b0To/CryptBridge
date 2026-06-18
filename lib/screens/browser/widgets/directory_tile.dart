import 'package:flutter/material.dart';

class DirectoryTile extends StatelessWidget {
  final String name;
  final VoidCallback onTap;

  const DirectoryTile({
    Key? key,
    required this.name,
    required this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: const Icon(
        Icons.folder_outlined,
        size: 20,
        color: Color(0xFFFFA726),
      ),
      title: Text(name, style: Theme.of(context).textTheme.bodyMedium),
      trailing: Icon(Icons.chevron_right, size: 16, color: cs.outline),
      onTap: onTap,
    );
  }
}