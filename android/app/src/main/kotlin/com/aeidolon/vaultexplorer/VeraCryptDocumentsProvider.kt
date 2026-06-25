package com.aeidolon.vaultexplorer

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Point
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.ProxyFileDescriptorCallback
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import android.system.ErrnoException
import android.system.OsConstants
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.RandomAccessFile

class VeraCryptDocumentsProvider : DocumentsProvider() {

    private val defaultRootProjection = arrayOf(
        DocumentsContract.Root.COLUMN_ROOT_ID,
        DocumentsContract.Root.COLUMN_MIME_TYPES,
        DocumentsContract.Root.COLUMN_FLAGS,
        DocumentsContract.Root.COLUMN_ICON,
        DocumentsContract.Root.COLUMN_TITLE,
        DocumentsContract.Root.COLUMN_SUMMARY,
        DocumentsContract.Root.COLUMN_DOCUMENT_ID,
        DocumentsContract.Root.COLUMN_AVAILABLE_BYTES,
        DocumentsContract.Root.COLUMN_CAPACITY_BYTES
    )

    private val defaultDocumentProjection = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        DocumentsContract.Document.COLUMN_FLAGS,
        DocumentsContract.Document.COLUMN_SIZE
    )

    override fun onCreate() = true

    private fun getFd(uriString: String, mode: String): Int {
        val uri = Uri.parse(uriString)
        val pfd = context?.contentResolver?.openFileDescriptor(uri, mode)
            ?: throw FileNotFoundException("Could not open PFD for $mode")
        return pfd.detachFd()
    }

    override fun queryRoots(projection: Array<out String>?): Cursor {
        var flags = DocumentsContract.Root.FLAG_SUPPORTS_CREATE or
                DocumentsContract.Root.FLAG_LOCAL_ONLY or
                DocumentsContract.Root.FLAG_SUPPORTS_EJECT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            flags = flags or DocumentsContract.Root.FLAG_SUPPORTS_IS_CHILD
        }

        val cursor = MatrixCursor(projection ?: defaultRootProjection)
        for ((volId, session) in VeraCryptSession.activeSessions.filter { it.value.documentProvider }) {
            val rootTitle = session.displayName ?: getFileNameFromUri(session.uri)
            val (totalBytes, freeBytes) = getRealSpace(session)
            val rootSummary = if (totalBytes > 0)
                "Volume — ${android.text.format.Formatter.formatFileSize(context, freeBytes)} free"
            else "Volume"

            cursor.newRow().apply {
                add(DocumentsContract.Root.COLUMN_ROOT_ID, volId.toString())
                add(DocumentsContract.Root.COLUMN_MIME_TYPES, "*/*")
                add(DocumentsContract.Root.COLUMN_DOCUMENT_ID, "$volId:dir:")
                add(DocumentsContract.Root.COLUMN_TITLE, rootTitle)
                add(DocumentsContract.Root.COLUMN_SUMMARY, rootSummary)
                add(DocumentsContract.Root.COLUMN_FLAGS, flags)
                add(DocumentsContract.Root.COLUMN_ICON, android.R.drawable.ic_lock_idle_charging)
                add(DocumentsContract.Root.COLUMN_AVAILABLE_BYTES, freeBytes)
                add(DocumentsContract.Root.COLUMN_CAPACITY_BYTES, totalBytes)
            }
        }
        return cursor
    }

    override fun isChildDocument(parentDocumentId: String?, documentId: String?): Boolean {
        if (parentDocumentId == null || documentId == null) return false
        val parentParts = parentDocumentId.split(":")
        val childParts = documentId.split(":")
        if (parentParts.size < 2 || childParts.size < 2) return false
        if (parentParts[0] != childParts[0]) return false
        val parentFatPath = parentParts.drop(2).joinToString(":")
        val childFatPath = childParts.drop(2).joinToString(":")
        return if (parentFatPath.isEmpty()) true
        else childFatPath.startsWith("$parentFatPath/")
    }

    override fun ejectRoot(rootId: String?) {
        val volId = rootId?.toIntOrNull() ?: return
        VeraCryptEngine.lockNative(volId)
        VeraCryptSession.removeSession(volId)
        context?.contentResolver?.notifyChange(
            DocumentsContract.buildRootsUri("com.aeidolon.vaultexplorer.documents"), null
        )
    }

    override fun queryDocument(documentId: String?, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: defaultDocumentProjection)
        val docId = documentId ?: throw FileNotFoundException("No document ID")
        val parts = docId.split(":")
        if (parts.size < 2) throw FileNotFoundException("Invalid document ID")
        val volId = parts[0].toIntOrNull() ?: throw FileNotFoundException("Invalid volume ID")
        val type = parts[1]
        val fatPath = parts.drop(2).joinToString(":")
        val isDir = type == "dir"
        val displayName = if (fatPath.isEmpty()) "Root $volId" else fatPath.substringAfterLast("/")
        val mimeType = if (isDir) DocumentsContract.Document.MIME_TYPE_DIR else getMimeType(displayName)

        val size: Long = if (isDir) 0L else {
            try {
                val session = VeraCryptSession.activeSessions[volId]
                if (session != null) {
                    synchronized(VeraCryptSession.locks[volId]) {
                        VeraCryptEngine.getFileSizeNative(getFd(session.uri, "r"), "", 0, fatPath, volId)
                    }
                } else 0L
            } catch (_: Exception) { 0L }
        }

        var flags = DocumentsContract.Document.FLAG_SUPPORTS_DELETE
        if (isDir) {
            flags = flags or DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
        } else {
            flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_WRITE
            if (mimeType.startsWith("image/")) flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_THUMBNAIL
        }

        cursor.newRow().apply {
            add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, docId)
            add(DocumentsContract.Document.COLUMN_MIME_TYPE, mimeType)
            add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, displayName)
            add(DocumentsContract.Document.COLUMN_FLAGS, flags)
            add(DocumentsContract.Document.COLUMN_SIZE, size)
        }
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String?,
        projection: Array<out String>?,
        sortOrder: String?
    ): Cursor {
        val cursor = MatrixCursor(projection ?: defaultDocumentProjection)
        val parentId = parentDocumentId ?: throw FileNotFoundException("No parent ID")
        val parts = parentId.split(":")
        if (parts.size < 2) throw FileNotFoundException("Invalid parent ID")
        val volId = parts[0].toIntOrNull() ?: throw FileNotFoundException("Invalid volume ID")
        val parentFatPath = parts.drop(2).joinToString(":")
        val session = VeraCryptSession.activeSessions[volId] ?: return cursor

        try {
            val files = synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.listDirectoryNative(getFd(session.uri, "r"), "", 0, parentFatPath, volId)
            }
            files?.forEach { file ->
                if (file.startsWith("System:")) return@forEach
                val isDir = file.startsWith("[DIR] ")
                val cleanName = if (isDir) file.substringAfter("[DIR] ") else file.substringBefore("|")
                val size = if (isDir) 0L else file.substringAfter("|", "0").toLongOrNull() ?: 0L
                val childFatPath = if (parentFatPath.isEmpty()) cleanName else "$parentFatPath/$cleanName"
                val childType = if (isDir) "dir" else "file"
                val childMime = if (isDir) DocumentsContract.Document.MIME_TYPE_DIR else getMimeType(cleanName)

                var flags = DocumentsContract.Document.FLAG_SUPPORTS_DELETE
                if (isDir) flags = flags or DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
                else {
                    flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_WRITE
                    if (childMime.startsWith("image/")) flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_THUMBNAIL
                }

                cursor.newRow().apply {
                    add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, "$volId:$childType:$childFatPath")
                    add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, cleanName)
                    add(DocumentsContract.Document.COLUMN_MIME_TYPE, childMime)
                    add(DocumentsContract.Document.COLUMN_FLAGS, flags)
                    add(DocumentsContract.Document.COLUMN_SIZE, size)
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("vaultexplorer_Provider", "queryChildDocuments failed for $parentId: ${e.javaClass.simpleName}")
        }
        return cursor
    }

    @Throws(FileNotFoundException::class)
    override fun createDocument(parentDocumentId: String?, mimeType: String?, displayName: String?): String {
        val parentId = parentDocumentId ?: throw FileNotFoundException("No parent ID")
        val parts = parentId.split(":")
        if (parts.size < 2) throw FileNotFoundException("Invalid parent ID")
        val volId = parts[0].toIntOrNull() ?: throw FileNotFoundException("Invalid volume ID")
        val parentFatPath = parts.drop(2).joinToString(":")
        val session = VeraCryptSession.activeSessions[volId] ?: throw FileNotFoundException("No active session")
        val fileName = displayName ?: throw FileNotFoundException("No file name")
        val cleanPath = if (parentFatPath.isEmpty()) fileName else "$parentFatPath/$fileName"
        val isDirectory = mimeType == DocumentsContract.Document.MIME_TYPE_DIR

        val success = if (isDirectory) {
            synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.createDirectoryNative(getFd(session.uri, "rw"), "", 0, cleanPath, volId)
            }
        } else {
            val tempFile = File(context?.cacheDir, "vc_new_${volId}_${cleanPath.hashCode()}_$fileName")
            try {
                tempFile.delete()
                tempFile.createNewFile()
                synchronized(VeraCryptSession.locks[volId]) {
                    VeraCryptEngine.writeBackFileNative(getFd(session.uri, "rw"), "", 0, cleanPath, tempFile.absolutePath, volId)
                }
            } finally {
                tempFile.delete()
            }
        }

        if (!success) throw FileNotFoundException("Creation failed for $cleanPath")

        val childType = if (isDirectory) "dir" else "file"
        context?.contentResolver?.notifyChange(
            DocumentsContract.buildChildDocumentsUri("com.aeidolon.vaultexplorer.documents", parentId), null
        )
        return "$volId:$childType:$cleanPath"
    }

    @Throws(FileNotFoundException::class)
    override fun deleteDocument(documentId: String?) {
        val docId = documentId ?: throw FileNotFoundException("No document ID")
        val parts = docId.split(":")
        if (parts.size < 2) throw FileNotFoundException("Invalid document ID")
        val volId = parts[0].toIntOrNull() ?: throw FileNotFoundException("Invalid volume")
        val session = VeraCryptSession.activeSessions[volId] ?: throw FileNotFoundException("No active session")
        val fatPath = parts.drop(2).joinToString(":")

        val success = synchronized(VeraCryptSession.locks[volId]) {
            VeraCryptEngine.deleteFileNative(getFd(session.uri, "rw"), "", 0, fatPath, volId)
        }
        if (!success) throw FileNotFoundException("Delete failed for $fatPath")

        val parentPath = if (fatPath.contains("/")) fatPath.substringBeforeLast("/") else ""
        context?.contentResolver?.notifyChange(
            DocumentsContract.buildChildDocumentsUri(
                "com.aeidolon.vaultexplorer.documents", "$volId:dir:$parentPath"
            ), null
        )
    }

 @Throws(FileNotFoundException::class)
    override fun openDocument(
        documentId: String?,
        mode: String?,
        signal: CancellationSignal?
    ): ParcelFileDescriptor {
        val docId = documentId ?: throw FileNotFoundException("No document ID")
        val parts = docId.split(":")
        if (parts.size < 2) throw FileNotFoundException("Invalid document ID")
        val volId = parts[0].toIntOrNull() ?: throw FileNotFoundException("Invalid volume")
        val session = VeraCryptSession.activeSessions[volId] ?: throw FileNotFoundException("No active session")
        val fatPath = parts.drop(2).joinToString(":")
        val isWrite = mode?.contains("w") == true || mode?.contains("r+") == true

        val storageManager = context?.getSystemService(Context.STORAGE_SERVICE) as? StorageManager
            ?: throw FileNotFoundException("Could not obtain StorageManager")

        // Dedicated background thread for handling incoming sequential read/write block calls
        val handlerThread = HandlerThread("vc_proxy_${volId}_${System.nanoTime()}").apply { start() }
        val handler = Handler(handlerThread.looper)

        val callback = VeraCryptProxyCallback(volId, session, fatPath, isWrite, handlerThread)

        try {
            val parcelMode = ParcelFileDescriptor.parseMode(mode ?: "r")
            return storageManager.openProxyFileDescriptor(parcelMode, callback, handler)
        } catch (e: Exception) {
            handlerThread.quitSafely()
            throw FileNotFoundException("Failed to open proxy file descriptor: ${e.message}")
        }
    }

    /**
     * Fully in-memory file bridge. Reads and writes chunks directly to JNI 
     * without temporary cache files on device storage.
     */
    inner class VeraCryptProxyCallback(
        private val volId: Int,
        private val session: ContainerSession,
        private val fatPath: String,
        private val isWrite: Boolean,
        private val handlerThread: HandlerThread
    ) : ProxyFileDescriptorCallback() {

        private var hasChanges = false
        private var fileSizeCached: Long = -1L

        init {
            try {
                // Pre-cache the current file size.
                synchronized(VeraCryptSession.locks[volId]) {
                    fileSizeCached = VeraCryptEngine.getFileSizeNative(
                        getFd(session.uri, "r"), "", 0, fatPath, volId
                    )
                }
                if (fileSizeCached < 0) {
                    fileSizeCached = 0L
                }
            } catch (e: Exception) {
                handlerThread.quitSafely()
                throw FileNotFoundException("VeraCrypt initialization failed: ${e.message}")
            }
        }

        override fun onGetSize(): Long {
            return fileSizeCached
        }

        override fun onRead(offset: Long, size: Int, data: ByteArray): Int {
            val fd = getFd(session.uri, "r")
            val chunk = synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.readFileChunkNative(
                    fd, "", 0, fatPath, offset, size, volId
                )
            } ?: throw ErrnoException("onRead", OsConstants.EIO)

            if (chunk.isEmpty()) return 0
            val readSize = minOf(chunk.size, size)
            System.arraycopy(chunk, 0, data, 0, readSize)
            return readSize
        }

        override fun onWrite(offset: Long, size: Int, data: ByteArray): Int {
            if (!isWrite) {
                throw ErrnoException("onWrite", OsConstants.EBADF)
            }

            // Extract exactly the slice of bytes the system requested to write
            val chunkData = if (data.size == size) data else data.copyOf(size)
            val fd = getFd(session.uri, "rw")

            val success = synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.writeFileChunkNative(
                    fd, "", 0, fatPath, offset, chunkData, volId
                )
            }
            if (!success) {
                throw ErrnoException("onWrite failed", OsConstants.EIO)
            }

            // Dynamically scale cached size if the write expands the file
            val endOffset = offset + size
            if (endOffset > fileSizeCached) {
                fileSizeCached = endOffset
            }
            hasChanges = true
            return size
        }

        override fun onFsync() {
            // Write operations commit to the virtual storage synchronously on each chunk,
            // but we keep this stub compliant with the standard interface.
        }

        override fun onRelease() {
            if (isWrite && hasChanges) {
                // Notify the system that the containing directory changed
                val parentPath = if (fatPath.contains("/")) fatPath.substringBeforeLast("/") else ""
                context?.contentResolver?.notifyChange(
                    DocumentsContract.buildChildDocumentsUri(
                        "com.aeidolon.vaultexplorer.documents", "$volId:dir:$parentPath"
                    ), null
                )
            }
            handlerThread.quitSafely()
        }
    }

    private fun calculateInSampleSize(options: BitmapFactory.Options, reqWidth: Int, reqHeight: Int): Int {
        val height = options.outHeight
        val width = options.outWidth
        var inSampleSize = 1
        if (height > reqHeight || width > reqWidth) {
            val halfHeight = height / 2
            val halfWidth = width / 2
            while (halfHeight / inSampleSize >= reqHeight && halfWidth / inSampleSize >= reqWidth) {
                inSampleSize *= 2
            }
        }
        return inSampleSize
    }

    private fun getRealSpace(session: ContainerSession): Pair<Long, Long> = try {
        val space = synchronized(VeraCryptSession.locks[session.volId]) {
            VeraCryptEngine.getSpaceInfoNative(getFd(session.uri, "r"), "", 0, session.volId)
        }
        if (space != null && space.size > 1) Pair(space[0], space[1]) else Pair(0L, 0L)
    } catch (_: Exception) { Pair(0L, 0L) }

    private fun getFileNameFromUri(uriString: String): String {
        val uri = Uri.parse(uriString)
        if (uri.scheme == "content") {
            try {
                context?.contentResolver?.query(
                    uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                        if (idx != -1) return cursor.getString(idx)
                    }
                }
            } catch (_: Exception) {}
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "Container"
    }

    private fun getMimeType(fileName: String): String = when {
        fileName.endsWith(".png", true) -> "image/png"
        fileName.endsWith(".jpg", true) || fileName.endsWith(".jpeg", true) -> "image/jpeg"
        fileName.endsWith(".webp", true) -> "image/webp"
        fileName.endsWith(".gif", true) -> "image/gif"
        fileName.endsWith(".mp4", true) || fileName.endsWith(".m4v", true) -> "video/mp4"
        fileName.endsWith(".webm", true) -> "video/webm"
        fileName.endsWith(".mkv", true) -> "video/x-matroska"
        fileName.endsWith(".txt", true) -> "text/plain"
        fileName.endsWith(".pdf", true) -> "application/pdf"
        else -> "application/octet-stream"
    }
}