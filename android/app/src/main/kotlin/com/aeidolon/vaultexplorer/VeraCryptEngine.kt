package com.aeidolon.vaultexplorer

object VeraCryptEngine {
    init {
        System.loadLibrary("vaultexplorer")
    }

    @JvmStatic
    external fun unlockAndListNative(fd: Int, password: String, pim: Int, volId: Int): Array<String>?

    @JvmStatic
    external fun unlockAndExtractNative(fd: Int, password: String, pim: Int, targetFileName: String, destPath: String, volId: Int): Boolean

    @JvmStatic
    external fun writeBackFileNative(fd: Int, password: String, pim: Int, targetFileName: String, sourcePath: String, volId: Int): Boolean

    @JvmStatic
    external fun deleteFileNative(fd: Int, password: String, pim: Int, targetFileName: String, volId: Int): Boolean

    @JvmStatic
    external fun lockNative(volId: Int)

    @JvmStatic
    external fun getFileSizeNative(fd: Int, password: String, pim: Int, targetFileName: String, volId: Int): Long

    /** Returns the recursive byte total for every file under [dirPath] inside volume [volId]. */
    @JvmStatic
    external fun getFolderSizeNative(fd: Int, password: String, pim: Int, dirPath: String, volId: Int): Long

    @JvmStatic
    external fun readFileChunkNative(fd: Int, password: String, pim: Int, targetFileName: String, offset: Long, length: Int, volId: Int): ByteArray?

    @JvmStatic
    external fun writeFileChunkNative(fd: Int, password: String, pim: Int, targetFileName: String, offset: Long, data: ByteArray, volId: Int): Boolean

    @JvmStatic
    external fun listDirectoryNative(fd: Int, password: String, pim: Int, dirPath: String, volId: Int): Array<String>?

    @JvmStatic
    external fun createDirectoryNative(fd: Int, password: String, pim: Int, dirPath: String, volId: Int): Boolean

    @JvmStatic
    external fun renameFileNative(fd: Int, password: String, pim: Int, oldPath: String, newPath: String, volId: Int): Boolean

    @JvmStatic
    external fun getSpaceInfoNative(fd: Int, password: String, pim: Int, volId: Int): LongArray?

    @JvmStatic
    external fun createContainerNative(fd: Int, password: String, pim: Int, sizeBytes: Long, fileSystem: String): Boolean

    @JvmStatic
    external fun hashPasswordNative(password: String, salt: ByteArray, iterations: Int): ByteArray?

    @JvmStatic
external fun readFileChunkDirectNative(fd: Int, password: String, pim: Int, targetFileName: String, offset: Long, buffer: ByteArray, length: Int, volId: Int): Int

@JvmStatic external fun openStreamNative(fd: Int, password: String, pim: Int, targetFileName: String, volId: Int): Long
@JvmStatic external fun readStreamNative(streamPtr: Long, offset: Long, buffer: ByteArray, length: Int, volId: Int): Int
@JvmStatic external fun closeStreamNative(streamPtr: Long, volId: Int)
}