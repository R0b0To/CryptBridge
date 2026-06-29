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
#include <mutex>
#include <ctime>   // mktime, struct tm, time_t

#include "mbedtls/md.h"
#include "mbedtls/pkcs5.h"
#include "mbedtls/aes.h"

#include "ff.h"
#include "diskio.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "VaultExplorer_C++", __VA_ARGS__)

#define MAX_VOLUMES FF_VOLUMES

// ----------------------------------------------------------------====
// NAMED CONSTANTS
// ----------------------------------------------------------------====

static constexpr size_t VC_SALT_SIZE            = 64;
static constexpr size_t VC_HEADER_BODY_SIZE     = 448;
static constexpr size_t VC_FULL_HEADER_SIZE     = 512;      // salt(64) + body(448)
static constexpr uint64_t VC_DATA_AREA_OFFSET   = 131072ULL;
static constexpr size_t IO_BUFFER_SIZE          = 262144;   // 256 KB
static constexpr int    VC_KEY_OFFSET_PRIMARY   = 252;
static constexpr int    VC_KEY_OFFSET_SECONDARY = 192;
static constexpr int    VC_KEY_MATERIAL_LEN     = 64;
static constexpr size_t MAX_DIR_ENTRIES         = 50000;
static constexpr uint64_t SCAN_SECTORS          = 2048;
static constexpr uint64_t SCAN_BATCH            = 64;
static constexpr int    MKFS_WORK_BUF_SIZE      = 4096;
static constexpr size_t MAX_CHUNK_SIZE          = 64 * 1024 * 1024; // 64 MB safety cap

// FIX P14: Use a much larger batch for container creation to reduce pwrite()
// syscall count. 4096 sectors = 2 MB per write vs 32 KB — 64× fewer syscalls
// for a 1 GB container (512 writes vs 32,768).
static constexpr uint64_t CREATE_FILL_BATCH     = 4096;

// FIX P12: Per-volume persistent IO buffer to avoid allocating a fresh heap
// buffer on every large disk_read/disk_write call (which FatFs can issue up to
// 4 MB at once during sequential file access).
static constexpr size_t   IO_VOL_BUF_SECTORS    = 512;    // 256 KB per volume
static constexpr size_t   IO_VOL_BUF_SIZE       = IO_VOL_BUF_SECTORS * 512;

// ----------------------------------------------------------------====
// RAII WRAPPERS
// ----------------------------------------------------------------====

struct XtsContextPair {
    mbedtls_aes_xts_context dec;
    mbedtls_aes_xts_context enc;
    bool initialized = false;

    XtsContextPair() {
        mbedtls_aes_xts_init(&dec);
        mbedtls_aes_xts_init(&enc);
    }
    ~XtsContextPair() {
        mbedtls_aes_xts_free(&dec);
        mbedtls_aes_xts_free(&enc);
    }
    XtsContextPair(const XtsContextPair&) = delete;
    XtsContextPair& operator=(const XtsContextPair&) = delete;
};

struct MdContextGuard {
    mbedtls_md_context_t ctx;
    MdContextGuard() { mbedtls_md_init(&ctx); }
    ~MdContextGuard() { mbedtls_md_free(&ctx); }
};

// ----------------------------------------------------------------====
// GLOBAL STATE
// ----------------------------------------------------------------====

static std::mutex    volumeMutex[MAX_VOLUMES];
static std::mutex    slotAllocMutex;

static int           activeFd[MAX_VOLUMES];
static uint64_t      activeDataOffset[MAX_VOLUMES];
static bool          activeIsRelTweak[MAX_VOLUMES];
static bool          isDataCtxInitialized[MAX_VOLUMES];
static uint64_t      activeFileSize[MAX_VOLUMES];
static bool          fsMounted[MAX_VOLUMES];

static mbedtls_aes_xts_context activeDataCtxDec[MAX_VOLUMES];
static mbedtls_aes_xts_context activeDataCtxEnc[MAX_VOLUMES];

// FIX P12: Per-volume persistent IO buffers. Allocated once on first use,
// reused for every subsequent disk_read/disk_write on that volume, eliminating
// per-call heap churn for large sequential reads (video, export, copy).
static std::unique_ptr<unsigned char[]> ioVolBuf[MAX_VOLUMES];
static size_t                           ioVolBufSize[MAX_VOLUMES];
static std::mutex                       ioVolBufMutex[MAX_VOLUMES];

static const char* drivePaths[MAX_VOLUMES] = {
    "0:", "1:", "2:", "3:", "4:", "5:", "6:", "7:"
};
static FATFS globalFs[MAX_VOLUMES];

static bool _globalInit = [](){
    for (int i = 0; i < MAX_VOLUMES; i++) {
        activeFd[i]               = -1;
        activeDataOffset[i]       = 0;
        activeIsRelTweak[i]       = false;
        isDataCtxInitialized[i]   = false;
        activeFileSize[i]         = 0;
        fsMounted[i]              = false;
        ioVolBufSize[i]           = 0;
    }
    return true;
}();

// ----------------------------------------------------------------====
// MOUNT CACHE HELPERS
// ----------------------------------------------------------------====

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
    // Release persistent IO buffer when volume is locked.
    std::lock_guard<std::mutex> bufLock(ioVolBufMutex[volId]);
    ioVolBuf[volId].reset();
    ioVolBufSize[volId] = 0;
}

// ----------------------------------------------------------------====
// INLINE HELPERS
// ----------------------------------------------------------------====

// FIX P13: Fast check before paying the full replace_if scan cost.
// The vast majority of filenames from FAT filesystems are clean ASCII —
// checking first avoids a full byte scan on every directory entry.
static inline bool hasControlChar(const std::string& s) {
    for (unsigned char c : s) {
        if (c < 32 || c == 127) return true;
    }
    return false;
}

static void sanitizeString(std::string& s) {
    if (!hasControlChar(s)) return;   // FIX P13: skip replace_if when clean
    std::replace_if(s.begin(), s.end(),
        [](unsigned char c){ return c < 32 || c == 127; }, '?');
}

static inline void setTweak(unsigned char* tweak, uint64_t sectorNum) {
    *reinterpret_cast<uint64_t*>(tweak)   = sectorNum;
    *reinterpret_cast<uint64_t*>(tweak+8) = 0ULL;
}

static inline int clampPim(int pim) {
    if (pim < 0) return 0;
    if (pim > 2000) return 2000;
    return pim;
}

// ── FAT date/time → Unix timestamp ─────────────────────────────────────────

static uint64_t fatToUnixTimestamp(WORD fdate, WORD ftime) {
    // FatFs stores dates as FAT-epoch (1980-01-01).
    // fdate: bits[15:9]=year-1980  bits[8:5]=month  bits[4:0]=day
    // ftime: bits[15:11]=hour  bits[10:5]=minute  bits[4:0]=second/2
    if (fdate == 0) return 0; // no RTC data (FF_FS_NORTC=1 new files)
    struct tm t = {};
    t.tm_year  = ((fdate >> 9) & 0x7F) + 80; // FAT epoch 1980, tm epoch 1900
    t.tm_mon   = ((fdate >> 5) & 0x0F) - 1;  // FAT 1-12  →  tm 0-11
    t.tm_mday  =  (fdate)       & 0x1F;
    t.tm_hour  = (ftime >> 11)  & 0x1F;
    t.tm_min   = (ftime >>  5)  & 0x3F;
    t.tm_sec   = (ftime  & 0x1F) * 2;
    t.tm_isdst = -1;
    const time_t ts = mktime(&t);
    return (ts < 0) ? 0 : static_cast<uint64_t>(ts);
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
// FIX P12: Per-volume IO buffer accessor
// Returns a pointer to a buffer of at least `neededBytes` for `volId`.
// The buffer is allocated once and grown if needed; never shrunk.
// MUST be called with ioVolBufMutex[volId] held.
// ----------------------------------------------------------------====
static unsigned char* getVolIoBuf(int volId, size_t neededBytes) {
    if (ioVolBufSize[volId] < neededBytes) {
        ioVolBuf[volId].reset(new unsigned char[neededBytes]);
        ioVolBufSize[volId] = neededBytes;
    }
    return ioVolBuf[volId].get();
}

// ----------------------------------------------------------------====
// FATFS LOW-LEVEL DISK HOOKS
// ----------------------------------------------------------------====

extern "C" DSTATUS disk_initialize(BYTE pdrv) { return 0; }
extern "C" DSTATUS disk_status(BYTE pdrv)     { return 0; }

extern "C" DRESULT disk_read(BYTE pdrv, BYTE* buff, LBA_t sector, UINT count) {
    if (pdrv >= MAX_VOLUMES || activeFd[pdrv] < 0 || !isDataCtxInitialized[pdrv])
        return RES_NOTRDY;
    if (count == 0 || count > 8192) return RES_PARERR;

    const uint64_t basePhysical = activeDataOffset[pdrv] / 512;
    const bool relTweak = activeIsRelTweak[pdrv];
    const int fd = activeFd[pdrv];
    const uint64_t firstPhysical = basePhysical + sector;
    const size_t   totalBytes    = static_cast<size_t>(count) * 512;

    // FIX P12: Use the per-volume persistent buffer for requests that exceed
    // the stack threshold, eliminating heap alloc/free on every large read.
    alignas(16) unsigned char stackBuf[65536];
    unsigned char* encBuf;

    if (totalBytes <= sizeof(stackBuf)) {
        encBuf = stackBuf;
    } else {
        std::lock_guard<std::mutex> bufLock(ioVolBufMutex[pdrv]);
        encBuf = getVolIoBuf(pdrv, totalBytes);
        // pread directly into the persistent buffer, decrypt into caller's buff.
        ssize_t got = pread(fd, encBuf, totalBytes,
                            static_cast<off_t>(firstPhysical * 512));
        if (got < static_cast<ssize_t>(totalBytes)) return RES_ERROR;
        for (UINT i = 0; i < count; i++) {
            const uint64_t physSector = firstPhysical + i;
            const uint64_t tweak      = relTweak ? (physSector - basePhysical) : physSector;
            decryptSector(&activeDataCtxDec[pdrv], tweak,
                          encBuf + (i * 512), buff + (i * 512));
        }
        return RES_OK;
    }

    ssize_t got = pread(fd, encBuf, totalBytes,
                        static_cast<off_t>(firstPhysical * 512));
    if (got < static_cast<ssize_t>(totalBytes)) return RES_ERROR;

    for (UINT i = 0; i < count; i++) {
        const uint64_t physSector = firstPhysical + i;
        const uint64_t tweak      = relTweak ? (physSector - basePhysical) : physSector;
        decryptSector(&activeDataCtxDec[pdrv], tweak,
                      encBuf + (i * 512), buff + (i * 512));
    }
    return RES_OK;
}

extern "C" DRESULT disk_write(BYTE pdrv, const BYTE* buff, LBA_t sector, UINT count) {
    if (pdrv >= MAX_VOLUMES || activeFd[pdrv] < 0 || !isDataCtxInitialized[pdrv])
        return RES_NOTRDY;
    if (count == 0 || count > 8192) return RES_PARERR;

    const uint64_t basePhysical = activeDataOffset[pdrv] / 512;
    const bool     relTweak     = activeIsRelTweak[pdrv];
    const int      fd           = activeFd[pdrv];
    const uint64_t firstPhysical = basePhysical + sector;
    const size_t   totalBytes    = static_cast<size_t>(count) * 512;

    // FIX P12: Same persistent-buffer strategy for writes.
    alignas(16) unsigned char stackBuf[65536];
    unsigned char* encBuf;

    if (totalBytes <= sizeof(stackBuf)) {
        encBuf = stackBuf;
        for (UINT i = 0; i < count; i++) {
            const uint64_t physSector = firstPhysical + i;
            const uint64_t tweak      = relTweak ? (physSector - basePhysical) : physSector;
            encryptSector(&activeDataCtxEnc[pdrv], tweak,
                          buff + (i * 512), encBuf + (i * 512));
        }
        ssize_t written = pwrite(fd, encBuf, totalBytes,
                                 static_cast<off_t>(firstPhysical * 512));
        return (written == static_cast<ssize_t>(totalBytes)) ? RES_OK : RES_ERROR;
    } else {
        std::lock_guard<std::mutex> bufLock(ioVolBufMutex[pdrv]);
        encBuf = getVolIoBuf(pdrv, totalBytes);
        for (UINT i = 0; i < count; i++) {
            const uint64_t physSector = firstPhysical + i;
            const uint64_t tweak      = relTweak ? (physSector - basePhysical) : physSector;
            encryptSector(&activeDataCtxEnc[pdrv], tweak,
                          buff + (i * 512), encBuf + (i * 512));
        }
        ssize_t written = pwrite(fd, encBuf, totalBytes,
                                 static_cast<off_t>(firstPhysical * 512));
        return (written == static_cast<ssize_t>(totalBytes)) ? RES_OK : RES_ERROR;
    }
}

extern "C" DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void* buff) {
    switch (cmd) {
        case CTRL_SYNC:
            return RES_OK;

        case GET_SECTOR_COUNT:
            if (pdrv < MAX_VOLUMES && activeFileSize[pdrv] > VC_DATA_AREA_OFFSET * 2) {
                *(LBA_t*)buff = static_cast<LBA_t>(
                    (activeFileSize[pdrv] - VC_DATA_AREA_OFFSET * 2) / 512);
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
//
// FIX P11: PBKDF2 runs for ~2 s (500k iterations). The original code held
// volumeMutex for the entire derivation, blocking ALL reads/writes on that
// volume slot while the key was being computed.
//
// The fix: derive the key with NO lock held, then acquire the mutex only for
// the brief header-decrypt + context-swap phase (~microseconds). A secondary
// "derivation in progress" atomic flag prevents two threads from deriving
// simultaneously for the same volume without blocking readers.
// ----------------------------------------------------------------====

static std::atomic<bool> derivationInProgress[MAX_VOLUMES];

static bool _derivationInit = [](){
    for (int i = 0; i < MAX_VOLUMES; i++)
        derivationInProgress[i].store(false);
    return true;
}();

bool prepareSession(int fd, const char* password, int pim, int volId, bool forceDerive) {
    if (volId < 0 || volId >= MAX_VOLUMES) {
        if (fd >= 0) close(fd);
        return false;
    }

    // Fast path: session already established, no derivation needed.
    if (!forceDerive) {
        std::lock_guard<std::mutex> lock(volumeMutex[volId]);
        if (isDataCtxInitialized[volId] && activeFd[volId] >= 0) {
            if (fd >= 0) close(fd);
            return true;
        }
        if (isDataCtxInitialized[volId]) {
            if (fd >= 0) {
                struct stat st;
                if (fstat(fd, &st) == 0)
                    activeFileSize[volId] = static_cast<uint64_t>(st.st_size);
                activeFd[volId] = fd;
                return true;
            }
            return false;
        }
    }

    if (fd < 0) return false;

    // FIX P11: Prevent two threads from deriving simultaneously for the same
    // volume (e.g., rapid double-tap unlock). Second thread waits via spinlock.
    bool expected = false;
    while (!derivationInProgress[volId].compare_exchange_weak(
               expected, true, std::memory_order_acquire)) {
        expected = false;
        // Re-check: the first thread may have finished by now.
        std::lock_guard<std::mutex> lock(volumeMutex[volId]);
        if (isDataCtxInitialized[volId]) {
            if (fd >= 0) close(fd);
            derivationInProgress[volId].store(false, std::memory_order_release);
            return true;
        }
    }

    LOGI("Running PBKDF2 Key Derivation for Volume %d (mutex NOT held)...", volId);

    // --- Read header WITHOUT holding the volume mutex ---
    unsigned char headerBuf[VC_FULL_HEADER_SIZE];
    if (pread(fd, headerBuf, VC_FULL_HEADER_SIZE, 0) != VC_FULL_HEADER_SIZE) {
        close(fd);
        derivationInProgress[volId].store(false, std::memory_order_release);
        return false;
    }

    uint64_t fileSize = 0;
    {
        struct stat st;
        if (fstat(fd, &st) == 0)
            fileSize = static_cast<uint64_t>(st.st_size);
    }

    const unsigned char* salt = headerBuf;
    const unsigned char* encH = headerBuf + VC_SALT_SIZE;

    const int safePim = clampPim(pim);
    const int iter = (safePim > 0) ? (15000 + (safePim * 1000)) : 500000;

    // FIX P11: PBKDF2 runs here — completely outside the volume mutex.
    // Other volume operations (reads on an already-unlocked volume, operations
    // on different volumes) are entirely unaffected.
    MdContextGuard mdGuard;
    mbedtls_md_setup(&mdGuard.ctx, mbedtls_md_info_from_type(MBEDTLS_MD_SHA512), 1);

    unsigned char hKey[VC_KEY_MATERIAL_LEN];
    mbedtls_pkcs5_pbkdf2_hmac(&mdGuard.ctx,
        reinterpret_cast<const unsigned char*>(password), strlen(password),
        salt, VC_SALT_SIZE, iter, VC_KEY_MATERIAL_LEN, hKey);

    unsigned char decH[VC_HEADER_BODY_SIZE];
    {
        XtsContextPair hdrXts;
        mbedtls_aes_xts_setkey_dec(&hdrXts.dec, hKey, 512);
        const unsigned char zTw[16] = {0};
        mbedtls_aes_crypt_xts(&hdrXts.dec, MBEDTLS_AES_DECRYPT,
                               VC_HEADER_BODY_SIZE, zTw, encH, decH);
    }

    mbedtls_platform_zeroize(hKey, sizeof(hKey));

    if (decH[0] != 'V' || decH[1] != 'E' || decH[2] != 'R' || decH[3] != 'A') {
        mbedtls_platform_zeroize(decH, sizeof(decH));
        close(fd);
        derivationInProgress[volId].store(false, std::memory_order_release);
        return false;
    }

    const int keyOffsets[] = {VC_KEY_OFFSET_PRIMARY, VC_KEY_OFFSET_SECONDARY};

    unsigned char dKey[VC_KEY_MATERIAL_LEN];
    bool fsFound = false;
    uint64_t foundDataOffset = 0;
    bool     foundRelTweak   = false;

    XtsContextPair candidate;
    std::unique_ptr<unsigned char[]> encBatch(new unsigned char[SCAN_BATCH * 512]);
    unsigned char decS[512];
    unsigned char tweak[16];

    for (int kOff : keyOffsets) {
        memcpy(dKey, &decH[kOff], VC_KEY_MATERIAL_LEN);
        mbedtls_aes_xts_setkey_dec(&candidate.dec, dKey, 512);

        uint64_t s = 0;
        while (s < SCAN_SECTORS && !fsFound) {
            const uint64_t batchCount = std::min(SCAN_BATCH, SCAN_SECTORS - s);
            const ssize_t  batchBytes = static_cast<ssize_t>(batchCount * 512);

            if (pread(fd, encBatch.get(), batchBytes,
                      static_cast<off_t>(s * 512)) != batchBytes)
                break;

            for (uint64_t i = 0; i < batchCount && !fsFound; i++) {
                const uint64_t sectorIdx = s + i;
                const unsigned char* enc = encBatch.get() + (i * 512);

                setTweak(tweak, sectorIdx);
                mbedtls_aes_crypt_xts(&candidate.dec, MBEDTLS_AES_DECRYPT,
                                      512, tweak, enc, decS);
                if (decS[510] == 0x55 && decS[511] == 0xAA) {
                    foundDataOffset = sectorIdx * 512;
                    foundRelTweak   = false;
                    fsFound = true;
                    break;
                }

                memset(tweak, 0, 16);
                mbedtls_aes_crypt_xts(&candidate.dec, MBEDTLS_AES_DECRYPT,
                                      512, tweak, enc, decS);
                if (decS[510] == 0x55 && decS[511] == 0xAA) {
                    foundDataOffset = sectorIdx * 512;
                    foundRelTweak   = true;
                    fsFound = true;
                    break;
                }
            }
            s += batchCount;
        }
        if (fsFound) break;
    }

    mbedtls_platform_zeroize(decH, sizeof(decH));

    if (!fsFound) {
        mbedtls_platform_zeroize(dKey, sizeof(dKey));
        close(fd);
        derivationInProgress[volId].store(false, std::memory_order_release);
        return false;
    }

    mbedtls_aes_xts_setkey_enc(&candidate.enc, dKey, 512);
    mbedtls_platform_zeroize(dKey, sizeof(dKey));

    // FIX P11: Now acquire the mutex ONLY for the brief context swap.
    // All the slow crypto work is already done above.
    {
        std::lock_guard<std::mutex> lock(volumeMutex[volId]);

        if (isDataCtxInitialized[volId]) {
            mbedtls_aes_xts_free(&activeDataCtxDec[volId]);
            mbedtls_aes_xts_free(&activeDataCtxEnc[volId]);
        }
        activeDataCtxDec[volId] = candidate.dec;
        activeDataCtxEnc[volId] = candidate.enc;
        mbedtls_aes_xts_init(&candidate.dec);
        mbedtls_aes_xts_init(&candidate.enc);

        isDataCtxInitialized[volId] = true;
        activeFd[volId]             = fd;
        activeDataOffset[volId]     = foundDataOffset;
        activeIsRelTweak[volId]     = foundRelTweak;
        activeFileSize[volId]       = fileSize;
    }

    derivationInProgress[volId].store(false, std::memory_order_release);
    return true;
}

// ----------------------------------------------------------------====
// SHARED: Directory listing
// ----------------------------------------------------------------====

// Returns the total byte size of all files under [fatPath] (recursive).
// Called from getFolderSizeNative; also usable for progress reporting later.
static uint64_t recursiveFolderSize(int volId, const std::string& fatPath) {
    std::string fullPath = drivePaths[volId];
    if (!fatPath.empty()) { fullPath += '/'; fullPath += fatPath; }

    uint64_t total = 0;
    DIR dir; FILINFO fno;
    if (f_opendir(&dir, fullPath.c_str()) == FR_OK) {
        while (f_readdir(&dir, &fno) == FR_OK && fno.fname[0]) {
            if (fno.fattrib & AM_DIR) {
                const std::string child = fatPath.empty()
                    ? std::string(fno.fname)
                    : fatPath + '/' + fno.fname;
                total += recursiveFolderSize(volId, child);
            } else {
                total += fno.fsize;
            }
        }
        f_closedir(&dir);
    }
    return total;
}

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
            if (results.size() >= MAX_DIR_ENTRIES) {
                results.push_back("System:TRUNCATED");
                LOGI("buildDirectoryListing: truncated at %zu entries", MAX_DIR_ENTRIES);
                break;
            }
            const char* name = fno.fname;
            if (strcmp(name, "SYSTEM~1") == 0 || strcmp(name, "$RECYCLE.BIN") == 0)
                continue;

            const uint64_t ts = fatToUnixTimestamp(fno.fdate, fno.ftime);
            if (fno.fattrib & AM_DIR) {
                std::string entry = "[DIR] ";
                entry += name;
                entry += "|0|";
                entry += std::to_string(ts);
                results.push_back(std::move(entry));
            } else {
                std::string entry = name;
                entry += '|';
                entry += std::to_string(fno.fsize);
                entry += '|';
                entry += std::to_string(ts);
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
        return nullptr;
    }

    jobjectArray result = nullptr;
    if (ensureMounted(volId)) {
        result = buildDirectoryListing(env, volId, nullptr);
    } else {
        LOGI("FATFS Mount failed on volume %d", volId);
    }

    env->ReleaseStringUTFChars(password, nativePass);
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
                    std::unique_ptr<unsigned char[]> buf(new unsigned char[IO_BUFFER_SIZE]);
                    UINT br;
                    while (f_read(&f, buf.get(), IO_BUFFER_SIZE, &br) == FR_OK && br > 0)
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
                    std::unique_ptr<char[]> buf(new char[IO_BUFFER_SIZE]);
                    UINT bw;
                    while (inFile) {
                        inFile.read(buf.get(), IO_BUFFER_SIZE);
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
    return success ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_lockNative(JNIEnv*, jobject, jint volId) {
    if (volId < 0 || volId >= MAX_VOLUMES) return;

    std::lock_guard<std::mutex> lock(volumeMutex[volId]);

    if (activeFd[volId] >= 0) {
        close(activeFd[volId]);
    }
    activeFd[volId]         = -1;
    activeDataOffset[volId] = 0;
    activeIsRelTweak[volId] = false;
    activeFileSize[volId]   = 0;

    if (isDataCtxInitialized[volId]) {
        mbedtls_aes_xts_free(&activeDataCtxDec[volId]);
        mbedtls_aes_xts_free(&activeDataCtxEnc[volId]);
        isDataCtxInitialized[volId] = false;
    }

    unmountVolume(volId);  // also clears the persistent IO buffer
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
    return size;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_readFileChunkNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim,
        jstring targetFileName, jlong offset, jint length, jint volId) {

    if (length <= 0 || static_cast<size_t>(length) > MAX_CHUNK_SIZE) {
        LOGI("readFileChunkNative: invalid length %d", length);
        if (fd >= 0) close(fd);
        return nullptr;
    }

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    const char* targetName = env->GetStringUTFChars(targetFileName, nullptr);

    jbyteArray retArray = nullptr;
    if (prepareSession(fd, nativePass, pim, volId, false)) {
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

    unsigned char salt[VC_SALT_SIZE]               = {0};
    unsigned char combinedMasterKey[VC_KEY_MATERIAL_LEN] = {0};

    do {
        if (sizeBytes < static_cast<jlong>(300 * 1024)) {
            LOGI("createContainer: sizeBytes too small (%lld)", (long long)sizeBytes);
            break;
        }

        int volId = -1;
        {
            std::lock_guard<std::mutex> allocLock(slotAllocMutex);
            for (int i = 0; i < MAX_VOLUMES; i++) {
                if (!isDataCtxInitialized[i]) { volId = i; break; }
            }
        }
        if (volId == -1) {
            LOGI("createContainer: no free slots available");
            break;
        }

        {
            FILE* urnd = fopen("/dev/urandom", "rb");
            if (!urnd) { LOGI("createContainer: cannot open /dev/urandom"); break; }
            bool ok = (fread(salt,              1, VC_SALT_SIZE, urnd) == VC_SALT_SIZE) &&
                      (fread(combinedMasterKey, 1, VC_KEY_MATERIAL_LEN, urnd) == VC_KEY_MATERIAL_LEN);
            fclose(urnd);
            if (!ok) { LOGI("createContainer: urandom read failed"); break; }
        }

        const int safePim = clampPim(pim);
        const int iter = (safePim > 0) ? (15000 + safePim * 1000) : 500000;

        unsigned char headerKey[VC_KEY_MATERIAL_LEN] = {0};
        {
            MdContextGuard mdGuard;
            if (mbedtls_md_setup(&mdGuard.ctx,
                    mbedtls_md_info_from_type(MBEDTLS_MD_SHA512), 1) != 0) {
                LOGI("createContainer: mbedtls_md_setup failed");
                break;
            }
            mbedtls_pkcs5_pbkdf2_hmac(&mdGuard.ctx,
                reinterpret_cast<const unsigned char*>(nativePass), strlen(nativePass),
                salt, VC_SALT_SIZE,
                static_cast<unsigned int>(iter),
                VC_KEY_MATERIAL_LEN, headerKey);
        }

        const uint64_t VOLUME_SIZE = static_cast<uint64_t>(sizeBytes);
        const uint64_t DATA_SIZE   = VOLUME_SIZE - (2 * VC_DATA_AREA_OFFSET);

        unsigned char body[VC_HEADER_BODY_SIZE];
        memset(body, 0, sizeof(body));

        body[0] = 'V'; body[1] = 'E'; body[2] = 'R'; body[3] = 'A';
        body[4] = 0x00; body[5] = 0x02;
        body[6] = 0x01; body[7] = 0x0b;

        for (int i = 7; i >= 0; --i)
            body[36 + (7 - i)] = (VOLUME_SIZE >> (i * 8)) & 0xFF;
        for (int i = 7; i >= 0; --i)
            body[44 + (7 - i)] = (VC_DATA_AREA_OFFSET >> (i * 8)) & 0xFF;
        for (int i = 7; i >= 0; --i)
            body[52 + (7 - i)] = (DATA_SIZE >> (i * 8)) & 0xFF;

        body[64] = 0x00; body[65] = 0x00; body[66] = 0x02; body[67] = 0x00;

        memcpy(&body[VC_KEY_OFFSET_SECONDARY], combinedMasterKey, VC_KEY_MATERIAL_LEN);

        auto crc32 = [](const unsigned char* data, size_t len) -> uint32_t {
            uint32_t crc = 0xFFFFFFFFu;
            for (size_t i = 0; i < len; ++i) {
                crc ^= data[i];
                for (int b = 0; b < 8; ++b)
                    crc = (crc >> 1) ^ (0xEDB88320u & ~((crc & 1) - 1));
            }
            return crc ^ 0xFFFFFFFFu;
        };

        uint32_t keyCrc = crc32(&body[VC_KEY_OFFSET_SECONDARY], 256);
        body[ 8] = (keyCrc >> 24) & 0xFF;
        body[ 9] = (keyCrc >> 16) & 0xFF;
        body[10] = (keyCrc >>  8) & 0xFF;
        body[11] = (keyCrc      ) & 0xFF;

        uint32_t hdrCrc = crc32(body, 188);
        body[188] = (hdrCrc >> 24) & 0xFF;
        body[189] = (hdrCrc >> 16) & 0xFF;
        body[190] = (hdrCrc >>  8) & 0xFF;
        body[191] = (hdrCrc      ) & 0xFF;

        unsigned char encBody[VC_HEADER_BODY_SIZE];
        {
            XtsContextPair hdrXts;
            mbedtls_aes_xts_setkey_enc(&hdrXts.enc, headerKey, 512);
            const unsigned char zeroTweak[16] = {0};
            mbedtls_aes_crypt_xts(&hdrXts.enc, MBEDTLS_AES_ENCRYPT,
                                  VC_HEADER_BODY_SIZE, zeroTweak, body, encBody);
        }

        mbedtls_platform_zeroize(headerKey, sizeof(headerKey));
        mbedtls_platform_zeroize(body, sizeof(body));

        unsigned char hdrSector[VC_FULL_HEADER_SIZE];
        memcpy(hdrSector,                  salt,    VC_SALT_SIZE);
        memcpy(hdrSector + VC_SALT_SIZE,   encBody, VC_HEADER_BODY_SIZE);

        if (pwrite(fd, hdrSector, VC_FULL_HEADER_SIZE, 0) != VC_FULL_HEADER_SIZE) {
            LOGI("createContainer: primary header write failed"); break;
        }
        if (pwrite(fd, hdrSector, VC_FULL_HEADER_SIZE,
                   static_cast<off_t>(VOLUME_SIZE - VC_DATA_AREA_OFFSET)) != VC_FULL_HEADER_SIZE) {
            LOGI("createContainer: backup header write failed"); break;
        }

        {
            XtsContextPair dataXts;
            mbedtls_aes_xts_setkey_enc(&dataXts.enc, combinedMasterKey, 512);

            const uint64_t START_SECTOR  = VC_DATA_AREA_OFFSET / 512;
            const uint64_t TOTAL_SECTORS = (VOLUME_SIZE - VC_DATA_AREA_OFFSET) / 512;

            // FIX P14: Use CREATE_FILL_BATCH (4096 sectors = 2 MB) instead of
            // SCAN_BATCH (64 sectors = 32 KB). For a 1 GB container this reduces
            // pwrite() syscalls from 32,768 → 512, cutting creation time noticeably.
            const unsigned char ZERO_SECTOR[512] = {0};
            const size_t batchBufBytes = CREATE_FILL_BATCH * 512;
            std::unique_ptr<unsigned char[]> batch(new unsigned char[batchBufBytes]);
            unsigned char tweak[16];
            bool writeOk = true;

            for (uint64_t s = START_SECTOR; s < TOTAL_SECTORS && writeOk; ) {
                const uint64_t rem   = TOTAL_SECTORS - s;
                const uint64_t count = (rem < CREATE_FILL_BATCH) ? rem : CREATE_FILL_BATCH;

                for (uint64_t i = 0; i < count; ++i) {
                    setTweak(tweak, s + i);
                    mbedtls_aes_crypt_xts(&dataXts.enc, MBEDTLS_AES_ENCRYPT,
                                          512, tweak, ZERO_SECTOR,
                                          batch.get() + i * 512);
                }

                const ssize_t want = static_cast<ssize_t>(count * 512);
                if (pwrite(fd, batch.get(), want,
                           static_cast<off_t>(s * 512)) != want) {
                    LOGI("createContainer: data fill write failed at sector %llu",
                         (unsigned long long)s);
                    writeOk = false;
                }
                s += count;
            }
            if (!writeOk) break;
        }

        fsync(fd);

        // Format drive
        {
            std::lock_guard<std::mutex> vlock(volumeMutex[volId]);

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
            activeDataOffset[volId]     = VC_DATA_AREA_OFFSET;
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

            alignas(16) unsigned char mkfsBuf[MKFS_WORK_BUF_SIZE];
            FRESULT fr = f_mkfs(drivePaths[volId], &mp, mkfsBuf, sizeof(mkfsBuf));

            LOGI("createContainer: f_mkfs result=%d fmt=%d exfat=%d",
                 (int)fr, (int)mp.fmt, (int)useExFat);

            f_mount(nullptr, drivePaths[volId], 0);
            fsMounted[volId]          = false;
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

    mbedtls_platform_zeroize(combinedMasterKey, sizeof(combinedMasterKey));
    mbedtls_platform_zeroize(salt, sizeof(salt));

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

    jsize len = env->GetArrayLength(data);

    if (len <= 0 || static_cast<size_t>(len) > MAX_CHUNK_SIZE) {
        LOGI("writeFileChunkNative: invalid length %d", (int)len);
        if (fd >= 0) close(fd);
        return JNI_FALSE;
    }

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    const char* targetName = env->GetStringUTFChars(targetFileName, nullptr);

    jbyte* body = env->GetByteArrayElements(data, nullptr);

    bool success = false;
    if (prepareSession(fd, nativePass, pim, volId, false)) {
        if (ensureMounted(volId)) {
            FIL f;
            std::string fatPath = std::string(drivePaths[volId]) + "/" + targetName;
            BYTE openMode = (offset == 0)
                ? (FA_WRITE | FA_CREATE_ALWAYS)
                : (FA_WRITE | FA_OPEN_ALWAYS);
            if (f_open(&f, fatPath.c_str(), openMode) == FR_OK) {
                if (f_lseek(&f, static_cast<FSIZE_t>(offset)) == FR_OK) {
                    UINT bw = 0;
                    if (f_write(&f, body, static_cast<UINT>(len), &bw) == FR_OK &&
                        bw == static_cast<UINT>(len)) {
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
    return success ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_getFolderSizeNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim,
        jstring dirPath, jint volId) {

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    const char* nativePath = env->GetStringUTFChars(dirPath, nullptr);

    jlong total = 0;
    if (prepareSession(fd, nativePass, pim, volId, false)) {
        if (ensureMounted(volId)) {
            total = static_cast<jlong>(recursiveFolderSize(volId, nativePath));
        }
    }

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(dirPath, nativePath);
    return total;
}

// ----------------------------------------------------------------====
// PBKDF2-SHA512
// ----------------------------------------------------------------====

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_hashPasswordNative(
        JNIEnv* env, jobject,
        jstring password, jbyteArray salt, jint iterations) {

    if (password == nullptr || salt == nullptr) return nullptr;

    const jsize saltLen = env->GetArrayLength(salt);
    if (saltLen == 0) return nullptr;

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    jbyte* saltData        = env->GetByteArrayElements(salt, nullptr);

    unsigned char out[64] = {0};
    jbyteArray result     = nullptr;

    const unsigned int safeIter =
        (iterations > 0) ? static_cast<unsigned int>(iterations) : 200000u;

    MdContextGuard mdGuard;
    if (mbedtls_md_setup(&mdGuard.ctx,
            mbedtls_md_info_from_type(MBEDTLS_MD_SHA512), 1) == 0) {
        int rc = mbedtls_pkcs5_pbkdf2_hmac(
            &mdGuard.ctx,
            reinterpret_cast<const unsigned char*>(nativePass), strlen(nativePass),
            reinterpret_cast<const unsigned char*>(saltData), static_cast<size_t>(saltLen),
            safeIter, 64, out);

        if (rc == 0) {
            result = env->NewByteArray(64);
            env->SetByteArrayRegion(result, 0, 64, reinterpret_cast<jbyte*>(out));
        } else {
            LOGI("hashPasswordNative: PBKDF2 failed, rc=%d", rc);
        }
    }

    mbedtls_platform_zeroize(out, sizeof(out));

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseByteArrayElements(salt, saltData, JNI_ABORT);

    return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_readFileChunkDirectNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim,
        jstring targetFileName, jlong offset, jbyteArray outBuffer, jint length, jint volId) {

    if (length <= 0) return 0;

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    const char* targetName = env->GetStringUTFChars(targetFileName, nullptr);

    jint bytesRead = -1;

    // Passing fd=-1 is fine here because prepareSession knows to use activeFd[volId]
    if (prepareSession(fd, nativePass, pim, volId, false)) {
        if (ensureMounted(volId)) {
            FIL f;
            std::string fatPath = std::string(drivePaths[volId]) + "/" + targetName;
            if (f_open(&f, fatPath.c_str(), FA_READ) == FR_OK) {
                f_lseek(&f, static_cast<FSIZE_t>(offset));
                
                // ZERO-COPY: Get a direct pointer to the Kotlin byte array!
                jbyte* destBuf = env->GetByteArrayElements(outBuffer, nullptr);
                if (destBuf != nullptr) {
                    UINT br = 0;
                    if (f_read(&f, destBuf, static_cast<UINT>(length), &br) == FR_OK) {
                        bytesRead = static_cast<jint>(br);
                    }
                    // Release and commit the changes back to Kotlin memory
                    env->ReleaseByteArrayElements(outBuffer, destBuf, 0);
                }
                f_close(&f);
            }
        }
    }

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(targetFileName, targetName);
    return bytesRead;
}


// 1. OPEN STREAM
extern "C" JNIEXPORT jlong JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_openStreamNative(
        JNIEnv* env, jobject,
        jint fd, jstring password, jint pim,
        jstring targetFileName, jint volId) {

    const char* nativePass = env->GetStringUTFChars(password, nullptr);
    const char* targetName = env->GetStringUTFChars(targetFileName, nullptr);
    jlong streamPtr = 0;

    if (prepareSession(fd, nativePass, pim, volId, false)) {
        if (ensureMounted(volId)) {
            FIL* f = new FIL(); // Allocate on heap
            std::string fatPath = std::string(drivePaths[volId]) + "/" + targetName;
            
            if (f_open(f, fatPath.c_str(), FA_READ) == FR_OK) {
                streamPtr = reinterpret_cast<jlong>(f); // Pass pointer to Kotlin
            } else {
                delete f;
            }
        }
    }

    env->ReleaseStringUTFChars(password, nativePass);
    env->ReleaseStringUTFChars(targetFileName, targetName);
    return streamPtr;
}

// 2. READ STREAM (Zero-Copy)
extern "C" JNIEXPORT jint JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_readStreamNative(
        JNIEnv* env, jobject,
        jlong streamPtr, jlong offset, jbyteArray outBuffer, jint length, jint volId) {
    
    if (streamPtr == 0 || length <= 0) return -1;
    
    FIL* f = reinterpret_cast<FIL*>(streamPtr);
    jint bytesRead = -1;

    // Fast seek using already-loaded cluster chains
    f_lseek(f, static_cast<FSIZE_t>(offset));

    jbyte* destBuf = env->GetByteArrayElements(outBuffer, nullptr);
    if (destBuf != nullptr) {
        UINT br = 0;
        if (f_read(f, destBuf, static_cast<UINT>(length), &br) == FR_OK) {
            bytesRead = static_cast<jint>(br);
        }
        env->ReleaseByteArrayElements(outBuffer, destBuf, 0); // 0 = commit changes back
    }
    
    return bytesRead;
}

// 3. CLOSE STREAM
extern "C" JNIEXPORT void JNICALL
Java_com_aeidolon_vaultexplorer_VeraCryptEngine_closeStreamNative(
        JNIEnv* env, jobject, jlong streamPtr, jint volId) {
    
    if (streamPtr != 0) {
        FIL* f = reinterpret_cast<FIL*>(streamPtr);
        f_close(f);
        delete f; // Free memory
    }
}