#include <jni.h>
#include <string>
#include <fstream>
#include <vector>
#include <android/log.h>
#include <iomanip>
#include <sstream>
#include <cstring>
#include <unistd.h>
#include <sys/stat.h>        
#include <memory>
#include <algorithm>

#include "mbedtls/md.h"
#include "mbedtls/pkcs5.h"
#include "mbedtls/aes.h"

#include "ff.h"
#include "diskio.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "VaultExplorer_C++", __VA_ARGS__)
#define MAX_VOLUMES 4

// ----------------------------------------------------------------====
// GLOBAL STATE
// ----------------------------------------------------------------====

static int           activeFd[MAX_VOLUMES]              = {-1, -1, -1, -1};
static uint64_t      activeDataOffset[MAX_VOLUMES]      = {0};
static bool          activeIsRelTweak[MAX_VOLUMES]      = {false};
static bool          isDataCtxInitialized[MAX_VOLUMES]  = {false};

// [FIX 1] Actual file sizes (bytes) — derived from fstat once per prepareSession.
static uint64_t      activeFileSize[MAX_VOLUMES]        = {0, 0, 0, 0};

static mbedtls_aes_xts_context activeDataCtxDec[MAX_VOLUMES];
static mbedtls_aes_xts_context activeDataCtxEnc[MAX_VOLUMES];

static const char* drivePaths[MAX_VOLUMES] = {"0:", "1:", "2:", "3:"};
static FATFS globalFs[MAX_VOLUMES];

// ----------------------------------------------------------------====
// INLINE HELPERS
// ----------------------------------------------------------------====

static inline bool isPrintable(unsigned char c) { return c >= 32 && c <= 126; }

static void sanitizeString(std::string& s) {
    std::replace_if(s.begin(), s.end(),
        [](char c) { return !isPrintable(static_cast<unsigned char>(c)); }, '?');
}

static inline void setTweak(unsigned char* tweak, uint64_t sectorNum) {
    *reinterpret_cast<uint64_t*>(tweak)   = sectorNum;
    *reinterpret_cast<uint64_t*>(tweak+8) = 0ULL;
}

// ----------------------------------------------------------------====
// CRYPTO HELPERS
// ----------------------------------------------------------------====

static void encryptSector(mbedtls_aes_xts_context* ctx, uint64_t sectorNum,
                           const unsigned char* in, unsigned char* out) {
    unsigned char tweak[16];
    setTweak(tweak, sectorNum);
    mbedtls_aes_crypt_xts(ctx, MBEDTLS_AES_ENCRYPT, 512, tweak, in, out);
}

static void decryptSector(mbedtls_aes_xts_context* ctx, uint64_t sectorNum,
                           const unsigned char* in, unsigned char* out) {
    unsigned char tweak[16];
    setTweak(tweak, sectorNum);
    mbedtls_aes_crypt_xts(ctx, MBEDTLS_AES_DECRYPT, 512, tweak, in, out);
}

// ----------------------------------------------------------------====
// FATFS LOW-LEVEL DISK HOOKS
// ----------------------------------------------------------------====

extern "C" DSTATUS disk_initialize(BYTE pdrv) { return 0; }
extern "C" DSTATUS disk_status(BYTE pdrv)     { return 0; }

extern "C" DRESULT disk_read(BYTE pdrv, BYTE* buff, LBA_t sector, UINT count) {
    if (pdrv >= MAX_VOLUMES || activeFd[pdrv] < 0 || !isDataCtxInitialized[pdrv])
        return RES_NOTRDY;

    const uint64_t basePhysical = activeDataOffset[pdrv] / 512;
    const bool relTweak = activeIsRelTweak[pdrv];
    const int fd = activeFd[pdrv];
   const uint64_t firstPhysical = basePhysical + sector;
    const size_t   totalBytes    = static_cast<size_t>(count) * 512;

    std::unique_ptr<unsigned char[]> encBuf(new unsigned char[totalBytes]);

    ssize_t got = pread(fd, encBuf.get(), totalBytes,
                        static_cast<off_t>(firstPhysical * 512));
    if (got < static_cast<ssize_t>(totalBytes)) return RES_ERROR;

    for (UINT i = 0; i < count; i++) {
        const uint64_t physSector = firstPhysical + i;
        const uint64_t tweak      = relTweak ? (physSector - basePhysical) : physSector;
        decryptSector(&activeDataCtxDec[pdrv], tweak,
                      encBuf.get() + (i * 512),
                      buff         + (i * 512));
    }
    return RES_OK;

}

extern "C" DRESULT disk_write(BYTE pdrv, const BYTE* buff, LBA_t sector, UINT count) {
    if (pdrv >= MAX_VOLUMES || activeFd[pdrv] < 0 || !isDataCtxInitialized[pdrv])
        return RES_NOTRDY;

    const uint64_t basePhysical = activeDataOffset[pdrv] / 512;
    const bool relTweak = activeIsRelTweak[pdrv];
    const int fd = activeFd[pdrv];
    const uint64_t firstPhysical = basePhysical + sector;

    static thread_local unsigned char encBuf[512 * 64];

    for (UINT i = 0; i < count; i++) {
        const uint64_t physSector = firstPhysical + i;
        const uint64_t tweak      = relTweak ? (physSector - basePhysical) : physSector;
        encryptSector(&activeDataCtxEnc[pdrv], tweak,
                      buff   + (i * 512),
                      encBuf + (i * 512));
    }

    const size_t totalBytes = static_cast<size_t>(count) * 512;
    ssize_t written = pwrite(fd, encBuf, totalBytes,
                             static_cast<off_t>(firstPhysical * 512));
    return (written == static_cast<ssize_t>(totalBytes)) ? RES_OK : RES_ERROR;
}

extern "C" DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void* buff) {
    switch (cmd) {
        case CTRL_SYNC:
            return RES_OK;

        case GET_SECTOR_COUNT:
            // [FIX 1] Return the real sector count derived from fstat() in
            // prepareSession().  Fall back to a conservative 1 000 000 only
            // if the file size was never stored (should not happen).
            if (pdrv < MAX_VOLUMES && activeFileSize[pdrv] > 0) {
                *(LBA_t*)buff = static_cast<LBA_t>(activeFileSize[pdrv] / 512);
            } else {
                *(LBA_t*)buff = 1000000;
            }
            return RES_OK;

        case GET_SECTOR_SIZE:
            *(WORD*)buff  = 512;
            return RES_OK;

        case GET_BLOCK_SIZE:
            *(DWORD*)buff = 1;
            return RES_OK;
    }
    return RES_PARERR;
}

extern "C" DWORD get_fattime() { return 0; }

// ----------------------------------------------------------------====
// CRYPTO SESSION BUILDER
// ----------------------------------------------------------------====

bool prepareSession(int fd, const char* password, int pim, int volId, bool forceDerive) {
    if (volId >= MAX_VOLUMES) return false;

    if (!forceDerive && isDataCtxInitialized[volId]) {
        // [FIX 1] Refresh file size on each new fd so GET_SECTOR_COUNT stays accurate.
        struct stat st;
        if (fstat(fd, &st) == 0)
            activeFileSize[volId] = static_cast<uint64_t>(st.st_size);
        activeFd[volId] = fd;
        return true;
    }

    LOGI("Running PBKDF2 Key Derivation for Volume %d...", volId);

    unsigned char headerBuf[512];
    if (pread(fd, headerBuf, 512, 0) != 512) return false;

    // [FIX 1] Record the container file size immediately.
    {
        struct stat st;
        if (fstat(fd, &st) == 0)
            activeFileSize[volId] = static_cast<uint64_t>(st.st_size);
    }

    const unsigned char* salt = headerBuf;
    const unsigned char* encH = headerBuf + 64;

    const int iter = (pim > 0) ? (15000 + (pim * 1000)) : 500000;

    mbedtls_md_context_t md_ctx;
    mbedtls_md_init(&md_ctx);
    mbedtls_md_setup(&md_ctx, mbedtls_md_info_from_type(MBEDTLS_MD_SHA512), 1);

    unsigned char hKey[64];
    mbedtls_pkcs5_pbkdf2_hmac(&md_ctx,
        reinterpret_cast<const unsigned char*>(password), strlen(password),
        salt, 64, iter, 64, hKey);
    mbedtls_md_free(&md_ctx);

    unsigned char decH[448];
    {
        mbedtls_aes_xts_context xts;
        mbedtls_aes_xts_init(&xts);
        mbedtls_aes_xts_setkey_dec(&xts, hKey, 512);
        const unsigned char zTw[16] = {0};
        mbedtls_aes_crypt_xts(&xts, MBEDTLS_AES_DECRYPT, 448, zTw, encH, decH);
        mbedtls_aes_xts_free(&xts);
    }

    if (decH[0] != 'V' || decH[1] != 'E' || decH[2] != 'R' || decH[3] != 'A')
        return false;

    const int keyOffsets[] = {252, 192};

    constexpr uint64_t SCAN_SECTORS = 2048;
    constexpr uint64_t BATCH        = 64;

    unsigned char dKey[64];
    bool fsFound = false;

    mbedtls_aes_xts_context tmpDec, tmpEnc;
    mbedtls_aes_xts_init(&tmpDec);
    mbedtls_aes_xts_init(&tmpEnc);

    std::unique_ptr<unsigned char[]> encBatch(new unsigned char[BATCH * 512]);
    unsigned char decS[512];
    unsigned char tweak[16];

    for (int kOff : keyOffsets) {
        memcpy(dKey, &decH[kOff], 64);
        mbedtls_aes_xts_setkey_dec(&tmpDec, dKey, 512);

        uint64_t s = 0;
        while (s < SCAN_SECTORS && !fsFound) {
            const uint64_t batchCount = std::min(BATCH, SCAN_SECTORS - s);
            const ssize_t  batchBytes = static_cast<ssize_t>(batchCount * 512);

            if (pread(fd, encBatch.get(), batchBytes, static_cast<off_t>(s * 512)) != batchBytes)
                break;

            for (uint64_t i = 0; i < batchCount && !fsFound; i++) {
                const uint64_t sectorIdx = s + i;
                const unsigned char* enc = encBatch.get() + (i * 512);

                // Absolute tweak
                setTweak(tweak, sectorIdx);
                mbedtls_aes_crypt_xts(&tmpDec, MBEDTLS_AES_DECRYPT, 512, tweak, enc, decS);
                if (decS[510] == 0x55 && decS[511] == 0xAA) {
                    activeDataOffset[volId] = sectorIdx * 512;
                    activeIsRelTweak[volId] = false;
                    fsFound = true;
                    break;
                }

                // Relative tweak
                memset(tweak, 0, 16);
                mbedtls_aes_crypt_xts(&tmpDec, MBEDTLS_AES_DECRYPT, 512, tweak, enc, decS);
                if (decS[510] == 0x55 && decS[511] == 0xAA) {
                    activeDataOffset[volId] = sectorIdx * 512;
                    activeIsRelTweak[volId] = true;
                    fsFound = true;
                    break;
                }
            }
            s += batchCount;
        }
        if (fsFound) break;
    }

    if (!fsFound) {
        mbedtls_aes_xts_free(&tmpDec);
        mbedtls_aes_xts_free(&tmpEnc);
        return false;
    }

    mbedtls_aes_xts_setkey_enc(&tmpEnc, dKey, 512);

    if (isDataCtxInitialized[volId]) {
        mbedtls_aes_xts_free(&activeDataCtxDec[volId]);
        mbedtls_aes_xts_free(&activeDataCtxEnc[volId]);
    }
    activeDataCtxDec[volId] = tmpDec;
    activeDataCtxEnc[volId] = tmpEnc;
    isDataCtxInitialized[volId] = true;
    activeFd[volId] = fd;

    return true;
}

// ----------------------------------------------------------------====
// SHARED: directory listing
// ----------------------------------------------------------------====

static jobjectArray buildDirectoryListing(JNIEnv* env, int volId, const char* pathSuffix) {
    std::vector<std::string> results;
    std::string fullPath = drivePaths[volId];
    if (pathSuffix && pathSuffix[0] != '\0') {
        fullPath += '/';
        fullPath += pathSuffix;
    }

    DIR dir;
    FILINFO fno;
    if (f_opendir(&dir, fullPath.c_str()) == FR_OK) {
        while (f_readdir(&dir, &fno) == FR_OK && fno.fname[0]) {
            const char* name = fno.fname;
            if (strcmp(name, "SYSTEM~1") == 0 || strcmp(name, "$RECYCLE.BIN") == 0)
                continue;
            if (fno.fattrib & AM_DIR) {
                std::string entry = "[DIR] ";
                entry += name;
                results.push_back(std::move(entry));
            } else {
                std::string entry = name;
                entry += '|';
                entry += std::to_string(fno.fsize);
                results.push_back(std::move(entry));
            }
        }
        f_closedir(&dir);
    }

    jclass strClass = env->FindClass("java/lang/String");
    jobjectArray retArr = env->NewObjectArray(
        static_cast<jsize>(results.size()), strClass, nullptr);
    for (size_t i = 0; i < results.size(); i++) {
        sanitizeString(results[i]);
        jstring js = env->NewStringUTF(results[i].c_str());
        env->SetObjectArrayElement(retArr, i, js);
        env->DeleteLocalRef(js);
    }
    return retArr;
}

// ----------------------------------------------------------------====
// JNI API
// ----------------------------------------------------------------====

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_unlockAndListNative(
        JNIEnv* env, jobject, jint fd, jstring password, jint pim, jint volId) {

    const char* nativePass = env->GetStringUTFChars(password, nullptr);

    if (!prepareSession(fd, nativePass, pim, volId, true)) {
        env->ReleaseStringUTFChars(password, nativePass);
        close(fd);
        return nullptr;   // Authentication failure — caller throws AUTH_FAIL.
    }

    jobjectArray result = nullptr;
    FRESULT fr = f_mount(&globalFs[volId], drivePaths[volId], 1);
    if (fr == FR_OK) {
        result = buildDirectoryListing(env, volId, nullptr);
        f_mount(nullptr, drivePaths[volId], 0);
    } else {
        // [FIX 2] Return nullptr so Kotlin treats this as AUTH_FAIL, not a
        // successful unlock with a bogus file list.
        LOGI("FATFS Mount failed on volume %d, code=%d", volId, fr);
        result = nullptr;
    }

    env->ReleaseStringUTFChars(password, nativePass);
    close(fd);
    return result;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_unlockAndExtractNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim,
        jstring targetFileName, jstring destPath, jint volId) {

    const char* nativePass  = env->GetStringUTFChars(password, nullptr);
    const char* targetName  = env->GetStringUTFChars(targetFileName, nullptr);
    const char* destination = env->GetStringUTFChars(destPath, nullptr);

    bool success = false;
    if (prepareSession(fd, nativePass, pim, volId, false)) {
        if (f_mount(&globalFs[volId], drivePaths[volId], 1) == FR_OK) {
            FIL f;
            std::string fatPath = std::string(drivePaths[volId]) + "/" + targetName;
            if (f_open(&f, fatPath.c_str(), FA_READ) == FR_OK) {
                std::ofstream outFile(destination, std::ios::binary);
                if (outFile.is_open()) {
                    std::unique_ptr<unsigned char[]> buf(new unsigned char[262144]);
                    UINT br;
                    while (f_read(&f, buf.get(), 262144, &br) == FR_OK && br > 0)
                        outFile.write(reinterpret_cast<char*>(buf.get()), br);
                    success = true;
                }
                f_close(&f);
            }
            f_mount(nullptr, drivePaths[volId], 0);
        }
    }

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(targetFileName, targetName);
    env->ReleaseStringUTFChars(destPath, destination);
    close(fd);
    return success ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_writeBackFileNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim,
        jstring targetFileName, jstring sourcePath, jint volId) {

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    const char* targetName = env->GetStringUTFChars(targetFileName, nullptr);
    const char* source     = env->GetStringUTFChars(sourcePath, nullptr);

    bool success = false;
    if (prepareSession(fd, nativePass, pim, volId, false)) {
        if (f_mount(&globalFs[volId], drivePaths[volId], 1) == FR_OK) {
            FIL f;
            std::string fatPath = std::string(drivePaths[volId]) + "/" + targetName;
            if (f_open(&f, fatPath.c_str(), FA_WRITE | FA_CREATE_ALWAYS) == FR_OK) {
                std::ifstream inFile(source, std::ios::binary);
                if (inFile.is_open()) {
                    std::unique_ptr<char[]> buf(new char[262144]);
                    UINT bw;
                    while (inFile) {
                        inFile.read(buf.get(), 262144);
                        std::streamsize n = inFile.gcount();
                        if (n > 0) f_write(&f, buf.get(), static_cast<UINT>(n), &bw);
                    }
                    success = true;
                }
                f_close(&f);
            }
            f_mount(nullptr, drivePaths[volId], 0);
        }
    }

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(targetFileName, targetName);
    env->ReleaseStringUTFChars(sourcePath, source);
    close(fd);
    return success ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_deleteFileNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim,
        jstring targetFileName, jint volId) {

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    const char* targetName = env->GetStringUTFChars(targetFileName, nullptr);

    bool success = false;
    if (prepareSession(fd, nativePass, pim, volId, false)) {
        if (f_mount(&globalFs[volId], drivePaths[volId], 1) == FR_OK) {
            std::string fatPath = std::string(drivePaths[volId]) + "/" + targetName;
            success = (f_unlink(fatPath.c_str()) == FR_OK);
            f_mount(nullptr, drivePaths[volId], 0);
        }
    }

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(targetFileName, targetName);
    close(fd);
    return success ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_lockNative(JNIEnv*, jobject, jint volId) {
    if (volId >= MAX_VOLUMES) return;

    activeFd[volId]         = -1;
    activeDataOffset[volId] = 0;
    activeIsRelTweak[volId] = false;
    activeFileSize[volId]   = 0;  // [FIX 3] Clear stale file-size.

    if (isDataCtxInitialized[volId]) {
        mbedtls_aes_xts_free(&activeDataCtxDec[volId]);
        mbedtls_aes_xts_free(&activeDataCtxEnc[volId]);
        isDataCtxInitialized[volId] = false;
    }

    f_mount(nullptr, drivePaths[volId], 0);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_getFileSizeNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim,
        jstring targetFileName, jint volId) {

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    const char* targetName = env->GetStringUTFChars(targetFileName, nullptr);

    jlong size = 0;
    if (prepareSession(fd, nativePass, pim, volId, false)) {
        if (f_mount(&globalFs[volId], drivePaths[volId], 1) == FR_OK) {
            FIL f;
            std::string fatPath = std::string(drivePaths[volId]) + "/" + targetName;
            if (f_open(&f, fatPath.c_str(), FA_READ) == FR_OK) {
                size = static_cast<jlong>(f_size(&f));
                f_close(&f);
            }
            f_mount(nullptr, drivePaths[volId], 0);
        }
    }

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(targetFileName, targetName);
    close(fd);
    return size;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_readFileChunkNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim,
        jstring targetFileName, jlong offset, jint length, jint volId) {

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    const char* targetName = env->GetStringUTFChars(targetFileName, nullptr);

    jbyteArray retArray = nullptr;
    if (prepareSession(fd, nativePass, pim, volId, false)) {
        if (f_mount(&globalFs[volId], drivePaths[volId], 1) == FR_OK) {
            FIL f;
            std::string fatPath = std::string(drivePaths[volId]) + "/" + targetName;
            if (f_open(&f, fatPath.c_str(), FA_READ) == FR_OK) {
                f_lseek(&f, static_cast<FSIZE_t>(offset));
                std::unique_ptr<unsigned char[]> buffer(new unsigned char[length]);
                UINT br = 0;
                if (f_read(&f, buffer.get(), static_cast<UINT>(length), &br) == FR_OK && br > 0) {
                    retArray = env->NewByteArray(static_cast<jsize>(br));
                    env->SetByteArrayRegion(retArray, 0, static_cast<jsize>(br),
                                            reinterpret_cast<jbyte*>(buffer.get()));
                }
                f_close(&f);
            }
            f_mount(nullptr, drivePaths[volId], 0);
        }
    }

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(targetFileName, targetName);
    close(fd);
    return retArray;
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_listDirectoryNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim, jstring dirPath, jint volId) {

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    const char* nativePath = env->GetStringUTFChars(dirPath, nullptr);

    jobjectArray result = nullptr;
    if (prepareSession(fd, nativePass, pim, volId, false)) {
        if (f_mount(&globalFs[volId], drivePaths[volId], 1) == FR_OK) {
            result = buildDirectoryListing(env, volId, nativePath);
            f_mount(nullptr, drivePaths[volId], 0);
        }
    }

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(dirPath, nativePath);
    close(fd);
    return result;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_createDirectoryNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim, jstring dirPath, jint volId) {

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    const char* nativePath = env->GetStringUTFChars(dirPath, nullptr);

    bool success = false;
    if (prepareSession(fd, nativePass, pim, volId, false)) {
        if (f_mount(&globalFs[volId], drivePaths[volId], 1) == FR_OK) {
            std::string fullPath = std::string(drivePaths[volId]) + "/" + nativePath;
            success = (f_mkdir(fullPath.c_str()) == FR_OK);
            f_mount(nullptr, drivePaths[volId], 0);
        }
    }

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(dirPath, nativePath);
    close(fd);
    return success ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_renameFileNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim,
        jstring oldPath, jstring newPath, jint volId) {

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    const char* nativeOld  = env->GetStringUTFChars(oldPath, nullptr);
    const char* nativeNew  = env->GetStringUTFChars(newPath, nullptr);

    bool success = false;
    if (prepareSession(fd, nativePass, pim, volId, false)) {
        if (f_mount(&globalFs[volId], drivePaths[volId], 1) == FR_OK) {
            std::string fullOld = std::string(drivePaths[volId]) + "/" + nativeOld;
            std::string fullNew = std::string(drivePaths[volId]) + "/" + nativeNew;
            success = (f_rename(fullOld.c_str(), fullNew.c_str()) == FR_OK);
            f_mount(nullptr, drivePaths[volId], 0);
        }
    }

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(oldPath, nativeOld);
    env->ReleaseStringUTFChars(newPath, nativeNew);
    close(fd);
    return success ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_getSpaceInfoNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim, jint volId) {

    const char* nativePass = env->GetStringUTFChars(password, nullptr);

    jlong totalBytes = 0, freeBytes = 0;
    if (prepareSession(fd, nativePass, pim, volId, false)) {
        if (f_mount(&globalFs[volId], drivePaths[volId], 1) == FR_OK) {
            FATFS* fs;
            DWORD fre_clust;
            if (f_getfree(drivePaths[volId], &fre_clust, &fs) == FR_OK) {
                totalBytes = static_cast<jlong>(fs->n_fatent - 2) * fs->csize * 512;
                freeBytes  = static_cast<jlong>(fre_clust)        * fs->csize * 512;
            }
            f_mount(nullptr, drivePaths[volId], 0);
        }
    }

    env->ReleaseStringUTFChars(password, nativePass);
    close(fd);

    jlongArray ret = env->NewLongArray(2);
    const jlong tmp[2] = {totalBytes, freeBytes};
    env->SetLongArrayRegion(ret, 0, 2, tmp);
    return ret;
}