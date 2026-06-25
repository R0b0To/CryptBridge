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
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import java.io.RandomAccessFile
import java.nio.channels.FileChannel
import android.annotation.TargetApi
import android.graphics.Bitmap
import android.media.MediaDataSource
import android.media.MediaMetadataRetriever
import java.io.ByteArrayOutputStream

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.aeidolon.vaultexplorer/engine"
    private val PICK_CONTAINER_REQUEST   = 1001
    private val IMPORT_FILE_REQUEST      = 1002
    private val EXPORT_FILE_REQUEST      = 1003
    private val CREATE_CONTAINER_REQUEST = 1004
    private val EXPORT_FILES_TREE_REQUEST  = 1006
    private val IMPORT_FOLDER_TREE_REQUEST = 1007

    private var pendingFlutterResult: MethodChannel.Result? = null

    private var pendingImportContainerUri: String? = null
    private var pendingImportTargetName: String? = null
    private var pendingImportVolId: Int = 0

    private var pendingExportContainerUri: String? = null
    private var pendingExportSourcePath: String? = null
    private var pendingExportVolId: Int = 0

    private var pendingCreateName: String? = null
    private var pendingCreateSize: Long = 0L
    private var pendingCreatePassword: String? = null
    private var pendingCreatePim: Int = 0
    private var pendingCreateFileSystem: String? = null

    private var pendingImportFolderContainerUri: String? = null
    private var pendingImportFolderTargetDir: String? = null
    private var pendingImportFolderVolId: Int = 0

    private var pendingExportMultiContainerUri: String? = null
    private var pendingExportMultiItems: List<Map<String, Any?>>? = null
    private var pendingExportMultiVolId: Int = 0

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

    // ── Document-provider notification helper ─────────────────────────────────

    private fun notifyRootsIfEnabled(uriString: String) {
        val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: return
        val session = VeraCryptSession.activeSessions[volId] ?: return
        if (session.documentProvider) {
            contentResolver.notifyChange(
                DocumentsContract.buildRootsUri("com.aeidolon.vaultexplorer.documents"), null
            )
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "pickContainer" -> {
                        pendingResultCheck(result)
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        startActivityForResult(intent, PICK_CONTAINER_REQUEST)
                    }

                    "createContainer" -> {
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

                    "unlockContainer" -> {
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
                            result.error("MAX_CONTAINERS", "Maximum 4 containers already mounted", null)
                            return@setMethodCallHandler
                        }

                        Thread {
                            try {
                                val uri = Uri.parse(uriString)
                                val pfd = contentResolver.openFileDescriptor(uri, "r")
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
                                                    "com.aeidolon.vaultexplorer.documents"), null
                                            )
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
                    
"getVideoThumbnail" -> {
                        val uriString = call.argument<String>("filePath")
                        val fileName  = call.argument<String>("fileName")

                        if (uriString == null || fileName == null) {
                            result.error("INVALID_ARGS", "filePath and fileName required", null)
                            return@setMethodCallHandler
                        }

                        Thread {
                            var retriever: MediaMetadataRetriever? = null
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                retriever = MediaMetadataRetriever()
                                
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                    val dataSource = VeraCryptMediaDataSource(this, uriString, fileName, volId)
                                    retriever.setDataSource(dataSource)

                                    val durationStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                                    val durationMs = durationStr?.toLongOrNull() ?: 10000L

                                    // Extract exactly one frame at 1s (or 25% of duration if the video is extremely short)
                                    val timeMs = minOf(1000L, durationMs / 4)
                                    
                                    // Hardware/software decoder downscaling optimization (Requires Android 8.1+)
                                    val frame = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                                        try {
                                            retriever.getScaledFrameAtTime(
                                                timeMs * 1000L,
                                                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                                                180,
                                                180
                                            )
                                        } catch (e: Exception) {
                                            retriever.getFrameAtTime(timeMs * 1000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                                        }
                                    } else {
                                        retriever.getFrameAtTime(timeMs * 1000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                                    }
                                    
                                    if (frame != null) {
                                        val stream = ByteArrayOutputStream()
                                        // Compress to JPEG 60% for a highly optimized thumbnail payload
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
                                try {
                                    retriever?.release()
                                } catch (_: Exception) {}
                            }
                        }.start()
                    }

                    "lockContainer" -> {
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

                    "decryptFile" -> {
                        val uriString = call.argument<String>("filePath")
                        val fileName  = call.argument<String>("fileName")
                        val destPath  = call.argument<String>("destPath")
                        if (uriString == null || fileName == null || destPath == null) {
                            result.error("INVALID_ARGS", "All arguments required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "r")
                                    ?: throw Exception("Could not open fd")
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.unlockAndExtractNative(
                                        pfd.detachFd(), "", 0, fileName, destPath, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_CRASH", e.message, null) }
                            }
                        }.start()
                    }

                    "getFileSize" -> {
                        val uriString = call.argument<String>("filePath")
                        val fileName  = call.argument<String>("fileName")
                        if (uriString == null || fileName == null) {
                            result.error("INVALID_ARGS", "filePath and fileName required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "r")
                                    ?: throw Exception("Could not open fd")
                                val size = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.getFileSizeNative(pfd.detachFd(), "", 0, fileName, volId)
                                }
                                runOnUiThread { result.success(size) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_CRASH", e.message, null) }
                            }
                        }.start()
                    }

                    "readFileChunk" -> {
                        val uriString = call.argument<String>("filePath")
                        val fileName  = call.argument<String>("fileName")
                        val offset    = call.argument<Number>("offset")?.toLong() ?: 0L
                        val length    = call.argument<Number>("length")?.toInt() ?: 0
                        if (uriString == null || fileName == null) {
                            result.error("INVALID_ARGS", "filePath and fileName required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "r")
                                    ?: throw Exception("Could not open fd")
                                val bytes = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.readFileChunkNative(
                                        pfd.detachFd(), "", 0, fileName, offset, length, volId)
                                }
                                runOnUiThread { result.success(bytes) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_CRASH", e.message, null) }
                            }
                        }.start()
                    }

                    "listDirectory" -> {
                        val uriString = call.argument<String>("filePath")
                        val dirPath   = call.argument<String>("dirPath") ?: ""
                        if (uriString == null) {
                            result.error("INVALID_ARGS", "filePath is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "r")
                                    ?: throw Exception("Could not open fd")
                                val files = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.listDirectoryNative(
                                        pfd.detachFd(), "", 0, dirPath, volId)
                                }
                                runOnUiThread { result.success(files?.toList()) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_ERROR", e.message, null) }
                            }
                        }.start()
                    }

                    "createDirectory" -> {
                        val uriString = call.argument<String>("filePath")
                        val dirPath   = call.argument<String>("dirPath")
                        if (uriString == null || dirPath == null) {
                            result.error("INVALID_ARGS", "All arguments required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "rw")
                                    ?: throw Exception("Could not open fd")
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.createDirectoryNative(
                                        pfd.detachFd(), "", 0, dirPath, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_ERROR", e.message, null) }
                            }
                        }.start()
                    }

                    "renameFile" -> {
                        val uriString = call.argument<String>("filePath")
                        val oldPath   = call.argument<String>("oldPath")
                        val newPath   = call.argument<String>("newPath")
                        if (uriString == null || oldPath == null || newPath == null) {
                            result.error("INVALID_ARGS", "All arguments required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "rw")
                                    ?: throw Exception("Could not open fd")
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.renameFileNative(
                                        pfd.detachFd(), "", 0, oldPath, newPath, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_ERROR", e.message, null) }
                            }
                        }.start()
                    }

                    "writeBackFile" -> {
                        val uriString  = call.argument<String>("filePath")
                        val fileName   = call.argument<String>("fileName")
                        val sourcePath = call.argument<String>("sourcePath")
                        if (uriString == null || fileName == null || sourcePath == null) {
                            result.error("INVALID_ARGS", "All arguments required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "rw")
                                    ?: throw Exception("Could not open fd")
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.writeBackFileNative(
                                        pfd.detachFd(), "", 0, fileName, sourcePath, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_ERROR", e.message, null) }
                            }
                        }.start()
                    }

                    "getSpaceInfo" -> {
                        val uriString = call.argument<String>("filePath")
                        if (uriString == null) {
                            result.error("INVALID_ARGS", "filePath is required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "r")
                                    ?: throw Exception("Could not open fd")
                                val space = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.getSpaceInfoNative(pfd.detachFd(), "", 0, volId)
                                }
                                runOnUiThread { result.success(space?.toList()) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_CRASH", e.message, null) }
                            }
                        }.start()
                    }

                    "deleteFile" -> {
                        val uriString = call.argument<String>("filePath")
                        val fileName  = call.argument<String>("fileName")
                        if (uriString == null || fileName == null) {
                            result.error("INVALID_ARGS", "All arguments required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "rw")
                                    ?: throw Exception("Could not open fd")
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.deleteFileNative(
                                        pfd.detachFd(), "", 0, fileName, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_ERROR", e.message, null) }
                            }
                        }.start()
                    }

                    "openWithApp" -> {
                        val uriString = call.argument<String>("filePath")
                        val fileName  = call.argument<String>("fileName")
                        if (uriString == null || fileName == null) {
                            result.error("INVALID_ARGS", "filePath and fileName required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                            val docUri = DocumentsContract.buildDocumentUri(
                                "com.aeidolon.vaultexplorer.documents", "$volId:file:$fileName")
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(docUri, getMimeType(fileName))
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                         Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                            }
                            startActivity(Intent.createChooser(intent, "Open file with…"))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_WITH_ERROR", e.message, null)
                        }
                    }

                    "importFile" -> {
                        pendingResultCheck(result)
                        pendingImportContainerUri = call.argument<String>("filePath")
                        pendingImportTargetName   = call.argument<String>("targetPath")
                        pendingImportVolId = VeraCryptSession.getVolumeIdByUri(pendingImportContainerUri!!) ?: 0
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        }, IMPORT_FILE_REQUEST)
                    }

                    "exportFilesToFolder" -> {
                        pendingResultCheck(result)
                        pendingExportMultiContainerUri = call.argument<String>("filePath")
                        @Suppress("UNCHECKED_CAST")
                        pendingExportMultiItems = (call.argument<List<*>>("items"))
                            ?.map { it as Map<String, Any?> } ?: emptyList()
                        pendingExportMultiVolId = VeraCryptSession.getVolumeIdByUri(pendingExportMultiContainerUri!!) ?: 0
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), EXPORT_FILES_TREE_REQUEST)
                    }

                    "importFolder" -> {
                        pendingResultCheck(result)
                        pendingImportFolderContainerUri = call.argument<String>("filePath")
                        pendingImportFolderTargetDir    = call.argument<String>("targetPath") ?: ""
                        pendingImportFolderVolId = VeraCryptSession.getVolumeIdByUri(pendingImportFolderContainerUri!!) ?: 0
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), IMPORT_FOLDER_TREE_REQUEST)
                    }

                    "exportFileToStorage" -> {
                        pendingResultCheck(result)
                        pendingExportContainerUri = call.argument<String>("filePath")
                        pendingExportSourcePath   = call.argument<String>("sourcePath")
                        pendingExportVolId = VeraCryptSession.getVolumeIdByUri(pendingExportContainerUri!!) ?: 0
                        val fileName = pendingExportSourcePath!!.split("/").last()
                        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = getMimeType(fileName)
                            putExtra(Intent.EXTRA_TITLE, fileName)
                        }, EXPORT_FILE_REQUEST)
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
                            val success = VeraCryptEngine.createContainerNative(pfd.detachFd(), pass, pim, size, fs)
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
                if (containerUri != null && uris.isNotEmpty()) {
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
                if (containerUri != null && srcRoot != null) {
                    val folderName = srcRoot.name ?: "imported_folder"
                    val targetFatPath = if (targetDir.isEmpty()) folderName else "$targetDir/$folderName"
                    Thread {
                        val count = importEntryRecursive(srcRoot, containerUri, targetFatPath, volId)
                        runOnUiThread { res.success(count) }
                    }.start()
                } else res.success(0)
            } else res.success(0)
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
                            val pfd = contentResolver.openFileDescriptor(Uri.parse(containerUri), "r")
                                ?: throw Exception("Could not open fd")
                            val success = synchronized(VeraCryptSession.locks[volId]) {
                                VeraCryptEngine.unlockAndExtractNative(
                                    pfd.detachFd(), "", 0, sourcePath, tempFile.absolutePath, volId)
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
                        } catch (e: Exception) {
                            runOnUiThread { res.error("EXPORT_ERROR", e.message, null) }
                        }
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
                val pfd = contentResolver.openFileDescriptor(Uri.parse(containerUri), "r") ?: return 0
                val ok = synchronized(VeraCryptSession.locks[volId]) {
                    VeraCryptEngine.unlockAndExtractNative(pfd.detachFd(), "", 0, fatPath, tempFile.absolutePath, volId)
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
        val listPfd = contentResolver.openFileDescriptor(Uri.parse(containerUri), "r") ?: return 0
        val children = synchronized(VeraCryptSession.locks[volId]) {
            VeraCryptEngine.listDirectoryNative(listPfd.detachFd(), "", 0, fatPath, volId)
        } ?: return 0
        var count = 0
        for (entry in children) {
            if (entry.startsWith("System:")) continue
            val childIsDir = entry.startsWith("[DIR] ")
            val childName  = if (childIsDir) entry.substringAfter("[DIR] ") else entry.substringBefore("|")
            count += exportEntryRecursive(destDir, "$fatPath/$childName", childIsDir, containerUri, volId)
        }
        return count
    }

    private fun importEntryRecursive(
        srcDoc: DocumentFile, containerUri: String, targetFatPath: String, volId: Int
    ): Int {
        if (srcDoc.isDirectory) {
            val mkPfd = contentResolver.openFileDescriptor(Uri.parse(containerUri), "rw") ?: return 0
            synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.createDirectoryNative(mkPfd.detachFd(), "", 0, targetFatPath, volId)
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
            val writePfd = contentResolver.openFileDescriptor(Uri.parse(containerUri), "rw") ?: return 0
            val ok = synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.writeBackFileNative(
                    writePfd.detachFd(), "", 0, targetFatPath, tempFile.absolutePath, volId)
            }
            tempFile.delete()
            if (ok) 1 else 0
        } catch (_: Exception) { 0 }
    }

    private fun getMimeType(fileName: String): String = when {
        fileName.endsWith(".png",  true)                                   -> "image/png"
        fileName.endsWith(".jpg",  true)||fileName.endsWith(".jpeg", true) -> "image/jpeg"
        fileName.endsWith(".webp", true)                                   -> "image/webp"
        fileName.endsWith(".gif",  true)                                   -> "image/gif"
        fileName.endsWith(".mp4",  true)||fileName.endsWith(".m4v",  true) -> "video/mp4"
        fileName.endsWith(".webm", true)                                   -> "video/webm"
        fileName.endsWith(".mkv",  true)                                   -> "video/x-matroska"
        fileName.endsWith(".txt",  true)                                   -> "text/plain"
        fileName.endsWith(".pdf",  true)                                   -> "application/pdf"
        else                                                               -> "application/octet-stream"
    }
}

@TargetApi(Build.VERSION_CODES.M)
class VeraCryptMediaDataSource(
    private val context: Context,
    private val uriString: String,
    private val fileName: String,
    private val volId: Int
) : MediaDataSource() {

    private var cachedSize: Long = -1L
    private var pfd: ParcelFileDescriptor? = null

    init {
        try {
            pfd = context.contentResolver.openFileDescriptor(Uri.parse(uriString), "r")
        } catch (_: Exception) {}
    }

    override fun getSize(): Long {
        if (cachedSize >= 0) return cachedSize
        val currentPfd = pfd ?: return 0L
        try {
            val dupPfd = currentPfd.dup()
            cachedSize = synchronized(VeraCryptSession.locks[volId]) {
                // Corrected: Queries the target file size instead of disk space info
                VeraCryptEngine.getFileSizeNative(dupPfd.detachFd(), "", 0, fileName, volId)
            }
        } catch (e: Exception) {
            cachedSize = 0L
        }
        return cachedSize
    }

    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        val currentPfd = pfd ?: return -1
        val fileLength = getSize()
        if (position >= fileLength) return -1 // EOF
        
        val readSize = minOf(size.toLong(), fileLength - position).toInt()
        if (readSize <= 0) return -1
        
        try {
            val dupPfd = currentPfd.dup()
            val chunk = synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.readFileChunkNative(
                    dupPfd.detachFd(), "", 0, fileName, position, readSize, volId
                )
            } ?: return -1
            
            if (chunk.isEmpty()) return -1
            val actualRead = minOf(chunk.size, readSize)
            System.arraycopy(chunk, 0, buffer, offset, actualRead)
            return actualRead
        } catch (e: Exception) {
            return -1
        }
    }

    override fun close() {
        try {
            pfd?.close()
        } catch (_: Exception) {}
    }
}