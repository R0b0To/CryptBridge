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

    // ── Roots ──────────────────────────────────────────────────────────────

    override fun queryRoots(projection: Array<out String>?): Cursor {
        var flags = DocumentsContract.Root.FLAG_SUPPORTS_CREATE or
                DocumentsContract.Root.FLAG_LOCAL_ONLY or
                DocumentsContract.Root.FLAG_SUPPORTS_EJECT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            flags = flags or DocumentsContract.Root.FLAG_SUPPORTS_IS_CHILD
        }

        val cursor = MatrixCursor(projection ?: defaultRootProjection)
        for ((volId, session) in VeraCryptSession.activeSessions.filter { it.value.documentProvider }) {
            val rootTitle = session.displayName
                ?: UriNameResolver.resolve(context?.contentResolver, Uri.parse(session.uri))
            val (totalBytes, freeBytes) = VeraCryptBridge.getSpacePair(volId)
            val rootSummary = if (totalBytes > 0)
                "Volume — ${android.text.format.Formatter.formatFileSize(context, freeBytes)} free"
            else "Volume"

            cursor.newRow().apply {
                add(DocumentsContract.Root.COLUMN_ROOT_ID, volId.toString())
                add(DocumentsContract.Root.COLUMN_MIME_TYPES, "*/*")
                add(DocumentsContract.Root.COLUMN_DOCUMENT_ID,
                    DocumentId(volId, "dir", "").toString())
                add(DocumentsContract.Root.COLUMN_TITLE, rootTitle)
                add(DocumentsContract.Root.COLUMN_SUMMARY, rootSummary)
                add(DocumentsContract.Root.COLUMN_FLAGS, flags)
                add(DocumentsContract.Root.COLUMN_ICON,
                    android.R.drawable.ic_lock_idle_charging)
                add(DocumentsContract.Root.COLUMN_AVAILABLE_BYTES, freeBytes)
                add(DocumentsContract.Root.COLUMN_CAPACITY_BYTES, totalBytes)
            }
        }
        return cursor
    }

    override fun isChildDocument(parentDocumentId: String?, documentId: String?): Boolean {
        if (parentDocumentId == null || documentId == null) return false
        val parent = try { DocumentId.parse(parentDocumentId, "parent") }
                     catch (_: FileNotFoundException) { return false }
        val child  = try { DocumentId.parse(documentId, "child") }
                     catch (_: FileNotFoundException) { return false }
        if (parent.volId != child.volId) return false
        return if (parent.fatPath.isEmpty()) true
               else child.fatPath.startsWith("${parent.fatPath}/")
    }

    override fun ejectRoot(rootId: String?) {
        val volId = rootId?.toIntOrNull()
            ?.takeIf { it in 0 until VeraCryptSession.MAX_VOLUMES }
            ?: return
        // lockNative takes only volId — no session required, so direct call
        // (not via Bridge) is correct here; the Bridge requires an active session.
        VeraCryptEngine.lockNative(volId)
        VeraCryptSession.removeSession(volId)
        context?.contentResolver?.notifyChange(
            DocumentsContract.buildRootsUri("com.aeidolon.vaultexplorer.documents"), null
        )
    }

    // ── Document queries ───────────────────────────────────────────────────

    override fun queryDocument(documentId: String?, projection: Array<out String>?): Cursor {
        val cursor  = MatrixCursor(projection ?: defaultDocumentProjection)
        val doc     = DocumentId.parse(documentId, "document")
        val volId   = doc.volId
        val fatPath = doc.fatPath

        val displayName = if (fatPath.isEmpty()) "Root $volId"
                          else fatPath.substringAfterLast("/")
        val mimeType = if (doc.isDir) DocumentsContract.Document.MIME_TYPE_DIR
                       else MimeTypeHelper.getMimeType(displayName)

        val size: Long = if (doc.isDir) 0L else {
            try {
                VeraCryptBridge.requireSession(volId)  // fast existence check
                VeraCryptBridge.getFileSize(volId, fatPath)
            } catch (_: Exception) { 0L }
        }

        var flags = DocumentsContract.Document.FLAG_SUPPORTS_DELETE
        if (doc.isDir) {
            flags = flags or DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
        } else {
            flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_WRITE
            if (mimeType.startsWith("image/"))
                flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_THUMBNAIL
        }

        cursor.newRow().apply {
            add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, doc.toString())
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
        val cursor        = MatrixCursor(projection ?: defaultDocumentProjection)
        val parent        = DocumentId.parse(parentDocumentId, "parent")
        val volId         = parent.volId
        val parentFatPath = parent.fatPath
        VeraCryptBridge.requireSession(volId)   // throws FileNotFoundException if not unlocked

        try {
            val files = VeraCryptBridge.listDirectory(volId, parentFatPath)
            files?.forEach { file ->
                if (file.startsWith("System:")) return@forEach
                val isDir     = file.startsWith("[DIR] ")
                val cleanName = if (isDir) file.substringAfter("[DIR] ").substringBefore("|")
                                else file.substringBefore("|")
                val size      = if (isDir) 0L
                                else file.split("|").getOrNull(1)?.toLongOrNull() ?: 0L
                val childFatPath = if (parentFatPath.isEmpty()) cleanName
                                   else "$parentFatPath/$cleanName"
                val childType    = if (isDir) "dir" else "file"
                val childMime    = if (isDir) DocumentsContract.Document.MIME_TYPE_DIR
                                   else MimeTypeHelper.getMimeType(cleanName)

                var flags = DocumentsContract.Document.FLAG_SUPPORTS_DELETE
                if (isDir) {
                    flags = flags or DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
                } else {
                    flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_WRITE
                    if (childMime.startsWith("image/"))
                        flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_THUMBNAIL
                }

                cursor.newRow().apply {
                    add(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentId(volId, childType, childFatPath).toString())
                    add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, cleanName)
                    add(DocumentsContract.Document.COLUMN_MIME_TYPE, childMime)
                    add(DocumentsContract.Document.COLUMN_FLAGS, flags)
                    add(DocumentsContract.Document.COLUMN_SIZE, size)
                }
            }
        } catch (e: FileNotFoundException) {
            throw e
        } catch (e: Exception) {
            android.util.Log.e("vaultexplorer_Provider",
                "queryChildDocuments failed for $parentDocumentId: ${e.javaClass.simpleName}")
        }
        return cursor
    }

    // ── Mutations ──────────────────────────────────────────────────────────

    @Throws(FileNotFoundException::class)
    override fun createDocument(
        parentDocumentId: String?,
        mimeType: String?,
        displayName: String?
    ): String {
        val parent        = DocumentId.parse(parentDocumentId, "parent")
        val volId         = parent.volId
        val parentFatPath = parent.fatPath
        VeraCryptBridge.requireSession(volId)
        val fileName  = displayName ?: throw FileNotFoundException("No file name provided")
        val cleanPath = if (parentFatPath.isEmpty()) fileName else "$parentFatPath/$fileName"
        val isDirectory = mimeType == DocumentsContract.Document.MIME_TYPE_DIR

        val success = if (isDirectory) {
            VeraCryptBridge.createDirectory(volId, cleanPath)
        } else {
            val tempFile = File(
                context?.cacheDir,
                "vc_new_${volId}_${cleanPath.hashCode()}_$fileName"
            )
            try {
                tempFile.delete()
                tempFile.createNewFile()
                VeraCryptBridge.writeBackFile(volId, cleanPath, tempFile.absolutePath)
            } finally {
                tempFile.delete()
            }
        }

        if (!success) throw FileNotFoundException("Creation failed for $cleanPath")

        val childType = if (isDirectory) "dir" else "file"
        context?.contentResolver?.notifyChange(
            DocumentsContract.buildChildDocumentsUri(
                "com.aeidolon.vaultexplorer.documents", parentDocumentId), null
        )
        return DocumentId(volId, childType, cleanPath).toString()
    }

    @Throws(FileNotFoundException::class)
    override fun deleteDocument(documentId: String?) {
        val doc     = DocumentId.parse(documentId, "document")
        val volId   = doc.volId
        val fatPath = doc.fatPath
        VeraCryptBridge.requireSession(volId)

        val success = VeraCryptBridge.deleteFile(volId, fatPath)
        if (!success) throw FileNotFoundException("Delete failed for $fatPath")

        val parentPath = if (fatPath.contains("/")) fatPath.substringBeforeLast("/") else ""
        context?.contentResolver?.notifyChange(
            DocumentsContract.buildChildDocumentsUri(
                "com.aeidolon.vaultexplorer.documents",
                DocumentId(volId, "dir", parentPath).toString()), null
        )
    }

    // ── File open (proxy) ──────────────────────────────────────────────────

    @Throws(FileNotFoundException::class)
    override fun openDocument(
        documentId: String?,
        mode: String?,
        signal: CancellationSignal?
    ): ParcelFileDescriptor {
        val doc     = DocumentId.parse(documentId, "document")
        val volId   = doc.volId
        val session = VeraCryptBridge.requireSession(volId)
        val fatPath = doc.fatPath
        val isWrite = mode?.contains("w") == true || mode?.contains("r+") == true

        val storageManager = context?.getSystemService(Context.STORAGE_SERVICE) as? StorageManager
            ?: throw FileNotFoundException("Could not obtain StorageManager")

        val handlerThread = HandlerThread(
            "vc_proxy_${volId}_${System.nanoTime()}"
        ).apply { start() }
        val handler = Handler(handlerThread.looper)

        val callback = VeraCryptProxyCallback(volId, session, fatPath, isWrite, handlerThread)

        return try {
            val parcelMode = ParcelFileDescriptor.parseMode(mode ?: "r")
            storageManager.openProxyFileDescriptor(parcelMode, callback, handler)
        } catch (e: Exception) {
            handlerThread.quitSafely()
            throw FileNotFoundException(
                "Failed to open proxy file descriptor: ${e.message}"
            )
        }
    }

    // ── Thumbnail ──────────────────────────────────────────────────────────

    @Throws(FileNotFoundException::class)
    override fun openDocumentThumbnail(
        documentId: String?,
        sizeHint: Point?,
        signal: CancellationSignal?
    ): AssetFileDescriptor {
        val doc     = DocumentId.parse(documentId, "document")
        val volId   = doc.volId
        val fatPath = doc.fatPath
        if (fatPath.isEmpty()) throw FileNotFoundException(
            "Cannot generate thumbnail for volume root"
        )
        VeraCryptBridge.requireSession(volId)

        val pipe     = ParcelFileDescriptor.createPipe()
        val readEnd  = pipe[0]
        val writeEnd = pipe[1]

        Thread {
            val tempFile = File(context?.cacheDir, "thumb_${System.nanoTime()}")
            try {
                val ok = VeraCryptBridge.extractToFile(volId, fatPath, tempFile.absolutePath)

                if (ok && tempFile.exists()) {
                    val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(tempFile.absolutePath, opts)
                    val reqW = sizeHint?.x ?: 256
                    val reqH = sizeHint?.y ?: 256
                    opts.inSampleSize       = calculateInSampleSize(opts, reqW, reqH)
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

    // ── Proxy callback (zero-copy stream bridge) ───────────────────────────
    //
    // Intentionally does NOT use VeraCryptBridge for the stream lifecycle:
    // openStreamNative / readStreamNative / closeStreamNative pass a raw C++
    // FIL* pointer as a Long across calls, which is specific to this callback's
    // own lifecycle and has no place in a general-purpose bridge.

    inner class VeraCryptProxyCallback(
        private val volId: Int,
        private val session: ContainerSession,
        private val fatPath: String,
        private val isWrite: Boolean,
        private val handlerThread: HandlerThread
    ) : ProxyFileDescriptorCallback() {

        private var hasChanges = false
        private var fileSizeCached: Long = -1L
        private var streamPtr: Long = 0L

        init {
            try {
                VeraCryptBridge.withLock(volId) {
                    fileSizeCached = VeraCryptEngine.getFileSize(fatPath, volId)
                    if (fileSizeCached < 0) fileSizeCached = 0L
                    if (!isWrite) {
                        streamPtr = VeraCryptEngine.openStream(fatPath, volId)
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
            val actualRead = VeraCryptBridge.withLock(volId) {
                VeraCryptEngine.readStream(streamPtr, offset, data, readSize, volId)
            }
            if (actualRead < 0) throw ErrnoException("onRead", OsConstants.EIO)
            return actualRead
        }

        override fun onWrite(offset: Long, size: Int, data: ByteArray): Int {
            if (!isWrite) throw ErrnoException("onWrite", OsConstants.EBADF)
            val chunkData = if (data.size == size) data else data.copyOf(size)
            val success = VeraCryptBridge.withLock(volId) {
                VeraCryptEngine.writeFileChunk(fatPath, offset, chunkData, volId)
            }
            if (!success) throw ErrnoException("onWrite", OsConstants.EIO)
            val endOffset = offset + size
            if (endOffset > fileSizeCached) fileSizeCached = endOffset
            hasChanges = true
            return size
        }

        override fun onFsync() {}

        override fun onRelease() {
            VeraCryptBridge.withLock(volId) {
                if (streamPtr != 0L) {
                    VeraCryptEngine.closeStream(streamPtr, volId)
                    streamPtr = 0L
                }
            }
            if (isWrite && hasChanges) {
                val parentPath = if (fatPath.contains("/"))
                    fatPath.substringBeforeLast("/") else ""
                context?.contentResolver?.notifyChange(
                    DocumentsContract.buildChildDocumentsUri(
                        "com.aeidolon.vaultexplorer.documents",
                        DocumentId(volId, "dir", parentPath).toString()), null)
            }
            handlerThread.quitSafely()
        }
    }

    // ── Private helpers ────────────────────────────────────────────────────

    private fun calculateInSampleSize(
        options: BitmapFactory.Options, reqWidth: Int, reqHeight: Int
    ): Int {
        val height = options.outHeight
        val width  = options.outWidth
        var inSampleSize = 1
        if (height > reqHeight || width > reqWidth) {
            val halfHeight = height / 2
            val halfWidth  = width / 2
            while (halfHeight / inSampleSize >= reqHeight &&
                   halfWidth / inSampleSize >= reqWidth) {
                inSampleSize *= 2
            }
        }
        return inSampleSize
    }
}