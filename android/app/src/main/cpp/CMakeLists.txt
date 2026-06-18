cmake_minimum_required(VERSION 3.18.0)

project("cryptbridge")

# 1. Download mbedTLS (Encryption Engine)
include(FetchContent)
FetchContent_Declare(
        mbedtls
        GIT_REPOSITORY https://github.com/Mbed-TLS/mbedtls.git
        GIT_TAG        v3.6.0
)
set(ENABLE_TESTING OFF CACHE BOOL "Disable mbedtls tests")
set(ENABLE_PROGRAMS OFF CACHE BOOL "Disable mbedtls programs")
FetchContent_MakeAvailable(mbedtls)

# 2. Download ChaN's FatFs (Filesystem Engine)
FetchContent_Declare(
        fatfs
        GIT_REPOSITORY https://github.com/stm32duino/FatFs.git
        GIT_TAG        main
)
FetchContent_MakeAvailable(fatfs)

# 3. Create the build target including FatFs source files directly!
add_library(
        cryptbridge
        SHARED
        cryptbridge.cpp
        ${fatfs_SOURCE_DIR}/src/ff.c
        ${fatfs_SOURCE_DIR}/src/ffunicode.c # Required for Long File Names (LFN)
)

# 4. Point the compiler to where headers are located
target_include_directories(
        cryptbridge PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}        # Local folder for ffconf.h
        ${mbedtls_SOURCE_DIR}/include
        ${fatfs_SOURCE_DIR}/src            # FatFs header folder
)

find_library(log-lib log)

# Link libraries (No more -lFatFs error!)
target_link_libraries(
        cryptbridge
        ${log-lib}
        mbedcrypto)