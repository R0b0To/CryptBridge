class MountedContainer {
  final String uri;
  final String displayName;
  final int volId;
  final String password;
  final int pim;
  final List<String> rootFiles;
  final DateTime mountedAt;
  final int totalSpace;
  final int freeSpace;

  const MountedContainer({
    required this.uri,
    required this.displayName,
    required this.volId,
    required this.password,
    required this.pim,
    required this.rootFiles,
    required this.mountedAt,
    required this.totalSpace,
    required this.freeSpace,
  });

  MountedContainer copyWith({
    List<String>? rootFiles,
    int? totalSpace,
    int? freeSpace,
  }) {
    return MountedContainer(
      uri: uri,
      displayName: displayName,
      volId: volId,
      password: password,
      pim: pim,
      rootFiles: rootFiles ?? this.rootFiles,
      mountedAt: mountedAt,
      totalSpace: totalSpace ?? this.totalSpace,
      freeSpace: freeSpace ?? this.freeSpace,
    );
  }
}