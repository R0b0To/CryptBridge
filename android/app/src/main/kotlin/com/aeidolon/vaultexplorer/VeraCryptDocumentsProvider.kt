package com.aeidolon.vaultexplorer

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
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException

class VeraCryptDocumentsProvider : DocumentsProvider() {

    private val defaultRootProjection: Array<String> = arrayOf(
        DocumentsContract.Root.COLUMN_ROOT_ID,
        DocumentsContract.Root.COLUMN_MIME_TYPES,
        DocumentsContract.Root.COLUMN_FLAGS,
        DocumentsContract.Root.COLUMN_ICON,
        DocumentsContract.Root.COLUMN_TITLE,
        DocumentsContract.Root.COLUMN_SUMMARY,
        DocumentsContract.Root.COLUMN_DOCUMENT_ID
    )

    private val defaultDocumentProjection: Array<String> = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        DocumentsContract.Document.COLUMN_FLAGS,
        DocumentsContract.Document.COLUMN_SIZE
    )

    override fun onCreate(): Boolean {
        return true
    }

    private fun getFd(uriString: String, mode: String): Int {
        val uri = Uri.parse(uriString)
        val pfd = context?.contentResolver?.openFileDescriptor(uri, mode) ?: throw FileNotFoundException("Could open PFD")
        return pfd.detachFd()
    }

    override fun queryRoots(projection: Array<out String>?): Cursor {
        var flags = DocumentsContract.Root.FLAG_SUPPORTS_CREATE or 
                    DocumentsContract.Root.FLAG_LOCAL_ONLY or
                    DocumentsContract.Root.FLAG_SUPPORTS_EJECT
                    
        // Crucial: Tell the system that this provider supports sub-tree validation.
        // This is what makes it appear in standard app document pickers.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            flags = flags or DocumentsContract.Root.FLAG_SUPPORTS_IS_CHILD
        }
                    
        val cursor = MatrixCursor(projection ?: defaultRootProjection)

        for ((volId, session) in VeraCryptSession.activeSessions) {
            val rootTitle = session.displayName ?: getFileNameFromUri(session.uri)
            val rootSummary = getSpaceSummary(session.uri)
            
            cursor.newRow().apply {
                add(DocumentsContract.Root.COLUMN_ROOT_ID, volId.toString())
                add(DocumentsContract.Root.COLUMN_MIME_TYPES, "*/*") // Map MIME types to enable broad matching
                add(DocumentsContract.Root.COLUMN_DOCUMENT_ID, "$volId:dir:") // Root ID maps to dir:
                add(DocumentsContract.Root.COLUMN_TITLE, rootTitle)
                add(DocumentsContract.Root.COLUMN_SUMMARY, rootSummary)
                add(DocumentsContract.Root.COLUMN_FLAGS, flags)
                add(DocumentsContract.Root.COLUMN_ICON, android.R.drawable.ic_lock_idle_charging)
            }
        }

        return cursor
    }

    // Crucial: You must override this function when FLAG_SUPPORTS_IS_CHILD is set.
    // The picker uses it to verify whether a file belongs within the open tree directory.
    override fun isChildDocument(parentDocumentId: String?, documentId: String?): Boolean {
        if (parentDocumentId == null || documentId == null) return false
        
        val parentParts = parentDocumentId.split(":")
        val childParts = documentId.split(":")
        if (parentParts.size < 2 || childParts.size < 2) return false
        
        // Ensure they belong to the same volume slot
        val parentVolId = parentParts[0]
        val childVolId = childParts[0]
        if (parentVolId != childVolId) return false
        
        val parentFatPath = parentParts.drop(2).joinToString(":")
        val childFatPath = childParts.drop(2).joinToString(":")
        
        return if (parentFatPath.isEmpty()) {
            // An empty parent path represents the root directory, making any path a child.
            true
        } else {
            // Check if child's path is a nested descendant of the parent path
            childFatPath.startsWith("$parentFatPath/")
        }
    }

    override fun ejectRoot(rootId: String?) {
        val volId = rootId?.toIntOrNull() ?: return
        VeraCryptEngine.lockNative(volId)
        VeraCryptSession.removeSession(volId)
        
        val rootsUri = DocumentsContract.buildRootsUri("com.aeidolon.vaultexplorer.documents")
        context?.contentResolver?.notifyChange(rootsUri, null)
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
        val displayName = if (fatPath.isEmpty()) {
            "vaultexplorer Root $volId"
        } else {
            fatPath.substringAfterLast("/")
        }
        val mimeType = if (isDir) DocumentsContract.Document.MIME_TYPE_DIR else getMimeType(displayName)

        val size = if (isDir) {
            0L
        } else {
            try {
                val session = VeraCryptSession.activeSessions[volId]
                if (session != null) {
                    synchronized(VeraCryptSession.locks[volId]) {
                        VeraCryptEngine.getFileSizeNative(getFd(session.uri, "r"), session.password, session.pim, fatPath, volId)
                    }
                } else {
                    0L
                }
            } catch (e: Exception) {
                0L
            }
        }

        var flags = DocumentsContract.Document.FLAG_SUPPORTS_DELETE
        if (isDir) {
            flags = flags or DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
        } else {
            flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_WRITE
            if (mimeType.startsWith("image/")) {
                flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_THUMBNAIL
            }
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

    override fun queryChildDocuments(parentDocumentId: String?, projection: Array<out String>?, sortOrder: String?): Cursor {
        val cursor = MatrixCursor(projection ?: defaultDocumentProjection)
        val parentId = parentDocumentId ?: throw FileNotFoundException("No parent ID")

        val parts = parentId.split(":")
        if (parts.size < 2) throw FileNotFoundException("Invalid parent ID")
        val volId = parts[0].toIntOrNull() ?: throw FileNotFoundException("Invalid volume ID")
        val parentFatPath = parts.drop(2).joinToString(":")

        val session = VeraCryptSession.activeSessions[volId] ?: return cursor

        try {
            val fd = getFd(session.uri, "r")
            val files = synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.listDirectoryNative(fd, session.password, session.pim, parentFatPath, volId)
            }

            if (files != null) {
                for (file in files) {
                    if (file.startsWith("System:")) continue
                    
                    val isDir = file.startsWith("[DIR] ")
                    val cleanName = if (isDir) {
                        file.substringAfter("[DIR] ")
                    } else {
                        file.substringBefore("|")
                    }
                    
                    val size = if (isDir) {
                        0L
                    } else {
                        file.substringAfter("|", "0").toLongOrNull() ?: 0L
                    }

                    val childFatPath = if (parentFatPath.isEmpty()) cleanName else "$parentFatPath/$cleanName"
                    val childType = if (isDir) "dir" else "file"
                    val childMime = if (isDir) DocumentsContract.Document.MIME_TYPE_DIR else getMimeType(cleanName)
                    
                    var flags = DocumentsContract.Document.FLAG_SUPPORTS_DELETE
                    if (isDir) {
                        flags = flags or DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
                    } else {
                        flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_WRITE
                        if (childMime.startsWith("image/")) {
                            flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_THUMBNAIL
                        }
                    }

                    cursor.newRow().apply {
                        add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, "$volId:$childType:$childFatPath")
                        add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, cleanName)
                        add(DocumentsContract.Document.COLUMN_MIME_TYPE, childMime)
                        add(DocumentsContract.Document.COLUMN_FLAGS, flags)
                        add(DocumentsContract.Document.COLUMN_SIZE, size)
                    }
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("vaultexplorer_Provider", "Failed query for $parentId: ${e.message}")
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

        val session = VeraCryptSession.activeSessions[volId] ?: throw FileNotFoundException("No session")
        val fileName = displayName ?: throw FileNotFoundException("No file name")

        val cleanPath = if (parentFatPath.isEmpty()) fileName else "$parentFatPath/$fileName"
        val isDirectory = mimeType == DocumentsContract.Document.MIME_TYPE_DIR

        val success = if (isDirectory) {
            synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.createDirectoryNative(getFd(session.uri, "rw"), session.password, session.pim, cleanPath, volId)
            }
        } else {
            val tempFile = File(context?.cacheDir, fileName)
            try {
                tempFile.createNewFile()
                synchronized(VeraCryptSession.locks[volId]) {
                    VeraCryptEngine.writeBackFileNative(getFd(session.uri, "rw"), session.password, session.pim, cleanPath, tempFile.absolutePath, volId)
                }
            } finally {
                tempFile.delete()
            }
        }

        if (!success) throw FileNotFoundException("Creation failed.")

        val childType = if (isDirectory) "dir" else "file"
        
        val childrenUri = DocumentsContract.buildChildDocumentsUri("com.aeidolon.vaultexplorer.documents", parentId)
        context?.contentResolver?.notifyChange(childrenUri, null)

        return "$volId:$childType:$cleanPath"
    }

    @Throws(FileNotFoundException::class)
    override fun deleteDocument(documentId: String?) {
        val docId = documentId ?: throw FileNotFoundException("No document ID")
        val parts = docId.split(":")
        if (parts.size < 2) throw FileNotFoundException("Invalid document ID")
        val volId = parts[0].toIntOrNull() ?: throw FileNotFoundException("Invalid volume")
        val session = VeraCryptSession.activeSessions[volId] ?: throw FileNotFoundException("No session")
        val fatPath = parts.drop(2).joinToString(":")

        val success = synchronized(VeraCryptSession.locks[volId]) {
            VeraCryptEngine.deleteFileNative(getFd(session.uri, "rw"), session.password, session.pim, fatPath, volId)
        }
        if (!success) throw FileNotFoundException("Delete failed")

        val parentPath = if (fatPath.contains("/")) fatPath.substringBeforeLast("/") else ""
        val parentId = "$volId:dir:$parentPath"
        
        val childrenUri = DocumentsContract.buildChildDocumentsUri("com.aeidolon.vaultexplorer.documents", parentId)
        context?.contentResolver?.notifyChange(childrenUri, null)
    }

    @Throws(FileNotFoundException::class)
    override fun openDocument(documentId: String?, mode: String?, signal: CancellationSignal?): ParcelFileDescriptor {
        val docId = documentId ?: throw FileNotFoundException("No document ID")
        val parts = docId.split(":")
        if (parts.size < 2) throw FileNotFoundException("Invalid document ID")
        val volId = parts[0].toIntOrNull() ?: throw FileNotFoundException("Invalid volume")
        val session = VeraCryptSession.activeSessions[volId] ?: throw FileNotFoundException("No session")
        val fatPath = parts.drop(2).joinToString(":")

        val cleanName = fatPath.substringAfterLast("/")
        val isWrite = mode?.contains("w") == true || mode?.contains("r+") == true
        val tempFile = File(context?.cacheDir, cleanName)

        if (isWrite) {
            if (!tempFile.exists()) {
                synchronized(VeraCryptSession.locks[volId]) {
                    VeraCryptEngine.unlockAndExtractNative(getFd(session.uri, "r"), session.password, session.pim, fatPath, tempFile.absolutePath, volId)
                }
            }
            val handler = Handler(context!!.mainLooper)
            return ParcelFileDescriptor.open(tempFile, ParcelFileDescriptor.MODE_READ_WRITE, handler, ParcelFileDescriptor.OnCloseListener {
                synchronized(VeraCryptSession.locks[volId]) {
                    VeraCryptEngine.writeBackFileNative(getFd(session.uri, "rw"), session.password, session.pim, fatPath, tempFile.absolutePath, volId)
                }
                tempFile.delete()
            })
        } else {
            val success = synchronized(VeraCryptSession.locks[volId]) {
                VeraCryptEngine.unlockAndExtractNative(getFd(session.uri, "r"), session.password, session.pim, fatPath, tempFile.absolutePath, volId)
            }
            if (!success || !tempFile.exists()) throw FileNotFoundException("Decrypt failed")
            return ParcelFileDescriptor.open(tempFile, ParcelFileDescriptor.MODE_READ_ONLY)
        }
    }

    @Throws(FileNotFoundException::class)
    override fun openDocumentThumbnail(
        documentId: String?,
        sizeHint: Point?,
        signal: CancellationSignal?
    ): AssetFileDescriptor {
        val docId = documentId ?: throw FileNotFoundException("No document ID")
        val parts = docId.split(":")
        if (parts.size < 2) throw FileNotFoundException("Invalid document ID")
        val volId = parts[0].toIntOrNull() ?: throw FileNotFoundException("Invalid volume")
        val session = VeraCryptSession.activeSessions[volId] ?: throw FileNotFoundException("No session")
        val fatPath = parts.drop(2).joinToString(":")

        val cleanName = fatPath.substringAfterLast("/")
        val tempFile = File(context?.cacheDir, "thumb_$cleanName")

        val success = synchronized(VeraCryptSession.locks[volId]) {
            VeraCryptEngine.unlockAndExtractNative(getFd(session.uri, "r"), session.password, session.pim, fatPath, tempFile.absolutePath, volId)
        }
        if (!success || !tempFile.exists()) {
            throw FileNotFoundException("Failed to decrypt image for thumbnail")
        }

        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(tempFile.absolutePath, options)

        val reqWidth = sizeHint?.x ?: 128
        val reqHeight = sizeHint?.y ?: 128
        options.inSampleSize = calculateInSampleSize(options, reqWidth, reqHeight)
        options.inJustDecodeBounds = false

        val bitmap = BitmapFactory.decodeFile(tempFile.absolutePath, options)
        tempFile.delete()

        if (bitmap == null) {
            throw FileNotFoundException("Failed decoding decrypted thumbnail")
        }

        val thumbFile = File(context?.cacheDir, "thumb_scaled_$cleanName")
        try {
            FileOutputStream(thumbFile).use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 75, out)
            }
        } finally {
            bitmap.recycle()
        }

        val pfd = ParcelFileDescriptor.open(thumbFile, ParcelFileDescriptor.MODE_READ_ONLY)
        return AssetFileDescriptor(pfd, 0, thumbFile.length())
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

    private fun getFileNameFromUri(uriString: String): String {
        val uri = Uri.parse(uriString)
        if (uri.scheme == "content") {
            try {
                context?.contentResolver?.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIndex = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                        if (nameIndex != -1) {
                            return cursor.getString(nameIndex)
                        }
                    }
                }
            } catch (e: Exception) {
                // ignore
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "Container"
    }

    private fun getSpaceSummary(uriString: String): String {
        val uri = Uri.parse(uriString)
        var size = 0L
        if (uri.scheme == "content") {
            try {
                context?.contentResolver?.query(uri, arrayOf(android.provider.OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val sizeIndex = cursor.getColumnIndex(android.provider.OpenableColumns.SIZE)
                        if (sizeIndex != -1) {
                            size = cursor.getLong(sizeIndex)
                        }
                    }
                }
            } catch (e: Exception) {
                // ignore
            }
        }
        return if (size > 0) {
            val sizeStr = android.text.format.Formatter.formatFileSize(context, size)
            "VeraCrypt Volume ($sizeStr)"
        } else {
            "VeraCrypt Volume"
        }
    }

    private fun getMimeType(fileName: String): String {
        return when {
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
}