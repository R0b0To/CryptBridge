package com.example.cryptbridge

object VeraCryptEngine {
    init {
        System.loadLibrary("cryptbridge")
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
    external fun lockNative(volId: Int) // New unmount method
}