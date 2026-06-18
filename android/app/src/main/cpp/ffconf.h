#ifndef _FFCONF
#define _FFCONF 80286   /* Revision ID */
#define FFCONF_DEF 80286 /* FatFs R0.15 Revision Guard */

/*---------------------------------------------------------------------------/
/ Function Configurations
/---------------------------------------------------------------------------*/

#define FF_FS_READONLY  0      /* 0:Read/Write or 1:Read-Only */
#define FF_FS_MINIMIZE  0      /* 0: Fully functional (f_opendir, f_readdir, f_unlink enabled) */
#define FF_USE_STRFUNC  1      /* 1: Enable string functions */
#define FF_USE_FIND     0      /* Disable filtered directory search */
#define FF_USE_MKFS     1      /* 1: Enable f_mkfs formatting functions */
#define FF_USE_FASTSEEK 0      /* Disable fast seek */
#define FF_USE_EXPAND   0      /* Disable contiguous sector allocation */
#define FF_USE_CHMOD    0      /* Disable metadata modifications */
#define FF_USE_LABEL    1      /* Enable volume labels */
#define FF_USE_FORWARD  0      /* Disable stream forwarding */

/*---------------------------------------------------------------------------/
/ Locale and Namespace Configurations
/---------------------------------------------------------------------------*/

#define FF_CODE_PAGE    437    /* U.S. English code page */
#define FF_USE_LFN      2      /* 2: Enable Long File Names with dynamic heap (Solves the LFN garbage issue!) */
#define FF_MAX_LFN      255    /* Maximum LFN length */
#define FF_LFN_UNICODE  0      /* 0: ANSI/OEM code page filenames (easiest for Android JNI) */
#define FF_LFN_BUF      255
#define FF_SFN_BUF      12

#define FF_FS_RPATH     0      /* Disable relative pathing */

/*---------------------------------------------------------------------------/
/ Drive/Volume Configurations
/---------------------------------------------------------------------------*/

#define FF_VOLUMES      4      /* We only need 1 active mount volume at a time */
#define FF_STR_VOLUME_ID 0     /* Use simple 0-based drive numbers */
#define FF_MULTI_PARTITION 0   /* 0: Single partition drives */
#define FF_MIN_SS       512    /* Minimum sector size */
#define FF_MAX_SS       512    /* Maximum sector size (VeraCrypt standard) */
#define FF_LBA64        0      /* 0: Disable 64-bit LBA (Solves the compilation error!) */
#define FF_MIN_GPT      0x10000000 /* Minimum sectors to use GPT partition tables */
#define FF_USE_TRIM     0      /* Disable ATA Trim */
#define FF_FS_NOFSINFO  0      /* Check FAT info sectors */

/*---------------------------------------------------------------------------/
/ System Configurations
/---------------------------------------------------------------------------*/

#define FF_FS_TINY      0      /* Normal buffer system */
#define FF_FS_EXFAT     1      /* 1: Enable exFAT support! */
#define FF_FS_NORTC     1      /* 1: System has no real-time clock hardware */
#define FF_NORTC_YEAR   2026
#define FF_NORTC_MON    6
#define FF_NORTC_MDAY   17

#define FF_FS_LOCK      0      /* Disable file locking */
#define FF_FS_REENTRANT 0      /* Disable re-entrancy (We protect this via JNI threads) */

#endif /* _FFCONF */