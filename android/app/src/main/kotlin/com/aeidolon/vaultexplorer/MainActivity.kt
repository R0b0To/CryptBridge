package com.aeidolon.vaultexplorer

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.annotation.NonNull
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import android.content.ClipboardManager
import android.content.ClipData
import android.content.Context
import android.os.Build
import android.os.ParcelFileDescriptor
import android.annotation.TargetApi
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaDataSource
import android.media.MediaMetadataRetriever
import java.io.ByteArrayOutputStream
import java.io.InputStream

private object ChannelMethods {
    const val PICK_CONTAINER      = "pickContainer"
    const val CREATE_CONTAINER    = "createContainer"
    const val UNLOCK_CONTAINER    = "unlockContainer"
    const val LOCK_CONTAINER      = "lockContainer"
    const val DECRYPT_FILE        = "decryptFile"
    const val EXPORT_FILE         = "exportFileToStorage"
    const val EXPORT_FILES_FOLDER = "exportFilesToFolder"
    const val IMPORT_FILE         = "importFile"
    const val IMPORT_FOLDER       = "importFolder"
    const val GET_FILE_SIZE       = "getFileSize"
    const val READ_FILE_CHUNK     = "readFileChunk"
    const val WRITE_BACK_FILE     = "writeBackFile"
    const val GET_SPACE_INFO      = "getSpaceInfo"
    const val LIST_DIRECTORY      = "listDirectory"
    const val CREATE_DIRECTORY    = "createDirectory"
    const val RENAME_FILE         = "renameFile"
    const val DELETE_FILE         = "deleteFile"
    const val OPEN_WITH_APP       = "openWithApp"
    const val GET_VIDEO_THUMBNAIL = "getVideoThumbnail"
    const val GET_IMAGE_THUMBNAIL = "getImageThumbnail"
    const val GENERATE_AND_CACHE_THUMBNAIL = "generateAndCacheThumbnail"
    const val GET_FOLDER_SIZE = "getFolderSize"
    const val HASH_PASSWORD       = "hashPassword"
    const val WRITE_FILE_CHUNK    = "writeFileChunk"
}

private const val MAX_CHUNK_BYTES = 64 * 1024 * 1024  // 64 MB

class MainActivity : FlutterFragmentActivity() {

    companion object {
        private val createContainerLock = Object()
    }

    private val CHANNEL = "com.aeidolon.vaultexplorer/engine"
    private val PICK_CONTAINER_REQUEST     = 1001
    private val IMPORT_FILE_REQUEST        = 1002
    private val EXPORT_FILE_REQUEST        = 1003
    private val CREATE_CONTAINER_REQUEST   = 1004
    private val EXPORT_FILES_TREE_REQUEST  = 1006
    private val IMPORT_FOLDER_TREE_REQUEST = 1007

    private var pendingFlutterResult: MethodChannel.Result? = null

    private var pendingImportContainerUri: String? = null
    private var pendingImportTargetName: String?   = null
    private var pendingImportVolId: Int?            = null

    private var pendingExportContainerUri: String? = null
    private var pendingExportSourcePath: String?   = null
    private var pendingExportVolId: Int            = 0

    private var pendingCreateName: String?       = null
    private var pendingCreateSize: Long          = 0L
    private var pendingCreatePassword: String?   = null
    private var pendingCreatePim: Int            = 0
    private var pendingCreateFileSystem: String? = null

    private var pendingImportFolderContainerUri: String? = null
    private var pendingImportFolderTargetDir: String?    = null
    private var pendingImportFolderVolId: Int?           = null

    private var pendingExportMultiContainerUri: String?           = null
    private var pendingExportMultiItems: List<Map<String, Any?>>? = null
    private var pendingExportMultiVolId: Int                       = 0
    /**
 * Scales [src] so its longer edge is exactly [maxEdge] pixels,
 * preserving the original aspect ratio.
 *
 * Returns [src] unchanged if it already fits within [maxEdge] × [maxEdge].
 * The caller is responsible for recycling the returned bitmap if it differs
 * from [src].
 */
private fun scaledToFit(src: Bitmap, maxEdge: Int): Bitmap {
    val w = src.width
    val h = src.height
    if (w <= maxEdge && h <= maxEdge) return src          // Already small enough.
    val scale = maxEdge.toFloat() / maxOf(w, h)
    val dstW  = (w * scale).toInt().coerceAtLeast(1)
    val dstH  = (h * scale).toInt().coerceAtLeast(1)
    return Bitmap.createScaledBitmap(src, dstW, dstH, true)
}
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) sanitizeClipboard()
    }

    private fun sanitizeClipboard() {
        try {
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
            if (clipboard.hasPrimaryClip()) {
                val description = clipboard.primaryClipDescription
                if (description != null) {
                    var isCorrupt = false
                    for (i in 0 until description.mimeTypeCount) {
                        if (description.getMimeType(i) == null) { isCorrupt = true; break }
                    }
                    if (isCorrupt) {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                            clipboard.clearPrimaryClip()
                        else {
                            @Suppress("DEPRECATION")
                            clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
                        }
                    }
                }
            }
        } catch (_: Exception) {}
    }

    private fun encodeKey(filePath: String): String {
        val bytes = filePath.toByteArray(Charsets.UTF_8)
        // Matches Dart's base64Url encoding layout
        val encoded = android.util.Base64.encodeToString(bytes, android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP)
        val trimmed = encoded.trim()
        return if (trimmed.length > 180) trimmed.substring(0, 180) else trimmed
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    ChannelMethods.PICK_CONTAINER -> {
                        pendingResultCheck(result)
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        startActivityForResult(intent, PICK_CONTAINER_REQUEST)
                    }

                    ChannelMethods.CREATE_CONTAINER -> {
                        pendingResultCheck(result)
                        pendingCreateName       = call.argument<String>("displayName")
                        pendingCreateSize       = call.argument<Number>("sizeBytes")?.toLong() ?: 0L
                        pendingCreatePassword   = call.argument<String>("password")
                        pendingCreatePim        = call.argument<Number>("pim")?.toInt() ?: 0
                        pendingCreateFileSystem = call.argument<String>("fileSystem")
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/octet-stream"
                            putExtra(Intent.EXTRA_TITLE, pendingCreateName ?: "vault.tc")
                        }
                        startActivityForResult(intent, CREATE_CONTAINER_REQUEST)
                    }

                    ChannelMethods.UNLOCK_CONTAINER -> {
                        val uriString   = call.argument<String>("filePath")
                        val password    = call.argument<String>("password")
                        val pim         = call.argument<Number>("pim")?.toInt() ?: 0
                        val displayName = call.argument<String>("displayName")
                        val docProvider = call.argument<Boolean>("documentProvider") ?: false

                        if (uriString == null || password == null) {
                            result.error("INVALID_ARGS", "filePath and password required", null)
                            return@setMethodCallHandler
                        }

                        val targetVolId = VeraCryptSession.getVolumeIdByUri(uriString)
                            ?: VeraCryptSession.getFreeVolumeId()
                        if (targetVolId == null) {
                            result.error("MAX_CONTAINERS", "Maximum 8 containers already mounted", null)
                            return@setMethodCallHandler
                        }

                        Thread {
                            try {
                                val uri = Uri.parse(uriString)
                                val pfd = contentResolver.openFileDescriptor(uri, "rw")
                                    ?: throw Exception("Could not open file descriptor")
                                val fd = pfd.detachFd()

                                val files = synchronized(VeraCryptSession.locks[targetVolId]) {
                                    VeraCryptEngine.unlockAndListNative(fd, password, pim, targetVolId)
                                }

                                runOnUiThread {
                                    if (files != null) {
                                        VeraCryptSession.activeSessions[targetVolId] = ContainerSession(
                                            uri = uriString,
                                            volId = targetVolId,
                                            cachedFilesList = files.toList(),
                                            displayName = displayName,
                                            documentProvider = docProvider,
                                        )
                                        if (docProvider) {
                                            contentResolver.notifyChange(
                                                DocumentsContract.buildRootsUri(
                                                    "com.aeidolon.vaultexplorer.documents"), null)
                                        }
                                        result.success(mapOf(
                                            "volId" to targetVolId,
                                            "files" to files.toList()
                                        ))
                                    } else {
                                        result.error("AUTH_FAIL",
                                            "Incorrect password or invalid container", null)
                                    }
                                }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_ERROR", e.message, null) }
                            }
                        }.start()
                    }

                    ChannelMethods.HASH_PASSWORD -> {
                        val password   = call.argument<String>("password")
                        val saltBytes  = call.argument<ByteArray>("salt")
                        val iterations = call.argument<Int>("iterations") ?: 200_000

                        if (password == null || saltBytes == null || saltBytes.isEmpty()) {
                            result.error("INVALID_ARGS", "password and non-empty salt required", null)
                            return@setMethodCallHandler
                        }

                        Thread {
                            val hash = VeraCryptEngine.hashPasswordNative(password, saltBytes, iterations)
                            runOnUiThread {
                                if (hash != null) result.success(hash)
                                else result.error("KDF_FAILED", "PBKDF2 derivation failed", null)
                            }
                        }.start()
                    }

                    ChannelMethods.GET_VIDEO_THUMBNAIL -> {
                        val uriString = call.argument<String>("filePath")
                        val fileName  = call.argument<String>("fileName")

                        if (uriString == null || fileName == null) {
                            result.error("INVALID_ARGS", "filePath and fileName required", null)
                            return@setMethodCallHandler
                        }

                        Thread {
                            var retriever: MediaMetadataRetriever? = null
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                                    ?: run {
                                        runOnUiThread {
                                            result.error("NOT_MOUNTED", "Container not mounted", null)
                                        }
                                        return@Thread
                                    }

                                retriever = MediaMetadataRetriever()

                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                    val dataSource = VeraCryptMediaDataSource(this, uriString, fileName, volId)
                                    retriever.setDataSource(dataSource)

                                    val durationMs = retriever
                                        .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                                        ?.toLongOrNull() ?: 10_000L
                                    val timeMs = minOf(1000L, durationMs / 4)

                                    val frame = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                                        runCatching {
                                            retriever.getScaledFrameAtTime(
                                                timeMs * 1000L,
                                                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                                                180, 180)
                                        }.getOrNull()
                                            ?: retriever.getFrameAtTime(timeMs * 1000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                                    } else {
                                        retriever.getFrameAtTime(timeMs * 1000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                                    }

                                    if (frame != null) {
                                        val stream = ByteArrayOutputStream()
                                        frame.compress(Bitmap.CompressFormat.JPEG, 60, stream)
                                        val bytes = stream.toByteArray()
                                        runOnUiThread { result.success(bytes) }
                                    } else {
                                        runOnUiThread { result.error("FRAME_FAILED", "Failed to extract frame", null) }
                                    }
                                } else {
                                    runOnUiThread { result.error("UNSUPPORTED_OS", "Requires Android 6.0+", null) }
                                }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("THUMBNAIL_ERROR", e.message, null) }
                            } finally {
                                runCatching { retriever?.release() }
                            }
                        }.start()
                    }

                    ChannelMethods.GET_IMAGE_THUMBNAIL -> {
                        val uriString  = call.argument<String>("filePath")
                        val fileName   = call.argument<String>("fileName")
                        val targetSize = call.argument<Int>("targetSize") ?: 180

                        if (uriString == null || fileName == null) {
                            result.error("INVALID_ARGS", "filePath and fileName required", null)
                            return@setMethodCallHandler
                        }

                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                                    ?: run {
                                        runOnUiThread { result.error("NOT_MOUNTED", "Container not mounted", null) }
                                        return@Thread
                                    }

                                val inputStream = VeraCryptInputStream(this, uriString, fileName, volId)
                                
                                val options = BitmapFactory.Options().apply {
                                    inJustDecodeBounds = true
                                }
                                BitmapFactory.decodeStream(inputStream, null, options)
                                inputStream.reset()

                                val width = options.outWidth
                                val height = options.outHeight

                                var inSampleSize = 1
                                if (width > targetSize || height > targetSize) {
                                    val halfWidth = width / 2
                                    val halfHeight = height / 2
                                    while (halfWidth / inSampleSize >= targetSize && halfHeight / inSampleSize >= targetSize) {
                                        inSampleSize *= 2
                                    }
                                }

                                val decodeOptions = BitmapFactory.Options().apply {
                                    this.inSampleSize = inSampleSize
                                }
                                val rawBitmap = BitmapFactory.decodeStream(inputStream, null, decodeOptions)
                                inputStream.close()

                                if (rawBitmap != null) {
    val scaledBitmap = scaledToFit(rawBitmap, targetSize)
    if (scaledBitmap != rawBitmap) rawBitmap.recycle()

    val stream = ByteArrayOutputStream()
    scaledBitmap.compress(Bitmap.CompressFormat.JPEG, 75, stream)
    val bytes = stream.toByteArray()
    scaledBitmap.recycle()

    runOnUiThread { result.success(bytes) }
} else {
    runOnUiThread { result.error("DECODE_FAILED", "Failed to decode image bytes", null) }
}
                            } catch (e: Exception) {
                                runOnUiThread { result.error("THUMBNAIL_ERROR", e.message, null) }
                            }
                        }.start()
                    }

                    // ── OPTIMIZATION: FIRE-AND-FORGET BACKGROUND CACHE GENERATION ──
                    ChannelMethods.GENERATE_AND_CACHE_THUMBNAIL -> {
                        val uriString = call.argument<String>("filePath")
                        val fileName  = call.argument<String>("fileName")
                        val keyBytes  = call.argument<ByteArray>("keyBytes")
                        val targetSize = 180

                        if (uriString == null || fileName == null || keyBytes == null) {
                            result.success(null)
                            return@setMethodCallHandler
                        }

                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: return@Thread
                                val inputStream = VeraCryptInputStream(this, uriString, fileName, volId)
                                
                                val options = BitmapFactory.Options().apply {
                                    inJustDecodeBounds = true
                                }
                                BitmapFactory.decodeStream(inputStream, null, options)
                                inputStream.reset()

                                val width = options.outWidth
                                val height = options.outHeight

                                var inSampleSize = 1
                                if (width > targetSize || height > targetSize) {
                                    val halfWidth = width / 2
                                    val halfHeight = height / 2
                                    while (halfWidth / inSampleSize >= targetSize && halfHeight / inSampleSize >= targetSize) {
                                        inSampleSize *= 2
                                    }
                                }

                                val decodeOptions = BitmapFactory.Options().apply {
                                    this.inSampleSize = inSampleSize
                                }
                                val rawBitmap = BitmapFactory.decodeStream(inputStream, null, decodeOptions)
                                inputStream.close()

                                if (rawBitmap != null) {
                                    val scaledBitmap = Bitmap.createScaledBitmap(rawBitmap, targetSize, targetSize, true)
                                    if (scaledBitmap != rawBitmap) {
                                        rawBitmap.recycle()
                                    }

                                    val stream = ByteArrayOutputStream()
                                    scaledBitmap.compress(Bitmap.CompressFormat.JPEG, 70, stream)
                                    val thumbData = stream.toByteArray()
                                    scaledBitmap.recycle()

                                    // Hardware AES-GCM Encrypt natively (12-byte random IV)
                                    val secureRandom = java.security.SecureRandom()
                                    val nonce = ByteArray(12)
                                    secureRandom.nextBytes(nonce)

                                    val secretKeySpec = javax.crypto.spec.SecretKeySpec(keyBytes, "AES")
                                    val gcmParameterSpec = javax.crypto.spec.GCMParameterSpec(128, nonce)

                                    val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
                                    cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, secretKeySpec, gcmParameterSpec)
                                    val encryptedData = cipher.doFinal(thumbData)

                                    // Concat: [nonce (12)] + [ciphertext + 16-byte GCM tag]
                                    val outBytes = ByteArray(nonce.size + encryptedData.size)
                                    System.arraycopy(nonce, 0, outBytes, 0, nonce.size)
                                    System.arraycopy(encryptedData, 0, outBytes, nonce.size, encryptedData.size)

                                    val cacheDir = this.cacheDir
                                    val volDir = File(cacheDir, "thumbs/$volId")
                                    if (!volDir.exists()) volDir.mkdirs()

                                    val encodedKey = encodeKey(fileName)
                                    val file = File(volDir, encodedKey)

                                    val tmpFile = File(volDir, "$encodedKey.tmp")
                                    tmpFile.writeBytes(outBytes)
                                    tmpFile.renameTo(file)
                                }
                            } catch (_: Exception) {}
                        }.start()

                        result.success(null) // Exit channel task immediately, non-blocking
                    }

                    ChannelMethods.LOCK_CONTAINER -> {
                        val uriString = call.argument<String>("filePath")
                        if (uriString == null) {
                            result.error("INVALID_ARGS", "filePath is required", null)
                            return@setMethodCallHandler
                        }
                        val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                        if (volId != null) {
                            Thread {
                                synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.lockNative(volId)
                                }
                                VeraCryptSession.removeSession(volId)
                                runOnUiThread {
                                    contentResolver.notifyChange(
                                        DocumentsContract.buildRootsUri(
                                            "com.aeidolon.vaultexplorer.documents"), null)
                                    result.success(true)
                                }
                            }.start()
                        } else {
                            result.success(false)
                        }
                    }

                    ChannelMethods.DECRYPT_FILE -> {
                        val uriString = call.argument<String>("filePath")
                        val fileName  = call.argument<String>("fileName")
                        val destPath  = call.argument<String>("destPath")
                        if (uriString == null || fileName == null || destPath == null) {
                            result.error("INVALID_ARGS", "All arguments required", null); return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                                    ?: run {
                                        runOnUiThread { result.error("NOT_MOUNTED", "Container not mounted", null) }
                                        return@Thread
                                    }
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.unlockAndExtractNative(-1, "", 0, fileName, destPath, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) { runOnUiThread { result.error("C++_CRASH", e.message, null) } }
                        }.start()
                    }

                    ChannelMethods.GET_FILE_SIZE -> {
                        val uriString = call.argument<String>("filePath")
                        val fileName  = call.argument<String>("fileName")
                        if (uriString == null || fileName == null) {
                            result.error("INVALID_ARGS", "filePath and fileName required", null); return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                                    ?: run {
                                        runOnUiThread { result.error("NOT_MOUNTED", "Container not mounted", null) }
                                        return@Thread
                                    }
                                val size = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.getFileSizeNative(-1, "", 0, fileName, volId)
                                }
                                runOnUiThread { result.success(size) }
                            } catch (e: Exception) { runOnUiThread { result.error("C++_CRASH", e.message, null) } }
                        }.start()
                    }

                    ChannelMethods.GET_FOLDER_SIZE -> {
        val uriString = call.argument<String>("filePath")
        val dirPath   = call.argument<String>("dirPath") ?: ""
        if (uriString == null) {
            result.error("INVALID_ARGS", "filePath is required", null)
            return@setMethodCallHandler
        }
        Thread {
            try {
                val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                    ?: run {
                        runOnUiThread { result.error("NOT_MOUNTED", "Container not mounted", null) }
                        return@Thread
                    }
                val total = synchronized(VeraCryptSession.locks[volId]) {
                    VeraCryptEngine.getFolderSizeNative(-1, "", 0, dirPath, volId)
                }
                runOnUiThread { result.success(total) }
            } catch (e: Exception) {
                runOnUiThread { result.error("C++_ERROR", e.message, null) }
            }
        }.start()
    }

                    ChannelMethods.READ_FILE_CHUNK -> {
                        val uriString = call.argument<String>("filePath")
                        val fileName  = call.argument<String>("fileName")
                        val offset    = call.argument<Number>("offset")?.toLong() ?: 0L
                        val length    = call.argument<Number>("length")?.toInt() ?: 0

                        if (uriString == null || fileName == null) {
                            result.error("INVALID_ARGS", "filePath and fileName required", null); return@setMethodCallHandler
                        }
                        if (length <= 0 || length > MAX_CHUNK_BYTES) {
                            result.error("INVALID_ARGS", "length must be between 1 and $MAX_CHUNK_BYTES bytes", null)
                            return@setMethodCallHandler
                        }

                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                                    ?: run {
                                        runOnUiThread { result.error("NOT_MOUNTED", "Container not mounted", null) }
                                        return@Thread
                                    }
                                val bytes = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.readFileChunkNative(-1, "", 0, fileName, offset, length, volId)
                                }
                                runOnUiThread { result.success(bytes) }
                            } catch (e: Exception) { runOnUiThread { result.error("C++_CRASH", e.message, null) } }
                        }.start()
                    }

                    ChannelMethods.LIST_DIRECTORY -> {
                        val uriString = call.argument<String>("filePath")
                        val dirPath   = call.argument<String>("dirPath") ?: ""
                        if (uriString == null) {
                            result.error("INVALID_ARGS", "filePath is required", null); return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                                    ?: run {
                                        runOnUiThread { result.error("NOT_MOUNTED", "Container not mounted", null) }
                                        return@Thread
                                    }
                                val files = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.listDirectoryNative(-1, "", 0, dirPath, volId)
                                }
                                runOnUiThread { result.success(files?.toList()) }
                            } catch (e: Exception) { runOnUiThread { result.error("C++_ERROR", e.message, null) } }
                        }.start()
                    }

                    ChannelMethods.CREATE_DIRECTORY -> {
                        val uriString = call.argument<String>("filePath")
                        val dirPath   = call.argument<String>("dirPath")
                        if (uriString == null || dirPath == null) {
                            result.error("INVALID_ARGS", "All arguments required", null); return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                                    ?: run {
                                        runOnUiThread { result.error("NOT_MOUNTED", "Container not mounted", null) }
                                        return@Thread
                                    }
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.createDirectoryNative(-1, "", 0, dirPath, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) { runOnUiThread { result.error("C++_ERROR", e.message, null) } }
                        }.start()
                    }

                    ChannelMethods.RENAME_FILE -> {
                        val uriString = call.argument<String>("filePath")
                        val oldPath   = call.argument<String>("oldPath")
                        val newPath   = call.argument<String>("newPath")
                        if (uriString == null || oldPath == null || newPath == null) {
                            result.error("INVALID_ARGS", "All arguments required", null); return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                                    ?: run {
                                        runOnUiThread { result.error("NOT_MOUNTED", "Container not mounted", null) }
                                        return@Thread
                                    }
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.renameFileNative(-1, "", 0, oldPath, newPath, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) { runOnUiThread { result.error("C++_ERROR", e.message, null) } }
                        }.start()
                    }

                    ChannelMethods.WRITE_BACK_FILE -> {
                        val uriString  = call.argument<String>("filePath")
                        val fileName   = call.argument<String>("fileName")
                        val sourcePath = call.argument<String>("sourcePath")
                        if (uriString == null || fileName == null || sourcePath == null) {
                            result.error("INVALID_ARGS", "All arguments required", null); return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                                    ?: run {
                                        runOnUiThread { result.error("NOT_MOUNTED", "Container not mounted", null) }
                                        return@Thread
                                    }
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.writeBackFileNative(-1, "", 0, fileName, sourcePath, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) { runOnUiThread { result.error("C++_ERROR", e.message, null) } }
                        }.start()
                    }

                    ChannelMethods.GET_SPACE_INFO -> {
                        val uriString = call.argument<String>("filePath")
                        if (uriString == null) {
                            result.error("INVALID_ARGS", "filePath is required", null); return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                                    ?: run {
                                        runOnUiThread { result.error("NOT_MOUNTED", "Container not mounted", null) }
                                        return@Thread
                                    }
                                val space = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.getSpaceInfoNative(-1, "", 0, volId)
                                }
                                runOnUiThread { result.success(space?.toList()) }
                            } catch (e: Exception) { runOnUiThread { result.error("C++_CRASH", e.message, null) } }
                        }.start()
                    }

                    ChannelMethods.DELETE_FILE -> {
                        val uriString = call.argument<String>("filePath")
                        val fileName  = call.argument<String>("fileName")
                        if (uriString == null || fileName == null) {
                            result.error("INVALID_ARGS", "All arguments required", null); return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                                    ?: run {
                                        runOnUiThread { result.error("NOT_MOUNTED", "Container not mounted", null) }
                                        return@Thread
                                    }
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.deleteFileNative(-1, "", 0, fileName, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) { runOnUiThread { result.error("C++_ERROR", e.message, null) } }
                        }.start()
                    }

                    ChannelMethods.OPEN_WITH_APP -> {
                        val uriString = call.argument<String>("filePath")
                        val fileName  = call.argument<String>("fileName")
                        if (uriString == null || fileName == null) {
                            result.error("INVALID_ARGS", "filePath and fileName required", null); return@setMethodCallHandler
                        }
                        try {
                            val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                                ?: run {
                                    result.error("NOT_MOUNTED", "Container not mounted", null)
                                    return@setMethodCallHandler
                                }
                            val docUri = DocumentsContract.buildDocumentUri(
                                "com.aeidolon.vaultexplorer.documents", "$volId:file:$fileName")
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(docUri, getMimeType(fileName))
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                         Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                            }
                            startActivity(Intent.createChooser(intent, "Open file with…"))
                            result.success(true)
                        } catch (e: Exception) { result.error("OPEN_WITH_ERROR", e.message, null) }
                    }

                    ChannelMethods.IMPORT_FILE -> {
                        pendingResultCheck(result)
                        val containerUri = call.argument<String>("filePath")
                        if (containerUri == null) {
                            result.error("INVALID_ARGS", "filePath is required", null); return@setMethodCallHandler
                        }
                        val resolvedVolId = VeraCryptSession.getVolumeIdByUri(containerUri)
                        if (resolvedVolId == null) {
                            result.error("NOT_MOUNTED", "Container is not mounted", null); return@setMethodCallHandler
                        }
                        pendingImportContainerUri = containerUri
                        pendingImportTargetName   = call.argument<String>("targetPath")
                        pendingImportVolId        = resolvedVolId
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        }, IMPORT_FILE_REQUEST)
                    }

                    ChannelMethods.EXPORT_FILES_FOLDER -> {
                        pendingResultCheck(result)
                        val containerUri = call.argument<String>("filePath")
                        if (containerUri == null) {
                            result.error("INVALID_ARGS", "filePath is required", null); return@setMethodCallHandler
                        }
                        pendingExportMultiContainerUri = containerUri
                        @Suppress("UNCHECKED_CAST")
                        pendingExportMultiItems = (call.argument<List<*>>("items"))
                            ?.mapNotNull { it as? Map<String, Any?> } ?: emptyList()
                        pendingExportMultiVolId = VeraCryptSession.getVolumeIdByUri(containerUri) ?: run {
                            result.error("NOT_MOUNTED", "Container not mounted", null)
                            return@setMethodCallHandler
                        }
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), EXPORT_FILES_TREE_REQUEST)
                    }

                    ChannelMethods.IMPORT_FOLDER -> {
                        pendingResultCheck(result)
                        val containerUri = call.argument<String>("filePath")
                        if (containerUri == null) {
                            result.error("INVALID_ARGS", "filePath is required", null); return@setMethodCallHandler
                        }
                        val resolvedVolId = VeraCryptSession.getVolumeIdByUri(containerUri)
                        if (resolvedVolId == null) {
                            result.error("NOT_MOUNTED", "Container is not mounted", null); return@setMethodCallHandler
                        }
                        pendingImportFolderContainerUri = containerUri
                        pendingImportFolderTargetDir    = call.argument<String>("targetPath") ?: ""
                        pendingImportFolderVolId        = resolvedVolId
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), IMPORT_FOLDER_TREE_REQUEST)
                    }

                    ChannelMethods.EXPORT_FILE -> {
                        pendingResultCheck(result)
                        pendingExportContainerUri = call.argument<String>("filePath")
                        pendingExportSourcePath   = call.argument<String>("sourcePath")
                        pendingExportVolId = VeraCryptSession.getVolumeIdByUri(
                            pendingExportContainerUri!!) ?: run {
                            result.error("NOT_MOUNTED", "Container not mounted", null)
                            return@setMethodCallHandler
                        }
                        val fileName = pendingExportSourcePath!!.split("/").last()
                        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = getMimeType(fileName)
                            putExtra(Intent.EXTRA_TITLE, fileName)
                        }, EXPORT_FILE_REQUEST)
                    }

                    ChannelMethods.WRITE_FILE_CHUNK -> {
                        val uriString = call.argument<String>("filePath")
                        val fileName  = call.argument<String>("fileName")
                        val offset    = call.argument<Number>("offset")?.toLong() ?: 0L
                        val data      = call.argument<ByteArray>("data")

                        if (uriString == null || fileName == null || data == null) {
                            result.error("INVALID_ARGS", "filePath, fileName and data required", null)
                            return@setMethodCallHandler
                        }
                        if (data.size > MAX_CHUNK_BYTES) {
                            result.error("INVALID_ARGS", "Chunk too large (max $MAX_CHUNK_BYTES bytes)", null)
                            return@setMethodCallHandler
                        }

                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                                    ?: run {
                                        runOnUiThread { result.error("NOT_MOUNTED", "Container not mounted", null) }
                                        return@Thread
                                    }
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.writeFileChunkNative(-1, "", 0, fileName, offset, data, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_ERROR", e.message, null) }
                            }
                        }.start()
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun pendingResultCheck(result: MethodChannel.Result) {
        pendingFlutterResult?.error("PICK_CANCELLED", "Another pick operation started", null)
        pendingFlutterResult = result
    }

    private fun resolveDisplayName(uri: Uri): String {
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME),
                null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx != -1) cursor.getString(idx) else null
                } else null
            } ?: uri.lastPathSegment ?: "Container"
        } catch (e: Exception) { uri.lastPathSegment ?: "Container" }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == PICK_CONTAINER_REQUEST) {
            val res = pendingFlutterResult ?: return; pendingFlutterResult = null
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri = data.data!!
                contentResolver.takePersistableUriPermission(uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                res.success(mapOf("uri" to uri.toString(), "displayName" to resolveDisplayName(uri)))
            } else res.success(null)
            return
        }

        if (requestCode == CREATE_CONTAINER_REQUEST) {
            val res = pendingFlutterResult ?: return; pendingFlutterResult = null
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val destUri = data.data!!
                val size = pendingCreateSize; val pass = pendingCreatePassword
                val pim = pendingCreatePim; val fs = pendingCreateFileSystem ?: "fat"
                if (pass != null && size > 0) {
                    Thread {
                        try {
                            val pfd = contentResolver.openFileDescriptor(destUri, "rw")
                                ?: throw Exception("Could not open file descriptor")
                            val success = synchronized(createContainerLock) {
                                VeraCryptEngine.createContainerNative(pfd.detachFd(), pass, pim, size, fs)
                            }
                            runOnUiThread { res.success(success) }
                        } catch (e: Exception) { runOnUiThread { res.error("CREATE_ERROR", e.message, null) } }
                    }.start()
                } else res.success(false)
            } else res.success(false)
            return
        }

        if (requestCode == IMPORT_FILE_REQUEST) {
            val res = pendingFlutterResult ?: return; pendingFlutterResult = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                val uris = mutableListOf<Uri>()
                data.clipData?.let { clip -> for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri) }
                    ?: data.data?.let { uris.add(it) }
                val containerUri = pendingImportContainerUri
                val targetDir    = pendingImportTargetName ?: ""
                val volId        = pendingImportVolId
                if (containerUri != null && volId != null && uris.isNotEmpty()) {
                    Thread {
                        var successCount = 0
                        for (pickedUri in uris) {
                            val srcDoc = DocumentFile.fromSingleUri(this, pickedUri) ?: continue
                            val name = srcDoc.name ?: "imported_file"
                            val targetFatPath = if (targetDir.isEmpty()) name else "$targetDir/$name"
                            successCount += importEntryRecursive(srcDoc, containerUri, targetFatPath, volId)
                        }
                        runOnUiThread { res.success(successCount) }
                    }.start()
                } else res.success(0)
            } else res.success(0)
            pendingImportVolId = null
            return
        }

        if (requestCode == EXPORT_FILES_TREE_REQUEST) {
            val res = pendingFlutterResult ?: return; pendingFlutterResult = null
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val treeUri = data.data!!
                contentResolver.takePersistableUriPermission(treeUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                val containerUri = pendingExportMultiContainerUri
                val items        = pendingExportMultiItems ?: emptyList()
                val volId        = pendingExportMultiVolId
                if (containerUri != null) {
                    Thread {
                        var successCount = 0
                        val destTree = DocumentFile.fromTreeUri(this, treeUri)
                        if (destTree != null) {
                            for (item in items) {
                                val path  = item["path"] as? String ?: continue
                                val isDir = item["isDir"] as? Boolean ?: false
                                successCount += exportEntryRecursive(destTree, path, isDir, containerUri, volId)
                            }
                        }
                        runOnUiThread { res.success(successCount) }
                    }.start()
                } else res.success(0)
            } else res.success(0)
            return
        }

        if (requestCode == IMPORT_FOLDER_TREE_REQUEST) {
            val res = pendingFlutterResult ?: return; pendingFlutterResult = null
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val treeUri = data.data!!
                contentResolver.takePersistableUriPermission(treeUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                val containerUri = pendingImportFolderContainerUri
                val targetDir    = pendingImportFolderTargetDir ?: ""
                val volId        = pendingImportFolderVolId
                val srcRoot      = DocumentFile.fromTreeUri(this, treeUri)
                if (containerUri != null && volId != null && srcRoot != null) {
                    val folderName    = srcRoot.name ?: "imported_folder"
                    val targetFatPath = if (targetDir.isEmpty()) folderName else "$targetDir/$folderName"
                    Thread {
                        val count = importEntryRecursive(srcRoot, containerUri, targetFatPath, volId)
                        runOnUiThread { res.success(count) }
                    }.start()
                } else res.success(0)
            } else res.success(0)
            pendingImportFolderVolId = null
            return
        }

        if (requestCode == EXPORT_FILE_REQUEST) {
            val res = pendingFlutterResult ?: return; pendingFlutterResult = null
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val destUri      = data.data!!
                val containerUri = pendingExportContainerUri
                val sourcePath   = pendingExportSourcePath
                val volId        = pendingExportVolId
                if (containerUri != null && sourcePath != null) {
                    Thread {
                        try {
                            val tempFile = File(cacheDir, "export_temp")
                            val success = synchronized(VeraCryptSession.locks[volId]) {
                                VeraCryptEngine.unlockAndExtractNative(
                                    -1, "", 0, sourcePath, tempFile.absolutePath, volId)
                            }
                            if (success && tempFile.exists()) {
                                contentResolver.openOutputStream(destUri)?.use { out ->
                                    tempFile.inputStream().use { it.copyTo(out) }
                                }
                                tempFile.delete()
                                runOnUiThread { res.success(true) }
                            } else {
                                tempFile.delete()
                                runOnUiThread { res.success(false) }
                            }
                        } catch (e: Exception) { runOnUiThread { res.error("EXPORT_ERROR", e.message, null) } }
                    }.start()
                } else res.success(false)
            } else res.success(false)
            return
        }
    }

    private fun exportEntryRecursive(
        destParent: DocumentFile, fatPath: String, isDir: Boolean,
        containerUri: String, volId: Int
    ): Int {
        val name = fatPath.substringAfterLast("/")
        if (!isDir) {
            return try {
                val tempFile = File(cacheDir, "export_${System.nanoTime()}")
                val ok  = synchronized(VeraCryptSession.locks[volId]) {
                    VeraCryptEngine.unlockAndExtractNative(-1, "", 0, fatPath, tempFile.absolutePath, volId)
                }
                var written = 0
                if (ok && tempFile.exists()) {
                    destParent.findFile(name)?.delete()
                    val outDoc = destParent.createFile(getMimeType(name), name)
                    if (outDoc != null) {
                        contentResolver.openOutputStream(outDoc.uri)?.use { out ->
                            tempFile.inputStream().use { it.copyTo(out) }
                        }
                        written = 1
                    }
                }
                tempFile.delete(); written
            } catch (_: Exception) { 0 }
        }
        val destDir = destParent.createDirectory(name) ?: return 0
        val children = synchronized(VeraCryptSession.locks[volId]) {
            VeraCryptEngine.listDirectoryNative(-1, "", 0, fatPath, volId)
        } ?: return 0
        var count = 0
        for (entry in children) {
            if (entry.startsWith("System:")) continue
            val childIsDir = entry.startsWith("[DIR] ")
            val childName = if (childIsDir) entry.substringAfter("[DIR] ").substringBefore("|") else entry.substringBefore("|")
            count += exportEntryRecursive(destDir, "$fatPath/$childName", childIsDir, containerUri, volId)
        }
        return count
    }

    private fun importEntryRecursive(
        srcDoc: DocumentFile, containerUri: String, targetFatPath: String, volId: Int
    ): Int {
        if (srcDoc.isDirectory) {
            synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.createDirectoryNative(-1, "", 0, targetFatPath, volId)
            }
            var count = 0
            for (child in srcDoc.listFiles()) {
                val childName = child.name ?: continue
                count += importEntryRecursive(child, containerUri, "$targetFatPath/$childName", volId)
            }
            return count
        }
        return try {
            val tempFile = File(cacheDir, "import_${System.nanoTime()}")
            contentResolver.openInputStream(srcDoc.uri)?.use { inp ->
                tempFile.outputStream().use { inp.copyTo(it) }
            }
            val ok = synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.writeBackFileNative(-1, "", 0, targetFatPath, tempFile.absolutePath, volId)
            }
            tempFile.delete()
            if (ok) 1 else 0
        } catch (_: Exception) { 0 }
    }

    private fun getMimeType(fileName: String): String = MimeTypeHelper.getMimeType(fileName)
}

// ── VeraCryptInputStream (Optimized Subsampled Native Image Stream) ─────────────

class VeraCryptInputStream(
    private val context: Context,
    private val uriString: String,
    private val fileName: String,
    private val volId: Int
) : java.io.InputStream() {

    private var position: Long = 0L
    private var fileSize: Long = -1L
    private var markedPosition: Long = 0L

    init {
        fileSize = synchronized(VeraCryptSession.locks[volId]) {
            VeraCryptEngine.getFileSizeNative(-1, "", 0, fileName, volId)
        }
    }

    override fun read(): Int {
        if (fileSize >= 0 && position >= fileSize) return -1
        val buf = ByteArray(1)
        val read = read(buf, 0, 1)
        return if (read > 0) buf[0].toInt() and 0xFF else -1
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (fileSize >= 0 && position >= fileSize) return -1
        val currentSize = fileSize
        val toRead = minOf(len.toLong(), currentSize - position).toInt()
        if (toRead <= 0) return -1

        val chunk = synchronized(VeraCryptSession.locks[volId]) {
            VeraCryptEngine.readFileChunkNative(-1, "", 0, fileName, position, toRead, volId)
        } ?: return -1

        if (chunk.isEmpty()) return -1
        val actual = minOf(chunk.size, toRead)
        System.arraycopy(chunk, 0, b, off, actual)
        position += actual
        return actual
    }

    override fun skip(n: Long): Long {
        if (n <= 0) return 0
        val currentSize = fileSize
        val actualSkip = minOf(n, currentSize - position)
        position += actualSkip
        return actualSkip
    }

    override fun available(): Int {
        val currentSize = fileSize
        return if (currentSize >= 0) {
            val avail = currentSize - position
            if (avail > Int.MAX_VALUE) Int.MAX_VALUE else avail.toInt()
        } else 0
    }

    override fun markSupported(): Boolean = true

    override fun mark(readlimit: Int) {
        synchronized(this) {
            markedPosition = position
        }
    }

    override fun reset() {
        synchronized(this) {
            position = markedPosition
        }
    }
}

// ── VeraCryptMediaDataSource (Optimized Native Video Stream) ─────────────────────

@TargetApi(Build.VERSION_CODES.M)
class VeraCryptMediaDataSource(
    private val context: Context,
    private val uriString: String,
    private val fileName: String,
    private val volId: Int
) : MediaDataSource() {

    private var cachedSize: Long = -1L

    override fun getSize(): Long {
        if (cachedSize >= 0) return cachedSize
        try {
            cachedSize = synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.getFileSizeNative(-1, "", 0, fileName, volId)
            }
        } catch (_: Exception) { cachedSize = 0L }
        return cachedSize
    }

    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        val fileLength = getSize()
        if (position >= fileLength) return -1
        val readSize = minOf(size.toLong(), fileLength - position).toInt()
        if (readSize <= 0) return -1
        try {
            val chunk = synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.readFileChunkNative(
                    -1, "", 0, fileName, position, readSize, volId)
            } ?: return -1
            if (chunk.isEmpty()) return -1
            val actualRead = minOf(chunk.size, readSize)
            System.arraycopy(chunk, 0, buffer, offset, actualRead)
            return actualRead
        } catch (_: Exception) { return -1 }
    }

    override fun close() {}
}