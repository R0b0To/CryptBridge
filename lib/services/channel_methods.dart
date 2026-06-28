/// Single source of truth for every MethodChannel method name.
///
/// Both [VaultExplorerApi] call-sites and [MainActivity]'s `when` block must
/// use these constants.  The Kotlin side mirrors them in the local
/// [ChannelMethods] object inside [MainActivity].
abstract final class ChannelMethods {
  // ── Container lifecycle ──────────────────────────────────────────────────
  static const pickContainer   = 'pickContainer';
  static const createContainer = 'createContainer';
  static const unlockContainer = 'unlockContainer';
  static const lockContainer   = 'lockContainer';

  // ── File I/O ─────────────────────────────────────────────────────────────
  static const decryptFile         = 'decryptFile';
  static const exportFileToStorage = 'exportFileToStorage';
  static const exportFilesToFolder = 'exportFilesToFolder';
  static const importFile          = 'importFile';
  static const importFolder        = 'importFolder';
  static const getFileSize         = 'getFileSize';
  static const getFolderSize       = 'getFolderSize'; // recursive directory byte total
  static const readFileChunk       = 'readFileChunk';
  static const writeBackFile       = 'writeBackFile';
  static const getSpaceInfo        = 'getSpaceInfo';

  // ── Directory operations ─────────────────────────────────────────────────
  static const listDirectory   = 'listDirectory';
  static const createDirectory = 'createDirectory';
  static const renameFile      = 'renameFile';
  static const deleteFile      = 'deleteFile';

  // ── Media ────────────────────────────────────────────────────────────────
  static const openWithApp       = 'openWithApp';
  static const getVideoThumbnail = 'getVideoThumbnail';

  // ── Crypto ───────────────────────────────────────────────────────────────
  /// PBKDF2-SHA512 via the C++ mbedTLS layer.
  static const hashPassword = 'hashPassword';
}