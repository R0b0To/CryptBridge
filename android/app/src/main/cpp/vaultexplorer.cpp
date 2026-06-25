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

static int           activeFd[MAX_VOLUMES];
static uint64_t      activeDataOffset[MAX_VOLUMES];
static bool          activeIsRelTweak[MAX_VOLUMES];
static bool          isDataCtxInitialized[MAX_VOLUMES];
static uint64_t      activeFileSize[MAX_VOLUMES];

static bool           fsMounted[MAX_VOLUMES];

static mbedtls_aes_xts_context activeDataCtxDec[MAX_VOLUMES];
static mbedtls_aes_xts_context activeDataCtxEnc[MAX_VOLUMES];

// Drive paths for up to 4 volumes — FatFs uses single-digit drive numbers.
static const char* drivePaths[MAX_VOLUMES] = {
    "0:", "1:", "2:", "3:"
};
static FATFS globalFs[MAX_VOLUMES];

// One-time initialiser so the arrays start in a known state.
static bool _globalInit = [](){
    for (int i = 0; i < MAX_VOLUMES; i++) {
        activeFd[i]               = -1;
        activeDataOffset[i]       = 0;
        activeIsRelTweak[i]       = false;
        isDataCtxInitialized[i]   = false;
        activeFileSize[i]         = 0;
        fsMounted[i]               = false;
    }
    return true;
}();

// ----------------------------------------------------------------====
// MOUNT CACHE HELPERS
// ----------------------------------------------------------------====

// Mounts the FatFs volume for `volId` only if it isn't already mounted.
// Must be called *after* prepareSession() so activeFd[volId] (used by the
// disk_read/disk_write hooks below) is valid at mount time.
static bool ensureMounted(int volId) {
    if (volId < 0 || volId >= MAX_VOLUMES) return false;
    if (fsMounted[volId]) return true;

    FRESULT fr = f_mount(&globalFs[volId], drivePaths[volId], 1);
    if (fr == FR_OK) {
        fsMounted[volId] = true;
        return true;
    }
    LOGI("ensureMounted: f_mount failed for volume %d, code=%d", volId, (int)fr);
    return false;
}

static void unmountVolume(int volId) {
    if (volId < 0 || volId >= MAX_VOLUMES) return;
    if (fsMounted[volId]) {
        f_mount(nullptr, drivePaths[volId], 0);
        fsMounted[volId] = false;
    }
}

// ----------------------------------------------------------------====
// INLINE HELPERS
// ----------------------------------------------------------------====

// Strips only genuinely unsafe control characters (and DEL). Bytes >= 0x80
// are left untouched because they are valid lead/continuation bytes of
// multi-byte UTF-8 sequences — FatFs is now configured for native UTF-8
// long file names (FF_LFN_UNICODE=2 in ffconf.h), so stripping them used to
// silently corrupt every accented/CJK/emoji file name byte-by-byte
// (review issue #3).
static inline bool isUnsafeControlChar(unsigned char c) {
    return c < 32 || c == 127;
}

static void sanitizeString(std::string& s) {
    std::replace_if(s.begin(), s.end(), isUnsafeControlChar, '?');
}

static inline void setTweak(unsigned char* tweak, uint64_t sectorNum) {
    *reinterpret_cast<uint64_t*>(tweak)   = sectorNum;
    *reinterpret_cast<uint64_t*>(tweak+8) = 0ULL;
}

// Clamps a user/JNI-supplied PIM to a sane, bounded range. An unclamped
// negative or huge PIM either silently fell back to the (already safe)
// default, or could otherwise be abused to request an absurd number of
// PBKDF2 iterations; we bound it defensively here regardless of what the
// Dart layer already validates.
static inline int clampPim(int pim) {
    if (pim < 0) return 0;
    if (pim > 2000) return 2000;
    return pim;
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
    // Sanity-cap: FatFs never legitimately issues > 8192 sectors in one call.
    if (count == 0 || count > 8192) return RES_PARERR;

    const uint64_t basePhysical = activeDataOffset[pdrv] / 512;
    const bool     relTweak     = activeIsRelTweak[pdrv];
    const int      fd           = activeFd[pdrv];
    const uint64_t firstPhysical = basePhysical + sector;
    const size_t   totalBytes    = static_cast<size_t>(count) * 512;

    // FIX: replaced static thread_local fixed-size stack buffer (32 KB, overflow for count > 64)
    // with heap allocation sized exactly to the request.
    std::unique_ptr<unsigned char[]> encBuf(new unsigned char[totalBytes]);

    for (UINT i = 0; i < count; i++) {
        const uint64_t physSector = firstPhysical + i;
        const uint64_t tweak      = relTweak ? (physSector - basePhysical) : physSector;
        encryptSector(&activeDataCtxEnc[pdrv], tweak,
                      buff        + (i * 512),
                      encBuf.get() + (i * 512));
    }

    ssize_t written = pwrite(fd, encBuf.get(), totalBytes,
                             static_cast<off_t>(firstPhysical * 512));
    return (written == static_cast<ssize_t>(totalBytes)) ? RES_OK : RES_ERROR;
}

extern "C" DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void* buff) {
    switch (cmd) {
        case CTRL_SYNC:
            return RES_OK;

        case GET_SECTOR_COUNT:
            if (pdrv < MAX_VOLUMES && activeFileSize[pdrv] > 262144) {
                *(LBA_t*)buff = static_cast<LBA_t>((activeFileSize[pdrv] - 262144) / 512);
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
        struct stat st;
        if (fstat(fd, &st) == 0)
            activeFileSize[volId] = static_cast<uint64_t>(st.st_size);
        activeFd[volId] = fd;
        return true;
    }

    LOGI("Running PBKDF2 Key Derivation for Volume %d...", volId);

    unsigned char headerBuf[512];
    if (pread(fd, headerBuf, 512, 0) != 512) return false;

    {
        struct stat st;
        if (fstat(fd, &st) == 0)
            activeFileSize[volId] = static_cast<uint64_t>(st.st_size);
    }

    const unsigned char* salt = headerBuf;
    const unsigned char* encH = headerBuf + 64;

    const int safePim = clampPim(pim);
    const int iter = (safePim > 0) ? (15000 + (safePim * 1000)) : 500000;

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

                setTweak(tweak, sectorIdx);
                mbedtls_aes_crypt_xts(&tmpDec, MBEDTLS_AES_DECRYPT, 512, tweak, enc, decS);
                if (decS[510] == 0x55 && decS[511] == 0xAA) {
                    activeDataOffset[volId] = sectorIdx * 512;
                    activeIsRelTweak[volId] = false;
                    fsFound = true;
                    break;
                }

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
        mbedtls_platform_zeroize(hKey, sizeof(hKey));
        mbedtls_platform_zeroize(dKey, sizeof(dKey));
        mbedtls_platform_zeroize(decH, sizeof(decH));
        return false;
    }

    mbedtls_aes_xts_setkey_enc(&tmpEnc, dKey, 512);

    mbedtls_platform_zeroize(hKey, sizeof(hKey));
    mbedtls_platform_zeroize(dKey, sizeof(dKey));
    mbedtls_platform_zeroize(decH, sizeof(decH));

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
        return nullptr;
    }

    jobjectArray result = nullptr;
    if (ensureMounted(volId)) {
        // Left mounted intentionally — subsequent calls for this volId
        // (listDirectory, readFileChunk, etc.) reuse the mount instead of
        // re-parsing the FAT/exFAT volume metadata every time. Only
        // lockNative() unmounts.
        result = buildDirectoryListing(env, volId, nullptr);
    } else {
        LOGI("FATFS Mount failed on volume %d", volId);
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
        if (ensureMounted(volId)) {
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
        if (ensureMounted(volId)) {
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
        if (ensureMounted(volId)) {
            std::string fatPath = std::string(drivePaths[volId]) + "/" + targetName;
            success = (f_unlink(fatPath.c_str()) == FR_OK);
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
    activeFileSize[volId]   = 0;

    if (isDataCtxInitialized[volId]) {
        mbedtls_aes_xts_free(&activeDataCtxDec[volId]);
        mbedtls_aes_xts_free(&activeDataCtxEnc[volId]);
        isDataCtxInitialized[volId] = false;
    }

    // Only place a volume actually gets unmounted now that mounts are
    // cached for the life of the session (see ensureMounted()/issue #6).
    unmountVolume(volId);
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
        if (ensureMounted(volId)) {
            FIL f;
            std::string fatPath = std::string(drivePaths[volId]) + "/" + targetName;
            if (f_open(&f, fatPath.c_str(), FA_READ) == FR_OK) {
                size = static_cast<jlong>(f_size(&f));
                f_close(&f);
            }
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
        // This is the hot path for video/image streaming — previously every
        // single chunk read remounted the whole FAT/exFAT volume. Now the
        // mount is reused for the entire session (issue #6).
        if (ensureMounted(volId)) {
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
        if (ensureMounted(volId)) {
            result = buildDirectoryListing(env, volId, nativePath);
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
        if (ensureMounted(volId)) {
            std::string fullPath = std::string(drivePaths[volId]) + "/" + nativePath;
            success = (f_mkdir(fullPath.c_str()) == FR_OK);
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
        if (ensureMounted(volId)) {
            std::string fullOld = std::string(drivePaths[volId]) + "/" + nativeOld;
            std::string fullNew = std::string(drivePaths[volId]) + "/" + nativeNew;
            success = (f_rename(fullOld.c_str(), fullNew.c_str()) == FR_OK);
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
        if (ensureMounted(volId)) {
            FATFS* fs;
            DWORD fre_clust;
            if (f_getfree(drivePaths[volId], &fre_clust, &fs) == FR_OK) {
                totalBytes = static_cast<jlong>(fs->n_fatent - 2) * fs->csize * 512;
                freeBytes  = static_cast<jlong>(fre_clust)        * fs->csize * 512;
            }
        }
    }

    env->ReleaseStringUTFChars(password, nativePass);
    close(fd);

    jlongArray ret = env->NewLongArray(2);
    const jlong tmp[2] = {totalBytes, freeBytes};
    env->SetLongArrayRegion(ret, 0, 2, tmp);
    return ret;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_createContainerNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim, jlong sizeBytes, jstring fileSystem) {

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    const char* nativeFS   = env->GetStringUTFChars(fileSystem, nullptr);

    bool success = false;
    unsigned char salt[64]              = {0};
    unsigned char combinedMasterKey[64] = {0};

    do {
        if (sizeBytes < static_cast<jlong>(300 * 1024)) {
            LOGI("createContainer: sizeBytes too small (%lld)", (long long)sizeBytes);
            break;
        }

        // Find a free volume slot
        int volId = -1;
        for (int i = 0; i < MAX_VOLUMES; i++) {
            if (activeFd[i] < 0) { volId = i; break; }
        }
        if (volId == -1) {
            LOGI("createContainer: no free slots available");
            break;
        }

        {
            FILE* urnd = fopen("/dev/urandom", "rb");
            if (!urnd) { LOGI("createContainer: cannot open /dev/urandom"); break; }
            bool ok = (fread(salt,              1, 64, urnd) == 64) &&
                      (fread(combinedMasterKey, 1, 64, urnd) == 64);
            fclose(urnd);
            if (!ok) { LOGI("createContainer: urandom read failed"); break; }
        }

        const int safePim = clampPim(pim);
        const int iter = (safePim > 0) ? (15000 + safePim * 1000) : 500000;

        mbedtls_md_context_t md_ctx;
        mbedtls_md_init(&md_ctx);
        if (mbedtls_md_setup(&md_ctx,
                mbedtls_md_info_from_type(MBEDTLS_MD_SHA512), 1) != 0) {
            mbedtls_md_free(&md_ctx);
            LOGI("createContainer: mbedtls_md_setup failed");
            break;
        }

        unsigned char headerKey[64] = {0};
        mbedtls_pkcs5_pbkdf2_hmac(&md_ctx,
            reinterpret_cast<const unsigned char*>(nativePass), strlen(nativePass),
            salt, 64,
            static_cast<unsigned int>(iter),
            64, headerKey);
        mbedtls_md_free(&md_ctx);

        const uint64_t DATA_OFFSET = 131072ULL;
        const uint64_t VOLUME_SIZE = static_cast<uint64_t>(sizeBytes);
        const uint64_t DATA_SIZE   = VOLUME_SIZE - (2 * DATA_OFFSET);

        unsigned char body[448];
        memset(body, 0, sizeof(body));

        // ASCII magic
        body[0] = 'V'; body[1] = 'E'; body[2] = 'R'; body[3] = 'A';
        
        // Volume header format version (2 for standard VeraCrypt)
        body[4] = 0x00; body[5] = 0x02;
        
        // Minimum program version required (0x010b = 267 for VeraCrypt 1.11+)
        body[6] = 0x01; body[7] = 0x0b;

        // Volume size in bytes (Sector offset 100 -> body[36..43])
        for (int i = 7; i >= 0; --i)
            body[36 + (7 - i)] = (VOLUME_SIZE >> (i * 8)) & 0xFF;

        // Start offset of master key scope (Sector offset 108 -> body[44..51])
        for (int i = 7; i >= 0; --i)
            body[44 + (7 - i)] = (DATA_OFFSET >> (i * 8)) & 0xFF;

        // Encrypted area size within master key scope (Sector offset 116 -> body[52..59])
        for (int i = 7; i >= 0; --i)
            body[52 + (7 - i)] = (DATA_SIZE >> (i * 8)) & 0xFF;

        // Sector size (512 bytes) (Sector offset 128 -> body[64..67])
        body[64] = 0x00;
        body[65] = 0x00;
        body[66] = 0x02;
        body[67] = 0x00;

        // Master keys start at sector offset 256 (body[192..255])
        memcpy(&body[192], combinedMasterKey, 64);

        auto crc32 = [](const unsigned char* data, size_t len) -> uint32_t {
            uint32_t crc = 0xFFFFFFFFu;
            for (size_t i = 0; i < len; ++i) {
                crc ^= data[i];
                for (int b = 0; b < 8; ++b)
                    crc = (crc >> 1) ^ (0xEDB88320u & ~((crc & 1) - 1));
            }
            return crc ^ 0xFFFFFFFFu;
        };

        // Key CRC at sector offset 72 (body[8..11]) covers decrypted bytes 256-511 (body[192..447], size 256)
        uint32_t keyCrc = crc32(&body[192], 256);
        body[ 8] = (keyCrc >> 24) & 0xFF; 
        body[ 9] = (keyCrc >> 16) & 0xFF;
        body[10] = (keyCrc >>  8) & 0xFF; 
        body[11] = (keyCrc      ) & 0xFF;

        // Header CRC at sector offset 252 (body[188..191]) covers decrypted bytes 64-251 (body[0..187], size 188)
        uint32_t hdrCrc = crc32(body, 188);
        body[188] = (hdrCrc >> 24) & 0xFF; 
        body[189] = (hdrCrc >> 16) & 0xFF;
        body[190] = (hdrCrc >>  8) & 0xFF; 
        body[191] = (hdrCrc      ) & 0xFF;

        unsigned char encBody[448];
        {
            mbedtls_aes_xts_context xtsHdr;
            mbedtls_aes_xts_init(&xtsHdr);
            mbedtls_aes_xts_setkey_enc(&xtsHdr, headerKey, 512);
            const unsigned char zeroTweak[16] = {0};
            mbedtls_aes_crypt_xts(&xtsHdr, MBEDTLS_AES_ENCRYPT, 448, zeroTweak, body, encBody);
            mbedtls_aes_xts_free(&xtsHdr);
        }

        unsigned char hdrSector[512];
        memcpy(hdrSector,      salt,    64);
        memcpy(hdrSector + 64, encBody, 448);

        if (pwrite(fd, hdrSector, 512, 0) != 512) {
            LOGI("createContainer: primary header write failed"); break;
        }
        if (pwrite(fd, hdrSector, 512, static_cast<off_t>(VOLUME_SIZE - DATA_OFFSET)) != 512) {
            LOGI("createContainer: backup header write failed"); break;
        }

        {
            mbedtls_aes_xts_context xtsData;
            mbedtls_aes_xts_init(&xtsData);
            mbedtls_aes_xts_setkey_enc(&xtsData, combinedMasterKey, 512);

            const uint64_t START_SECTOR  = DATA_OFFSET / 512;
            const uint64_t TOTAL_SECTORS = (VOLUME_SIZE - DATA_OFFSET) / 512;
            const uint64_t BATCH = 64;

            const unsigned char ZERO_SECTOR[512] = {0};
            std::unique_ptr<unsigned char[]> batch(new unsigned char[512 * BATCH]);
            unsigned char tweak[16];
            bool writeOk = true;

            for (uint64_t s = START_SECTOR; s < TOTAL_SECTORS && writeOk; ) {
                const uint64_t rem   = TOTAL_SECTORS - s;
                const uint64_t count = (rem < BATCH) ? rem : BATCH;

                for (uint64_t i = 0; i < count; ++i) {
                    setTweak(tweak, s + i);
                    mbedtls_aes_crypt_xts(&xtsData, MBEDTLS_AES_ENCRYPT,
                                          512, tweak, ZERO_SECTOR, batch.get() + i * 512);
                }

                const ssize_t want = static_cast<ssize_t>(count * 512);
                if (pwrite(fd, batch.get(), want, static_cast<off_t>(s * 512)) != want) {
                    LOGI("createContainer: data fill write failed at sector %llu",
                         (unsigned long long)s);
                    writeOk = false;
                }
                s += count;
            }
            mbedtls_aes_xts_free(&xtsData);
            if (!writeOk) break;
        }

        fsync(fd);

        {
            if (isDataCtxInitialized[volId]) {
                mbedtls_aes_xts_free(&activeDataCtxDec[volId]);
                mbedtls_aes_xts_free(&activeDataCtxEnc[volId]);
            }
            mbedtls_aes_xts_init(&activeDataCtxDec[volId]);
            mbedtls_aes_xts_init(&activeDataCtxEnc[volId]);
            mbedtls_aes_xts_setkey_dec(&activeDataCtxDec[volId], combinedMasterKey, 512);
            mbedtls_aes_xts_setkey_enc(&activeDataCtxEnc[volId], combinedMasterKey, 512);
            isDataCtxInitialized[volId] = true;
            activeFd[volId]             = fd;
            activeDataOffset[volId]     = DATA_OFFSET;
            activeIsRelTweak[volId]     = false;
            activeFileSize[volId]       = VOLUME_SIZE;

            const bool useExFat = (strncasecmp(nativeFS, "exfat", 5) == 0);

            MKFS_PARM mp;
            memset(&mp, 0, sizeof(mp));
            mp.fmt    = useExFat ? FM_EXFAT : FM_FAT;
            mp.n_fat  = 1;
            mp.n_root = 512;
            mp.au_size = 0;
            mp.align   = 0;

            alignas(16) unsigned char mkfsBuf[4096];
            FRESULT fr = f_mkfs(drivePaths[volId], &mp, mkfsBuf, sizeof(mkfsBuf));

            LOGI("createContainer: f_mkfs result=%d fmt=%d exfat=%d",
                 (int)fr, (int)mp.fmt, (int)useExFat);

            // This volume slot is not part of the persistent-mount session
            // cache (fsMounted[] was never set for it via ensureMounted),
            // so we unmount it directly here regardless of that tracking.
            f_mount(nullptr, drivePaths[volId], 0);
            activeFd[volId]           = -1;
            activeDataOffset[volId]   = 0;
            activeIsRelTweak[volId]   = false;
            activeFileSize[volId]     = 0;
            mbedtls_aes_xts_free(&activeDataCtxDec[volId]);
            mbedtls_aes_xts_free(&activeDataCtxEnc[volId]);
            isDataCtxInitialized[volId] = false;

            if (fr != FR_OK) {
                LOGI("createContainer: f_mkfs failed, code=%d", (int)fr);
                break;
            }
        }

        success = true;
        LOGI("createContainer: complete – %lld bytes, fs=%s",
             (long long)sizeBytes, nativeFS);

    } while (false);

    volatile unsigned char* vp = combinedMasterKey;
    for (size_t i = 0; i < sizeof(combinedMasterKey); ++i) vp[i] = 0;

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(fileSystem, nativeFS);
    close(fd);

    return success ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_writeFileChunkNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim,
        jstring targetFileName, jlong offset, jbyteArray data, jint volId) {

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    const char* targetName = env->GetStringUTFChars(targetFileName, nullptr);

    jsize len = env->GetArrayLength(data);
    jbyte* body = env->GetByteArrayElements(data, nullptr);

    bool success = false;
    if (prepareSession(fd, nativePass, pim, volId, false)) {
        if (ensureMounted(volId)) {
            FIL f;
            std::string fatPath = std::string(drivePaths[volId]) + "/" + targetName;
            
            // FA_WRITE | FA_OPEN_ALWAYS allows writing to any offset, creating the file if missing
            if (f_open(&f, fatPath.c_str(), FA_WRITE | FA_OPEN_ALWAYS) == FR_OK) {
                if (f_lseek(&f, static_cast<FSIZE_t>(offset)) == FR_OK) {
                    UINT bw = 0;
                    if (f_write(&f, body, static_cast<UINT>(len), &bw) == FR_OK && bw == static_cast<UINT>(len)) {
                        success = true;
                    }
                }
                f_close(&f);
            }
        }
    }

    env->ReleaseByteArrayElements(data, body, JNI_ABORT);
    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(targetFileName, targetName);
    close(fd);
    return success ? JNI_TRUE : JNI_FALSE;
}