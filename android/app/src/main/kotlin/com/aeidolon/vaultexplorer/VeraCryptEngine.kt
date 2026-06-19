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

    @JvmStatic
    external fun readFileChunkNative(fd: Int, password: String, pim: Int, targetFileName: String, offset: Long, length: Int, volId: Int): ByteArray?

    @JvmStatic
    external fun listDirectoryNative(fd: Int, password: String, pim: Int, dirPath: String, volId: Int): Array<String>?

    @JvmStatic
    external fun createDirectoryNative(fd: Int, password: String, pim: Int, dirPath: String, volId: Int): Boolean

    @JvmStatic
    external fun renameFileNative(fd: Int, password: String, pim: Int, oldPath: String, newPath: String, volId: Int): Boolean

    @JvmStatic
    external fun getSpaceInfoNative(fd: Int, password: String, pim: Int, volId: Int): LongArray?
}