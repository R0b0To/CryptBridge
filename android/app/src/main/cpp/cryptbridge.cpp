#include <jni.h>
#include <string>
#include <fstream>
#include <vector>
#include <android/log.h>
#include <iomanip>
#include <sstream>
#include <cstring>
#include <unistd.h> 

#include "mbedtls/md.h"
#include "mbedtls/pkcs5.h"
#include "mbedtls/aes.h"

// FATFS HEADERS
#include "ff.h"     
#include "diskio.h" 

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "CryptBridge_C++", __VA_ARGS__)
#define MAX_VOLUMES 4

// Multi-volume arrays indexing active keys and FDs
static int activeFd[MAX_VOLUMES] = {-1, -1, -1, -1};
static uint64_t activeDataOffset[MAX_VOLUMES] = {0};
static bool activeIsRelTweak[MAX_VOLUMES] = {false};
static bool isDataCtxInitialized[MAX_VOLUMES] = {false};

static mbedtls_aes_xts_context activeDataCtxDec[MAX_VOLUMES];
static mbedtls_aes_xts_context activeDataCtxEnc[MAX_VOLUMES];

// 4 Global filesystem workspaces (one for each drive slot)
static FATFS globalFs[MAX_VOLUMES];

bool isPrintable(unsigned char c) {
    return (c >= 32 && c <= 126);
}

bool isSafeChar(unsigned char c) {
    return isPrintable(c);
}

// Sector encryption function (using the dedicated encryption context)
void encryptSector(mbedtls_aes_xts_context* ctx, uint64_t sectorNum, const unsigned char* input, unsigned char* output) {
    unsigned char tweak[16] = {0};
    for (int i = 0; i < 8; i++) {
        tweak[i] = (unsigned char)((sectorNum >> (i * 8)) & 0xFF);
    }
    mbedtls_aes_crypt_xts(ctx, MBEDTLS_AES_ENCRYPT, 512, tweak, input, output);
}

// Helper decryption function (using the dedicated decryption context)
void decryptSector(mbedtls_aes_xts_context* ctx, uint64_t sectorNum, const unsigned char* input, unsigned char* output) {
    unsigned char tweak[16] = {0};
    for (int i = 0; i < 8; i++) {
        tweak[i] = (unsigned char)((sectorNum >> (i * 8)) & 0xFF);
    }
    mbedtls_aes_crypt_xts(ctx, MBEDTLS_AES_DECRYPT, 512, tweak, input, output);
}

void setTweak(unsigned char* tweak, uint64_t sectorNum) {
    memset(tweak, 0, 16);
    for (int i = 0; i < 8; i++) {
        tweak[i] = (unsigned char)((sectorNum >> (i * 8)) & 0xFF);
    }
}

// ----------------------------------------------------------------====
// FATFS SYSTEM INTEGRATION (Low-Level POSIX Disk Hooks)
// ----------------------------------------------------------------====

extern "C" DSTATUS disk_initialize(BYTE pdrv) {
    return 0; 
}

extern "C" DSTATUS disk_status(BYTE pdrv) {
    return 0;
}

// FatFs automatically passes the drive ID (0 to 3) as "pdrv"
extern "C" DRESULT disk_read(BYTE pdrv, BYTE* buff, LBA_t sector, UINT count) {
    if (pdrv >= MAX_VOLUMES || activeFd[pdrv] < 0 || !isDataCtxInitialized[pdrv]) return RES_NOTRDY;

    unsigned char enc[512];
    for (UINT i = 0; i < count; i++) {
        uint64_t physicalSector = (activeDataOffset[pdrv] / 512) + sector + i;
        lseek(activeFd[pdrv], physicalSector * 512, SEEK_SET);
        read(activeFd[pdrv], enc, 512);

        decryptSector(&activeDataCtxDec[pdrv], activeIsRelTweak[pdrv] ? (physicalSector - (activeDataOffset[pdrv] / 512)) : physicalSector, enc, buff + (i * 512));
    }
    return RES_OK;
}

extern "C" DRESULT disk_write(BYTE pdrv, const BYTE* buff, LBA_t sector, UINT count) {
    if (pdrv >= MAX_VOLUMES || activeFd[pdrv] < 0 || !isDataCtxInitialized[pdrv]) return RES_NOTRDY;

    unsigned char enc[512];
    for (UINT i = 0; i < count; i++) {
        uint64_t physicalSector = (activeDataOffset[pdrv] / 512) + sector + i;
        encryptSector(&activeDataCtxEnc[pdrv], activeIsRelTweak[pdrv] ? (physicalSector - (activeDataOffset[pdrv] / 512)) : physicalSector, buff + (i * 512), enc);

        lseek(activeFd[pdrv], physicalSector * 512, SEEK_SET);
        write(activeFd[pdrv], enc, 512);
    }
    return RES_OK;
}

extern "C" DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void* buff) {
    switch (cmd) {
        case CTRL_SYNC:
            return RES_OK;
        case GET_SECTOR_COUNT:
            *(LBA_t*)buff = 1000000;
            return RES_OK;
        case GET_SECTOR_SIZE:
            *(WORD*)buff = 512;
            return RES_OK;
        case GET_BLOCK_SIZE:
            *(DWORD*)buff = 1;
            return RES_OK;
    }
    return RES_PARERR;
}

extern "C" DWORD get_fattime() {
    return 0; 
}

// ----------------------------------------------------------------====
// CRYPTO SESSION BUILDER
// ----------------------------------------------------------------====

bool prepareSession(int fd, const char* password, int pim, int volId, bool forceDerive) {
    if (volId >= MAX_VOLUMES) return false;

    // FIX: Only bypass PBKDF2 if we aren't explicitly forcing a new key derivation
    if (!forceDerive && isDataCtxInitialized[volId]) {
        activeFd[volId] = fd;
        return true; 
    }

    LOGI("Running PBKDF2 Key Derivation for Volume %d...", volId);

    std::vector<unsigned char> salt(64), encH(448), decH(448);
    lseek(fd, 0, SEEK_SET);
    read(fd, salt.data(), 64);
    read(fd, encH.data(), 448);

    int iter = (pim > 0) ? (15000 + (pim * 1000)) : 500000;
    mbedtls_md_context_t md_ctx;
    mbedtls_md_init(&md_ctx);
    mbedtls_md_setup(&md_ctx, mbedtls_md_info_from_type(MBEDTLS_MD_SHA512), 1);
    std::vector<unsigned char> hKey(64);
    mbedtls_pkcs5_pbkdf2_hmac(&md_ctx, (const unsigned char*)password, strlen(password), salt.data(), 64, iter, 64, hKey.data());
    mbedtls_md_free(&md_ctx);

    mbedtls_aes_xts_context xts;
    mbedtls_aes_xts_init(&xts);
    mbedtls_aes_xts_setkey_dec(&xts, hKey.data(), 512);
    unsigned char zTw[16] = {0};
    mbedtls_aes_crypt_xts(&xts, MBEDTLS_AES_DECRYPT, 448, zTw, encH.data(), decH.data());

    if (decH[0] != 'V' || decH[1] != 'E' || decH[2] != 'R' || decH[3] != 'A') {
        mbedtls_aes_xts_free(&xts);
        return false;
    }

    unsigned char dKey[64];
    memcpy(dKey, &decH[252], 64);

    if (isDataCtxInitialized[volId]) {
        mbedtls_aes_xts_free(&activeDataCtxDec[volId]);
        mbedtls_aes_xts_free(&activeDataCtxEnc[volId]);
    }
    mbedtls_aes_xts_init(&activeDataCtxDec[volId]);
    mbedtls_aes_xts_init(&activeDataCtxEnc[volId]);
    mbedtls_aes_xts_setkey_dec(&activeDataCtxDec[volId], dKey, 512);
    mbedtls_aes_xts_setkey_enc(&activeDataCtxEnc[volId], dKey, 512);
    isDataCtxInitialized[volId] = true;

    // FIX: Scanner rewritten using 100% POSIX fd commands! No more std::ifstream here.
    int keyOffsets[] = {252, 192};
    unsigned char encS[512], decS[512], tw[16];
    bool fsFound = false;

    for (int kOff : keyOffsets) {
        memcpy(dKey, &decH[kOff], 64);
        mbedtls_aes_xts_setkey_dec(&activeDataCtxDec[volId], dKey, 512);

        for (uint64_t s = 0; s < 2048; s++) {
            lseek(fd, s * 512, SEEK_SET);
            read(fd, encS, 512);
            
            setTweak(tw, s);
            mbedtls_aes_crypt_xts(&activeDataCtxDec[volId], MBEDTLS_AES_DECRYPT, 512, tw, encS, decS);
            if (decS[510] == 0x55 && decS[511] == 0xAA) {
                activeDataOffset[volId] = s * 512;
                activeIsRelTweak[volId] = false;
                fsFound = true;
                break;
            }
            setTweak(tw, 0); 
            mbedtls_aes_crypt_xts(&activeDataCtxDec[volId], MBEDTLS_AES_DECRYPT, 512, tw, encS, decS);
            if (decS[510] == 0x55 && decS[511] == 0xAA) {
                activeDataOffset[volId] = s * 512;
                activeIsRelTweak[volId] = true;
                fsFound = true;
                break;
            }
        }
        if (fsFound) break;
    }

    mbedtls_aes_xts_free(&xts);

    if (!fsFound) return false;

    mbedtls_aes_xts_setkey_enc(&activeDataCtxEnc[volId], dKey, 512);
    activeFd[volId] = fd; // FIX: Keep track of our system file descriptor instead of paths!
    return true;
}

// ----------------------------------------------------------------====
// JNI API IMPLEMENTATION
// ----------------------------------------------------------------====

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_example_cryptbridge_VeraCryptEngine_unlockAndListNative(JNIEnv* env, jobject obj, jint fd, jstring password, jint pim, jint volId) {
    const char *nativePass = env->GetStringUTFChars(password, nullptr);

    // FORCE key derivation on first unlock
    if (!prepareSession(fd, nativePass, pim, volId, true)) {
        env->ReleaseStringUTFChars(password, nativePass);
        close(fd);
        return nullptr;
    }

    std::vector<std::string> results;
    std::string drivePath = std::to_string(volId) + ":";

    FRESULT fr = f_mount(&globalFs[volId], drivePath.c_str(), 1); 
    
    if (fr == FR_OK) {
        DIR dir;
        FILINFO fno;
        if (f_opendir(&dir, drivePath.c_str()) == FR_OK) {
            while (f_readdir(&dir, &fno) == FR_OK && fno.fname[0]) {
                std::string entryName = fno.fname;
                if (entryName == "SYSTEM~1" || entryName == "$RECYCLE.BIN") continue;
                
                if (fno.fattrib & AM_DIR) {
                    results.push_back("[DIR] " + entryName);
                } else {
                    results.push_back(entryName);
                }
            }
            f_closedir(&dir);
        }
        f_mount(nullptr, drivePath.c_str(), 0); 
    } else {
        LOGI("FATFS Mount failed on volume %d with code: %d", volId, fr);
        results.push_back("Error: Mount failed.");
    }

    jclass strClass = env->FindClass("java/lang/String");
    jobjectArray retArr = env->NewObjectArray(results.size(), strClass, nullptr);
    for (size_t i = 0; i < results.size(); i++) {
        std::string safeStr = "";
        for (char c : results[i]) {
            if (isPrintable((unsigned char)c)) {
                safeStr += c;
            } else {
                safeStr += '?'; 
            }
        }
        jstring js = env->NewStringUTF(safeStr.c_str());
        env->SetObjectArrayElement(retArr, i, js);
        env->DeleteLocalRef(js);
    }

    env->ReleaseStringUTFChars(password, nativePass);
    close(fd); 
    return retArr;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_cryptbridge_VeraCryptEngine_unlockAndExtractNative(
        JNIEnv* env, jobject obj, 
        jint fd, jstring password, jint pim, 
        jstring targetFileName, jstring destPath, jint volId) {
        
    const char *nativePass = env->GetStringUTFChars(password, nullptr);
    const char *targetName = env->GetStringUTFChars(targetFileName, nullptr);
    const char *destination = env->GetStringUTFChars(destPath, nullptr);

    // Reuse cached keys
    if (!prepareSession(fd, nativePass, pim, volId, false)) {
        env->ReleaseStringUTFChars(password, nativePass);
        env->ReleaseStringUTFChars(targetFileName, targetName);
        env->ReleaseStringUTFChars(destPath, destination);
        close(fd);
        return JNI_FALSE;
    }

    std::string drivePath = std::to_string(volId) + ":";
    FRESULT fr = f_mount(&globalFs[volId], drivePath.c_str(), 1);
    bool success = false;

    if (fr == FR_OK) {
        FIL f;
        std::string fatPath = drivePath + "/" + std::string(targetName);
        
        fr = f_open(&f, fatPath.c_str(), FA_READ);
        if (fr == FR_OK) {
            std::ofstream outFile(destination, std::ios::binary);
            if (outFile.is_open()) {
                unsigned char buffer[4096];
                UINT br;
                while (f_read(&f, buffer, sizeof(buffer), &br) == FR_OK && br > 0) {
                    outFile.write((char*)buffer, br);
                }
                outFile.close();
                success = true;
            }
            f_close(&f);
        }
        f_mount(nullptr, drivePath.c_str(), 0); 
    }

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(targetFileName, targetName);
    env->ReleaseStringUTFChars(destPath, destination);
    close(fd);

    return success ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_cryptbridge_VeraCryptEngine_writeBackFileNative(
        JNIEnv* env, jobject obj, 
        jint fd, jstring password, jint pim, 
        jstring targetFileName, jstring sourcePath, jint volId) {
        
    const char *nativePass = env->GetStringUTFChars(password, nullptr);
    const char *targetName = env->GetStringUTFChars(targetFileName, nullptr);
    const char *source = env->GetStringUTFChars(sourcePath, nullptr);

    // Reuse cached keys
    if (!prepareSession(fd, nativePass, pim, volId, false)) {
        env->ReleaseStringUTFChars(password, nativePass);
        env->ReleaseStringUTFChars(targetFileName, targetName);
        env->ReleaseStringUTFChars(sourcePath, source);
        close(fd);
        return JNI_FALSE;
    }

    std::string drivePath = std::to_string(volId) + ":";
    FRESULT fr = f_mount(&globalFs[volId], drivePath.c_str(), 1);
    bool success = false;

    if (fr == FR_OK) {
        FIL f;
        std::string fatPath = drivePath + "/" + std::string(targetName);
        
        fr = f_open(&f, fatPath.c_str(), FA_WRITE | FA_CREATE_ALWAYS);
        if (fr == FR_OK) {
            std::ifstream inFile(source, std::ios::binary);
            if (inFile.is_open()) {
                char buffer[4096];
                UINT bw;
                
                while (inFile) {
                    inFile.read(buffer, sizeof(buffer));
                    std::streamsize bytesRead = inFile.gcount();
                    if (bytesRead > 0) {
                        f_write(&f, buffer, bytesRead, &bw);
                    }
                }
                inFile.close();
                success = true;
            }
            f_close(&f);
        }
        f_mount(nullptr, drivePath.c_str(), 0); 
    }

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(targetFileName, targetName);
    env->ReleaseStringUTFChars(sourcePath, source);
    close(fd);

    return success ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_cryptbridge_VeraCryptEngine_deleteFileNative(
        JNIEnv* env, jobject obj, 
        jint fd, jstring password, jint pim, 
        jstring targetFileName, jint volId) {
        
    const char *nativePass = env->GetStringUTFChars(password, nullptr);
    const char *targetName = env->GetStringUTFChars(targetFileName, nullptr);

    // Reuse cached keys
    if (!prepareSession(fd, nativePass, pim, volId, false)) {
        env->ReleaseStringUTFChars(password, nativePass);
        env->ReleaseStringUTFChars(targetFileName, targetName);
        close(fd);
        return JNI_FALSE;
    }

    std::string drivePath = std::to_string(volId) + ":";
    FRESULT fr = f_mount(&globalFs[volId], drivePath.c_str(), 1);
    bool success = false;

    if (fr == FR_OK) {
        std::string fatPath = drivePath + "/" + std::string(targetName);
        fr = f_unlink(fatPath.c_str());
        if (fr == FR_OK) {
            success = true;
        }
        f_mount(nullptr, drivePath.c_str(), 0); 
    }

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(targetFileName, targetName);
    close(fd);

    return success ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_cryptbridge_VeraCryptEngine_lockNative(JNIEnv* env, jobject obj, jint volId) {
    if (volId >= MAX_VOLUMES) return;

    activeFd[volId] = -1;
    activeDataOffset[volId] = 0;
    activeIsRelTweak[volId] = false;

    if (isDataCtxInitialized[volId]) {
        mbedtls_aes_xts_free(&activeDataCtxDec[volId]);
        mbedtls_aes_xts_free(&activeDataCtxEnc[volId]);
        isDataCtxInitialized[volId] = false;
    }

    std::string drivePath = std::to_string(volId) + ":";
    f_mount(nullptr, drivePath.c_str(), 0); 
}