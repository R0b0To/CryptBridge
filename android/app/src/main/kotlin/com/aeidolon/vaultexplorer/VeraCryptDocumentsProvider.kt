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

    private fun openPfd(uriString: String, mode: String): ParcelFileDescriptor {
        val uri = Uri.parse(uriString)
        return context?.contentResolver?.openFileDescriptor(uri, mode)
            ?: throw FileNotFoundException("Could not open PFD for $mode on $uriString")
    }

    private fun detachFd(uriString: String, mode: String): Int =
        openPfd(uriString, mode).detachFd()

    // FIX: Centralised, bounds-checked volId parser.
    //
    // Previously every override parsed `parts[0].toIntOrNull()` without
    // validating the range. A malicious document URI with volId=-1 or
    // volId=100 would cause ArrayIndexOutOfBoundsException on
    // VeraCryptSession.locks[volId]. Now all overrides call this helper.
    private fun parseVolId(raw: String?): Int {
        val id = raw?.toIntOrNull()
            ?: throw FileNotFoundException("Missing volume ID in document URI")
        if (id < 0 || id >= VeraCryptSession.MAX_VOLUMES) {
            throw FileNotFoundException("Volume ID $id is out of range [0, ${VeraCryptSession.MAX_VOLUMES})")
        }
        return id
    }

    // FIX: Centralised session lookup.
    //
    // Avoids duplicating the null check + error message across every override.
    // Also ensures we never operate on an inactive session (which would pass
    // an empty password to native, silently failing or worse).
    private fun requireSession(volId: Int): ContainerSession =
        VeraCryptSession.activeSessions[volId]
            ?: throw FileNotFoundException(
                "No active session for volume $volId. " +
                "Please unlock the container first."
            )

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
        val childParts  = documentId.split(":")
        if (parentParts.size < 2 || childParts.size < 2) return false
        if (parentParts[0] != childParts[0]) return false
        val parentFatPath = parentParts.drop(2).joinToString(":")
        val childFatPath  = childParts.drop(2).joinToString(":")
        return if (parentFatPath.isEmpty()) true
        else childFatPath.startsWith("$parentFatPath/")
    }

    override fun ejectRoot(rootId: String?) {
        // FIX: Use parseVolId for bounds checking
        val volId = rootId?.toIntOrNull()
            ?.takeIf { it in 0 until VeraCryptSession.MAX_VOLUMES }
            ?: return
        VeraCryptEngine.lockNative(volId)
        VeraCryptSession.removeSession(volId)
        context?.contentResolver?.notifyChange(
            DocumentsContract.buildRootsUri("com.aeidolon.vaultexplorer.documents"), null
        )
    }

    override fun queryDocument(documentId: String?, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: defaultDocumentProjection)
        val docId  = documentId ?: throw FileNotFoundException("No document ID")
        val parts  = docId.split(":")
        if (parts.size < 2) throw FileNotFoundException("Invalid document ID: $docId")

        // FIX: bounds-checked volId parse
        val volId   = parseVolId(parts[0])
        val type    = parts[1]
        val fatPath = parts.drop(2).joinToString(":")
        val isDir   = type == "dir"
        val displayName = if (fatPath.isEmpty()) "Root $volId" else fatPath.substringAfterLast("/")
        val mimeType    = if (isDir) DocumentsContract.Document.MIME_TYPE_DIR
                          else MimeTypeHelper.getMimeType(displayName)

        val size: Long = if (isDir) 0L else {
            try {
                // FIX: requireSession instead of nullable access
                val session = requireSession(volId)
                synchronized(VeraCryptSession.locks[volId]) {
                    VeraCryptEngine.getFileSizeNative(
                        detachFd(session.uri, "r"), "", 0, fatPath, volId)
                }
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
        val cursor   = MatrixCursor(projection ?: defaultDocumentProjection)
        val parentId = parentDocumentId ?: throw FileNotFoundException("No parent ID")
        val parts    = parentId.split(":")
        if (parts.size < 2) throw FileNotFoundException("Invalid parent ID: $parentId")

        // FIX: bounds-checked volId parse
        val volId         = parseVolId(parts[0])
        val parentFatPath = parts.drop(2).joinToString(":")

        // FIX: requireSession — fail fast with a clear error if session is gone
        val session = requireSession(volId)

        try {
            val files = synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.listDirectoryNative(
                    detachFd(session.uri, "r"), "", 0, parentFatPath, volId)
            }
            files?.forEach { file ->
                if (file.startsWith("System:")) return@forEach
                val isDir     = file.startsWith("[DIR] ")
                val cleanName = if (isDir) file.substringAfter("[DIR] ").substringBefore("|") else file.substringBefore("|")
                val size      = if (isDir) 0L else file.split("|").getOrNull(1)?.toLongOrNull() ?: 0L
                val childFatPath = if (parentFatPath.isEmpty()) cleanName else "$parentFatPath/$cleanName"
                val childType = if (isDir) "dir" else "file"
                val childMime = if (isDir) DocumentsContract.Document.MIME_TYPE_DIR
                                else MimeTypeHelper.getMimeType(cleanName)

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
        } catch (e: FileNotFoundException) {
            throw e // Re-throw session-not-found errors
        } catch (e: Exception) {
            android.util.Log.e("vaultexplorer_Provider",
                "queryChildDocuments failed for $parentId: ${e.javaClass.simpleName}")
        }
        return cursor
    }

    @Throws(FileNotFoundException::class)
    override fun createDocument(parentDocumentId: String?, mimeType: String?, displayName: String?): String {
        val parentId = parentDocumentId ?: throw FileNotFoundException("No parent ID")
        val parts    = parentId.split(":")
        if (parts.size < 2) throw FileNotFoundException("Invalid parent ID: $parentId")

        // FIX: bounds-checked volId parse + requireSession
        val volId         = parseVolId(parts[0])
        val parentFatPath = parts.drop(2).joinToString(":")
        val session       = requireSession(volId)
        val fileName      = displayName ?: throw FileNotFoundException("No file name")
        val cleanPath     = if (parentFatPath.isEmpty()) fileName else "$parentFatPath/$fileName"
        val isDirectory   = mimeType == DocumentsContract.Document.MIME_TYPE_DIR

        val success = if (isDirectory) {
            synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.createDirectoryNative(
                    detachFd(session.uri, "rw"), "", 0, cleanPath, volId)
            }
        } else {
            val tempFile = File(context?.cacheDir, "vc_new_${volId}_${cleanPath.hashCode()}_$fileName")
            try {
                tempFile.delete()
                tempFile.createNewFile()
                synchronized(VeraCryptSession.locks[volId]) {
                    VeraCryptEngine.writeBackFileNative(
                        detachFd(session.uri, "rw"), "", 0, cleanPath, tempFile.absolutePath, volId)
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
        val docId   = documentId ?: throw FileNotFoundException("No document ID")
        val parts   = docId.split(":")
        if (parts.size < 2) throw FileNotFoundException("Invalid document ID: $docId")

        // FIX: bounds-checked volId parse + requireSession
        val volId   = parseVolId(parts[0])
        val session = requireSession(volId)
        val fatPath = parts.drop(2).joinToString(":")

        val success = synchronized(VeraCryptSession.locks[volId]) {
            VeraCryptEngine.deleteFileNative(detachFd(session.uri, "rw"), "", 0, fatPath, volId)
        }
        if (!success) throw FileNotFoundException("Delete failed for $fatPath")

        val parentPath = if (fatPath.contains("/")) fatPath.substringBeforeLast("/") else ""
        context?.contentResolver?.notifyChange(
            DocumentsContract.buildChildDocumentsUri(
                "com.aeidolon.vaultexplorer.documents", "$volId:dir:$parentPath"), null
        )
    }

    @Throws(FileNotFoundException::class)
    override fun openDocument(
        documentId: String?,
        mode: String?,
        signal: CancellationSignal?
    ): ParcelFileDescriptor {
        val docId   = documentId ?: throw FileNotFoundException("No document ID")
        val parts   = docId.split(":")
        if (parts.size < 2) throw FileNotFoundException("Invalid document ID: $docId")

        // FIX: bounds-checked volId parse + requireSession
        val volId   = parseVolId(parts[0])
        val session = requireSession(volId)
        val fatPath = parts.drop(2).joinToString(":")
        val isWrite = mode?.contains("w") == true || mode?.contains("r+") == true

        val storageManager = context?.getSystemService(Context.STORAGE_SERVICE) as? StorageManager
            ?: throw FileNotFoundException("Could not obtain StorageManager")

        val handlerThread = HandlerThread("vc_proxy_${volId}_${System.nanoTime()}").apply { start() }
        val handler = Handler(handlerThread.looper)

        val callback = VeraCryptProxyCallback(volId, session, fatPath, isWrite, handlerThread)

        return try {
            val parcelMode = ParcelFileDescriptor.parseMode(mode ?: "r")
            storageManager.openProxyFileDescriptor(parcelMode, callback, handler)
        } catch (e: Exception) {
            handlerThread.quitSafely()
            throw FileNotFoundException("Failed to open proxy file descriptor: ${e.message}")
        }
    }

    @Throws(FileNotFoundException::class)
    override fun openDocumentThumbnail(
        documentId: String?,
        sizeHint: Point?,
        signal: CancellationSignal?
    ): AssetFileDescriptor {
        val docId   = documentId ?: throw FileNotFoundException("No document ID")
        val parts   = docId.split(":")
        if (parts.size < 3) throw FileNotFoundException("Invalid document ID for thumbnail: $docId")

        // FIX: bounds-checked volId parse + requireSession
        val volId   = parseVolId(parts[0])
        val session = requireSession(volId)
        val fatPath = parts.drop(2).joinToString(":")

        val pipe     = ParcelFileDescriptor.createPipe()
        val readEnd  = pipe[0]
        val writeEnd = pipe[1]

        Thread {
            val tempFile = File(context?.cacheDir, "thumb_${System.nanoTime()}")
            try {
                val ok = synchronized(VeraCryptSession.locks[volId]) {
                    VeraCryptEngine.unlockAndExtractNative(
                        detachFd(session.uri, "r"), "", 0, fatPath, tempFile.absolutePath, volId)
                }

                if (ok && tempFile.exists()) {
                    val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(tempFile.absolutePath, opts)
                    val reqW = sizeHint?.x ?: 256
                    val reqH = sizeHint?.y ?: 256
                    opts.inSampleSize    = calculateInSampleSize(opts, reqW, reqH)
                    opts.inJustDecodeBounds = false
                    val bmp = BitmapFactory.decodeFile(tempFile.absolutePath, opts)
                    if (bmp != null) {
                        ParcelFileDescriptor.AutoCloseOutputStream(writeEnd).use { out ->
                            bmp.compress(Bitmap.CompressFormat.JPEG, 85, out)
                        }
                        bmp.recycle()
                        return@Thread
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("vaultexplorer", "openDocumentThumbnail: ${e.message}")
            } finally {
                if (tempFile.exists()) tempFile.delete()
                runCatching { writeEnd.close() }
            }
        }.start()

        return AssetFileDescriptor(readEnd, 0, AssetFileDescriptor.UNKNOWN_LENGTH)
    }

    /**
     * Fully in-memory, ZERO-COPY file bridge optimized for fvp / FFmpeg.
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
        private var streamPtr: Long = 0L // Holds the C++ FIL* pointer

        init {
            try {
                synchronized(VeraCryptSession.locks[volId]) {
                    fileSizeCached = VeraCryptEngine.getFileSizeNative(-1, "", 0, fatPath, volId)
                    if (fileSizeCached < 0) fileSizeCached = 0L
                    
                    if (!isWrite) {
                        streamPtr = VeraCryptEngine.openStreamNative(-1, "", 0, fatPath, volId)
                    }
                }
            } catch (e: Exception) {
                handlerThread.quitSafely()
                throw FileNotFoundException("VeraCrypt init failed for $fatPath: ${e.message}")
            }
        }

        override fun onGetSize(): Long = fileSizeCached

        override fun onRead(offset: Long, size: Int, data: ByteArray): Int {
            if (offset >= fileSizeCached || streamPtr == 0L) return 0
            val readSize = minOf(size.toLong(), fileSizeCached - offset).toInt()
            if (readSize <= 0) return 0

            val actualRead = synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.readStreamNative(streamPtr, offset, data, readSize, volId)
            }
            
            if (actualRead < 0) throw ErrnoException("onRead", OsConstants.EIO)
            return actualRead
        }

        override fun onWrite(offset: Long, size: Int, data: ByteArray): Int {
            if (!isWrite) throw ErrnoException("onWrite", OsConstants.EBADF)
            
            val chunkData = if (data.size == size) data else data.copyOf(size)
            val success = synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.writeFileChunkNative(
                    -1, "", 0, fatPath, offset, chunkData, volId)
            }
            
            if (!success) throw ErrnoException("onWrite", OsConstants.EIO)
            val endOffset = offset + size
            if (endOffset > fileSizeCached) fileSizeCached = endOffset
            hasChanges = true
            return size
        }

        override fun onFsync() {}

        override fun onRelease() {
            synchronized(VeraCryptSession.locks[volId]) {
                if (streamPtr != 0L) {
                    VeraCryptEngine.closeStreamNative(streamPtr, volId)
                    streamPtr = 0L
                }
            }
            
            if (isWrite && hasChanges) {
                val parentPath = if (fatPath.contains("/")) fatPath.substringBeforeLast("/") else ""
                context?.contentResolver?.notifyChange(
                    DocumentsContract.buildChildDocumentsUri(
                        "com.aeidolon.vaultexplorer.documents", "$volId:dir:$parentPath"), null)
            }
            handlerThread.quitSafely()
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun calculateInSampleSize(options: BitmapFactory.Options, reqWidth: Int, reqHeight: Int): Int {
        val height = options.outHeight
        val width  = options.outWidth
        var inSampleSize = 1
        if (height > reqHeight || width > reqWidth) {
            val halfHeight = height / 2
            val halfWidth  = width / 2
            while (halfHeight / inSampleSize >= reqHeight && halfWidth / inSampleSize >= reqWidth) {
                inSampleSize *= 2
            }
        }
        return inSampleSize
    }

    private fun getRealSpace(session: ContainerSession): Pair<Long, Long> = try {
        val space = synchronized(VeraCryptSession.locks[session.volId]) {
            VeraCryptEngine.getSpaceInfoNative(detachFd(session.uri, "r"), "", 0, session.volId)
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

    private fun getMimeType(fileName: String): String = MimeTypeHelper.getMimeType(fileName)
}