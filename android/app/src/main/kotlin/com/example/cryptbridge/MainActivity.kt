package com.example.cryptbridge

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.cryptbridge/engine"
    private val PICK_CONTAINER_REQUEST = 1001
    private val IMPORT_FILE_REQUEST = 1002
    private val EXPORT_FILE_REQUEST = 1003
    private var pendingFlutterResult: MethodChannel.Result? = null

    private var pendingImportContainerUri: String? = null
    private var pendingImportTargetName: String? = null
    private var pendingImportPassword: String? = null
    private var pendingImportPim: Int = 0
    private var pendingImportVolId: Int = 0

    private var pendingExportContainerUri: String? = null
    private var pendingExportSourcePath: String? = null
    private var pendingExportPassword: String? = null
    private var pendingExportPim: Int = 0
    private var pendingExportVolId: Int = 0

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

                    "unlockContainer" -> {
                        val uriString   = call.argument<String>("filePath")
                        val password    = call.argument<String>("password")
                        val pim         = call.argument<Number>("pim")?.toInt() ?: 0
                        val displayName = call.argument<String>("displayName")

                        if (uriString == null || password == null) {
                            result.error("INVALID_ARGS", "filePath and password are required", null)
                            return@setMethodCallHandler
                        }

                        // [FIX 1+2] Resolve the target slot before spawning the worker thread.
                        val targetVolId = VeraCryptSession.getVolumeIdByUri(uriString)
                            ?: VeraCryptSession.getFreeVolumeId()
                        if (targetVolId == null) {
                            result.error("MAX_CONTAINERS",
                                "Maximum 4 containers already mounted", null)
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
                                            uri             = uriString,
                                            password        = password,
                                            pim             = pim,
                                            volId           = targetVolId,
                                            cachedFilesList = files.toList(),
                                            displayName     = displayName
                                        )
                                        val rootsUri = DocumentsContract.buildRootsUri(
                                            "com.example.cryptbridge.documents")
                                        contentResolver.notifyChange(rootsUri, null)
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

                    "lockContainer" -> {
                        val uriString = call.argument<String>("filePath")
                        if (uriString == null) {
                            result.error("INVALID_ARGS", "filePath is required", null)
                            return@setMethodCallHandler
                        }
                        val volId = VeraCryptSession.getVolumeIdByUri(uriString)
                        if (volId != null) {
                            synchronized(VeraCryptSession.locks[volId]) {
                                VeraCryptEngine.lockNative(volId)
                            }
                            VeraCryptSession.removeSession(volId)
                            val rootsUri = DocumentsContract.buildRootsUri(
                                "com.example.cryptbridge.documents")
                            contentResolver.notifyChange(rootsUri, null)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }

                    "decryptFile" -> {
                        val uriString = call.argument<String>("filePath")
                        val password  = call.argument<String>("password")
                        val pim       = call.argument<Number>("pim")?.toInt() ?: 0
                        val fileName  = call.argument<String>("fileName")
                        val destPath  = call.argument<String>("destPath")
                        if (uriString == null || password == null || fileName == null || destPath == null) {
                            result.error("INVALID_ARGS", "All arguments are required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "r")
                                    ?: throw Exception("Could not open fd")
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.unlockAndExtractNative(
                                        pfd.detachFd(), password, pim, fileName, destPath, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_CRASH", e.message, null) }
                            }
                        }.start()
                    }

                    "getFileSize" -> {
                        val uriString = call.argument<String>("filePath")
                        val password  = call.argument<String>("password")
                        val pim       = call.argument<Number>("pim")?.toInt() ?: 0
                        val fileName  = call.argument<String>("fileName")
                        if (uriString == null || password == null || fileName == null) {
                            result.error("INVALID_ARGS", "filePath, password, and fileName required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "r")
                                    ?: throw Exception("Could not open fd")
                                val size = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.getFileSizeNative(
                                        pfd.detachFd(), password, pim, fileName, volId)
                                }
                                runOnUiThread { result.success(size) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_CRASH", e.message, null) }
                            }
                        }.start()
                    }

                    "readFileChunk" -> {
                        val uriString = call.argument<String>("filePath")
                        val password  = call.argument<String>("password")
                        val pim       = call.argument<Number>("pim")?.toInt() ?: 0
                        val fileName  = call.argument<String>("fileName")
                        val offset    = call.argument<Number>("offset")?.toLong() ?: 0L
                        val length    = call.argument<Number>("length")?.toInt() ?: 0
                        if (uriString == null || password == null || fileName == null) {
                            result.error("INVALID_ARGS", "filePath, password, and fileName required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "r")
                                    ?: throw Exception("Could not open fd")
                                val bytes = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.readFileChunkNative(
                                        pfd.detachFd(), password, pim, fileName, offset, length, volId)
                                }
                                runOnUiThread { result.success(bytes) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_CRASH", e.message, null) }
                            }
                        }.start()
                    }

                    "listDirectory" -> {
                        val uriString = call.argument<String>("filePath")
                        val password  = call.argument<String>("password")
                        val pim       = call.argument<Number>("pim")?.toInt() ?: 0
                        val dirPath   = call.argument<String>("dirPath") ?: ""
                        if (uriString == null || password == null) {
                            result.error("INVALID_ARGS", "filePath and password required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "r")
                                    ?: throw Exception("Could not open fd")
                                val files = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.listDirectoryNative(
                                        pfd.detachFd(), password, pim, dirPath, volId)
                                }
                                runOnUiThread { result.success(files?.toList()) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_ERROR", e.message, null) }
                            }
                        }.start()
                    }

                    "createDirectory" -> {
                        val uriString = call.argument<String>("filePath")
                        val password  = call.argument<String>("password")
                        val pim       = call.argument<Number>("pim")?.toInt() ?: 0
                        val dirPath   = call.argument<String>("dirPath")
                        if (uriString == null || password == null || dirPath == null) {
                            result.error("INVALID_ARGS", "All arguments are required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "rw")
                                    ?: throw Exception("Could not open fd")
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.createDirectoryNative(
                                        pfd.detachFd(), password, pim, dirPath, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_ERROR", e.message, null) }
                            }
                        }.start()
                    }

                    "renameFile" -> {
                        val uriString = call.argument<String>("filePath")
                        val password  = call.argument<String>("password")
                        val pim       = call.argument<Number>("pim")?.toInt() ?: 0
                        val oldPath   = call.argument<String>("oldPath")
                        val newPath   = call.argument<String>("newPath")
                        if (uriString == null || password == null || oldPath == null || newPath == null) {
                            result.error("INVALID_ARGS", "All arguments are required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "rw")
                                    ?: throw Exception("Could not open fd")
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.renameFileNative(
                                        pfd.detachFd(), password, pim, oldPath, newPath, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_ERROR", e.message, null) }
                            }
                        }.start()
                    }

                    "writeBackFile" -> {
                        val uriString  = call.argument<String>("filePath")
                        val password   = call.argument<String>("password")
                        val pim        = call.argument<Number>("pim")?.toInt() ?: 0
                        val fileName   = call.argument<String>("fileName")
                        val sourcePath = call.argument<String>("sourcePath")
                        if (uriString == null || password == null || fileName == null || sourcePath == null) {
                            result.error("INVALID_ARGS", "All arguments are required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "rw")
                                    ?: throw Exception("Could not open fd")
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.writeBackFileNative(
                                        pfd.detachFd(), password, pim, fileName, sourcePath, volId)
                                }
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_ERROR", e.message, null) }
                            }
                        }.start()
                    }

                    "getSpaceInfo" -> {
                        val uriString = call.argument<String>("filePath")
                        val password  = call.argument<String>("password")
                        val pim       = call.argument<Number>("pim")?.toInt() ?: 0
                        if (uriString == null || password == null) {
                            result.error("INVALID_ARGS", "filePath and password required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "r")
                                    ?: throw Exception("Could not open fd")
                                val space = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.getSpaceInfoNative(
                                        pfd.detachFd(), password, pim, volId)
                                }
                                runOnUiThread { result.success(space?.toList()) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("C++_CRASH", e.message, null) }
                            }
                        }.start()
                    }

                    "deleteFile" -> {
                        val uriString = call.argument<String>("filePath")
                        val password  = call.argument<String>("password")
                        val pim       = call.argument<Number>("pim")?.toInt() ?: 0
                        val fileName  = call.argument<String>("fileName")
                        if (uriString == null || password == null || fileName == null) {
                            result.error("INVALID_ARGS", "All arguments are required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val volId = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                                val pfd = contentResolver.openFileDescriptor(Uri.parse(uriString), "rw")
                                    ?: throw Exception("Could not open fd")
                                val success = synchronized(VeraCryptSession.locks[volId]) {
                                    VeraCryptEngine.deleteFileNative(
                                        pfd.detachFd(), password, pim, fileName, volId)
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
                            val volId     = VeraCryptSession.getVolumeIdByUri(uriString) ?: 0
                            val docUri    = DocumentsContract.buildDocumentUri(
                                "com.example.cryptbridge.documents", "$volId:file:$fileName")
                            val intent    = Intent(Intent.ACTION_VIEW).apply {
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
                        pendingImportPassword     = call.argument<String>("password")
                        pendingImportPim          = call.argument<Number>("pim")?.toInt() ?: 0
                        pendingImportVolId        =
                            VeraCryptSession.getVolumeIdByUri(pendingImportContainerUri!!) ?: 0
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE); type = "*/*"
                        }, IMPORT_FILE_REQUEST)
                    }

                    "exportFileToStorage" -> {
                        pendingResultCheck(result)
                        pendingExportContainerUri = call.argument<String>("filePath")
                        pendingExportSourcePath   = call.argument<String>("sourcePath")
                        pendingExportPassword     = call.argument<String>("password")
                        pendingExportPim          = call.argument<Number>("pim")?.toInt() ?: 0
                        pendingExportVolId        =
                            VeraCryptSession.getVolumeIdByUri(pendingExportContainerUri!!) ?: 0
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

    // [FIX 3] Resolve the real filename via OpenableColumns.DISPLAY_NAME and
    // return both uri + displayName so Flutter never has to parse the URI itself.
    private fun resolveDisplayName(uri: Uri): String {
        return try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx != -1) cursor.getString(idx) else null
                } else null
            } ?: uri.lastPathSegment ?: "Container"
        } catch (e: Exception) {
            uri.lastPathSegment ?: "Container"
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == PICK_CONTAINER_REQUEST) {
            val res = pendingFlutterResult ?: return; pendingFlutterResult = null
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri = data.data!!
                contentResolver.takePersistableUriPermission(uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                val displayName = resolveDisplayName(uri)
                res.success(mapOf(
                    "uri"         to uri.toString(),
                    "displayName" to displayName,
                ))
            } else {
                res.success(null)
            }
            return
        }

        if (requestCode == IMPORT_FILE_REQUEST) {
            val res = pendingFlutterResult ?: return; pendingFlutterResult = null
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val pickedUri    = data.data!!
                val containerUri = pendingImportContainerUri
                val targetDir    = pendingImportTargetName ?: ""
                val password     = pendingImportPassword
                val pim          = pendingImportPim
                val volId        = pendingImportVolId
                if (containerUri != null && password != null) {
                    Thread {
                        try {
                            var displayName = "imported_file"
                            contentResolver.query(pickedUri,
                                arrayOf(OpenableColumns.DISPLAY_NAME),
                                null, null, null)?.use { c ->
                                if (c.moveToFirst()) {
                                    val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                                    if (i != -1) displayName = c.getString(i)
                                }
                            }
                            val targetName = if (targetDir.isEmpty()) displayName
                                             else "$targetDir/$displayName"
                            val tempFile = File(cacheDir, "import_temp")
                            contentResolver.openInputStream(pickedUri)?.use { inp ->
                                tempFile.outputStream().use { inp.copyTo(it) }
                            }
                            val pfd = contentResolver.openFileDescriptor(
                                Uri.parse(containerUri), "rw")
                                ?: throw Exception("Could not open fd")
                            val success = synchronized(VeraCryptSession.locks[volId]) {
                                VeraCryptEngine.writeBackFileNative(
                                    pfd.detachFd(), password, pim,
                                    targetName, tempFile.absolutePath, volId)
                            }
                            tempFile.delete()
                            runOnUiThread { res.success(success) }
                        } catch (e: Exception) {
                            runOnUiThread { res.error("IMPORT_ERROR", e.message, null) }
                        }
                    }.start()
                } else res.success(false)
            } else res.success(false)
            return
        }

        if (requestCode == EXPORT_FILE_REQUEST) {
            val res = pendingFlutterResult ?: return; pendingFlutterResult = null
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val destUri      = data.data!!
                val containerUri = pendingExportContainerUri
                val sourcePath   = pendingExportSourcePath
                val password     = pendingExportPassword
                val pim          = pendingExportPim
                val volId        = pendingExportVolId
                if (containerUri != null && sourcePath != null && password != null) {
                    Thread {
                        try {
                            val tempFile = File(cacheDir, "export_temp")
                            val pfd = contentResolver.openFileDescriptor(
                                Uri.parse(containerUri), "r")
                                ?: throw Exception("Could not open fd")
                            val success = synchronized(VeraCryptSession.locks[volId]) {
                                VeraCryptEngine.unlockAndExtractNative(
                                    pfd.detachFd(), password, pim,
                                    sourcePath, tempFile.absolutePath, volId)
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

    private fun getMimeType(fileName: String): String = when {
        fileName.endsWith(".png",  true)                                      -> "image/png"
        fileName.endsWith(".jpg",  true)||fileName.endsWith(".jpeg", true)    -> "image/jpeg"
        fileName.endsWith(".webp", true)                                      -> "image/webp"
        fileName.endsWith(".gif",  true)                                      -> "image/gif"
        fileName.endsWith(".mp4",  true)||fileName.endsWith(".m4v",  true)    -> "video/mp4"
        fileName.endsWith(".webm", true)                                      -> "video/webm"
        fileName.endsWith(".mkv",  true)                                      -> "video/x-matroska"
        fileName.endsWith(".txt",  true)                                      -> "text/plain"
        fileName.endsWith(".pdf",  true)                                      -> "application/pdf"
        else                                                                  -> "application/octet-stream"
    }
}