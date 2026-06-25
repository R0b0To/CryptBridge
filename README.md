# VaultExplorer [![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/K3K2ND3Y8)

**A native Android file manager for VeraCrypt encrypted containers — no PC required.**

VaultExplorer lets you mount, browse, and manage VeraCrypt volumes directly on your Android device. Built with Flutter and a custom C++ crypto engine (mbedTLS + FatFs), it decrypts and re-encrypts data fully on-device with zero temporary plaintext files on device storage.

---

## Features

### Encryption & Compatibility
- Full **AES-256-XTS** decryption and encryption matching the VeraCrypt standard
- **PBKDF2-SHA512** key derivation with configurable PIM support
- Compatible with containers created by the desktop VeraCrypt application
- Supports both **FAT32** and **exFAT** formatted volumes
- Create new VeraCrypt containers directly from the app

### File Management
- Browse directories with a breadcrumb navigation bar
- **List view** and **gallery/grid view** with live thumbnails
- Multi-select with batch operations: copy, move (cut), delete, rename, export
- **Cross-container clipboard** — copy or move files between two mounted volumes
- Import files and entire folder trees from device storage
- Export files and folders back to device storage
- Search within the current directory
- Sort by name, size, or file type

### Media Viewer
- Built-in image viewer with pinch-to-zoom and double-tap zoom
- Video and audio playback via the `video_player` package (FFmpeg-backed via `fvp`)
- Slideshow mode with auto-advance
- Shuffle playlist across current folder or all subfolders recursively
- Playback controls: speed selection, seek by double-tap, loop, mute
- Subtitle support (`.srt` and `.vtt` files auto-detected alongside video)
- Image fit modes: best fit, fit to width, fit to height
- Image prefetch cache for smooth navigation

### Android Integration
- Exposes mounted containers as a **Documents Provider** — files appear in Android's system file picker (like Google Photos, Office apps, etc.)
- Proxy file descriptor streaming — apps read/write directly to the encrypted volume without any plaintext intermediary on disk
- Supports opening files in external apps via Android's `ACTION_VIEW` intent

### Security & App Settings
- Optional **master password** to lock the app itself on launch
- **Biometric unlock** (fingerprint / face) as an alternative to typing the master password
- Per-container settings: custom display name, saved password (obfuscated), auto-lock timer
- Auto-lock: automatically dismounts a container after a configurable idle period
- Password obfuscation for saved credentials (XOR with a key derived from the app's install path)
- Up to **8 containers** can be mounted simultaneously

---

## Architecture

```
Flutter (Dart)
  ├── Dashboard — mount/lock containers, clipboard status strip
  ├── File Browser — list/grid, breadcrumbs, selection, search, sort
  ├── Media Viewer — images, video, audio, slideshow
  ├── Settings — master password, biometric, per-container config
  └── VaultExplorerApi — MethodChannel bridge to Kotlin

Android (Kotlin)
  ├── MainActivity — MethodChannel handler, SAF file picker, import/export
  ├── VeraCryptSession — in-memory session registry (up to 4 volumes)
  ├── VeraCryptEngine — JNI wrapper for the C++ engine
  └── VeraCryptDocumentsProvider — Android Documents Provider (ContentProvider)

C++ (NDK)
  ├── vaultexplorer.cpp — crypto session, FatFs disk hooks, all JNI entry points
  ├── mbedTLS v3.6.0 — AES-XTS, PBKDF2-SHA512
  └── ChaN FatFs — FAT32 / exFAT read/write with UTF-8 LFN support
```

---

## Requirements

- Android 6.0+ (API 23)
- Android 8.0+ (API 26) required for video thumbnail generation
- NDK support (CMake build)

---

## Building

### Prerequisites
- Flutter SDK `^3.12.0`
- Android NDK (version specified in `flutter.ndkVersion`)
- CMake 3.18+

### Steps

```bash
git clone https://github.com/R0b0To/VaultExplorer.git
cd vaultexplorer
flutter pub get
flutter build apk --release
```

The C++ engine is built automatically by CMake during the Android build. mbedTLS and FatFs are fetched via `FetchContent` at build time — no manual dependency setup required.

---

## Dependencies

| Package | Purpose |
|---|---|
| `file_picker` | SAF-based container file selection |
| `path_provider` | App document/cache directory access |
| `video_player` | Video and audio playback |
| `fvp` | FFmpeg-backed video player engine |
| `local_auth` | Biometric / fingerprint unlock |
| `permission_handler` | Storage permission handling |
| `mbedTLS 3.6.0` | AES-256-XTS, PBKDF2-SHA512 (C++) |
| `ChaN FatFs` | FAT32 / exFAT filesystem (C++) |

---

## How It Works

1. **Unlock**: The app reads the 512-byte VeraCrypt header from the container file, derives the header key via PBKDF2-SHA512, decrypts the header with AES-XTS, and extracts the master key.
2. **Mount**: FatFs is initialised with custom `disk_read`/`disk_write` hooks that transparently decrypt/encrypt 512-byte sectors on every I/O call using the master key.
3. **Browse**: All file and directory operations go through FatFs over the encrypted disk layer — plaintext data never touches device storage.
4. **Stream (Documents Provider)**: For external apps, a `ProxyFileDescriptor` is created that serves read/write calls chunk-by-chunk directly through the JNI engine, enabling seamless integration with Android's system file picker.

---

## Limitations

- **Android only** (the native engine uses Android JNI / NDK APIs)
- Hidden volumes are not currently supported
- Keyfiles are not currently supported

---

## Acknowledgements

- [VeraCrypt](https://veracrypt.fr) — the open-source disk encryption standard this app is compatible with
- [Mbed TLS](https://github.com/Mbed-TLS/mbedtls) — embedded TLS and crypto library
- [ChaN FatFs](http://elm-chan.org/fsw/ff/) — lightweight FAT/exFAT filesystem module
