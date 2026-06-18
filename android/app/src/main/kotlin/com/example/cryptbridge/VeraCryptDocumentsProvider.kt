package com.example.cryptbridge

import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import java.io.File
import java.io.FileNotFoundException
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

    private fun refreshFilesList(volId: Int) {
        val session = VeraCryptSession.activeSessions[volId] ?: return
        try {
            val fd = getFd(session.uri, "r")
            val files = VeraCryptEngine.unlockAndListNative(fd, session.password, session.pim, volId)
            if (files != null) {
                session.cachedFilesList = files.toList()
                
                val rootsUri = DocumentsContract.buildRootsUri("com.example.cryptbridge.documents")
                context?.contentResolver?.notifyChange(rootsUri, null)
                val childrenUri = DocumentsContract.buildChildDocumentsUri("com.example.cryptbridge.documents", "${volId}_root")
                context?.contentResolver?.notifyChange(childrenUri, null)
            }
        } catch (e: Exception) {
            android.util.Log.e("CryptBridge_Provider", "Refresh list failed for volume $volId: ${e.message}")
        }
    }

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val flags = DocumentsContract.Root.FLAG_SUPPORTS_CREATE or DocumentsContract.Root.FLAG_LOCAL_ONLY
        val cursor = MatrixCursor(projection ?: defaultRootProjection)

        // Expose a native Root/Drive in the sidebar for EVERY unlocked container!
        for ((volId, session) in VeraCryptSession.activeSessions) {
            val fileName = Uri.parse(session.uri).lastPathSegment ?: "Container $volId"
            cursor.newRow().apply {
                add(DocumentsContract.Root.COLUMN_ROOT_ID, volId.toString())
                add(DocumentsContract.Root.COLUMN_DOCUMENT_ID, "${volId}_root")
                add(DocumentsContract.Root.COLUMN_TITLE, "VC: $fileName")
                add(DocumentsContract.Root.COLUMN_SUMMARY, "Drive slot $volId")
                add(DocumentsContract.Root.COLUMN_FLAGS, flags)
                add(DocumentsContract.Root.COLUMN_ICON, android.R.drawable.ic_lock_idle_charging)
            }
        }

        // Show a helpful locked placeholder drive if no containers are open
        if (!VeraCryptSession.hasAnyActiveSessions()) {
            cursor.newRow().apply {
                add(DocumentsContract.Root.COLUMN_ROOT_ID, "locked")
                add(DocumentsContract.Root.COLUMN_DOCUMENT_ID, "locked_placeholder")
                add(DocumentsContract.Root.COLUMN_TITLE, "CryptBridge")
                add(DocumentsContract.Root.COLUMN_SUMMARY, "Locked - Open App to Unlock")
                add(DocumentsContract.Root.COLUMN_FLAGS, flags)
                add(DocumentsContract.Root.COLUMN_ICON, android.R.drawable.ic_lock_idle_lock)
            }
        }
        return cursor
    }

    override fun queryDocument(documentId: String?, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: defaultDocumentProjection)
        val docId = documentId ?: "locked_placeholder"

        if (docId == "locked_placeholder") {
            cursor.newRow().apply {
                add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, "locked_placeholder")
                add(DocumentsContract.Document.COLUMN_MIME_TYPE, "text/plain")
                add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, "⚠️ Please unlock container in CryptBridge App")
                add(DocumentsContract.Document.COLUMN_FLAGS, 0)
                add(DocumentsContract.Document.COLUMN_SIZE, 0)
            }
        } else if (docId.endsWith("_root")) {
            val volId = docId.substringBefore("_")
            cursor.newRow().apply {
                add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, docId)
                add(DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.MIME_TYPE_DIR)
                add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, "CryptBridge Root $volId")
                add(DocumentsContract.Document.COLUMN_FLAGS, DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE)
                add(DocumentsContract.Document.COLUMN_SIZE, 0)
            }
        } else {
            val volId = VeraCryptSession.getVolumeIdByDocId(docId) ?: 0
            val cleanId = docId.substringAfter("_")
            val isDirectory = cleanId.startsWith("[DIR] ")
            val displayName = if (isDirectory) cleanId.substringAfter("[DIR] ") else cleanId
            val mimeType = if (isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else getMimeType(cleanId)
            
            var flags = DocumentsContract.Document.FLAG_SUPPORTS_DELETE
            if (isDirectory) {
                flags = flags or DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
            } else {
                flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_WRITE
            }

            cursor.newRow().apply {
                add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, docId)
                add(DocumentsContract.Document.COLUMN_MIME_TYPE, mimeType)
                add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, displayName)
                add(DocumentsContract.Document.COLUMN_FLAGS, flags)
                add(DocumentsContract.Document.COLUMN_SIZE, 0)
            }
        }
        return cursor
    }

    override fun queryChildDocuments(parentDocumentId: String?, projection: Array<out String>?, sortOrder: String?): Cursor {
        val cursor = MatrixCursor(projection ?: defaultDocumentProjection)
        val parentId = parentDocumentId ?: "locked_placeholder"
        
        if (parentId == "locked_placeholder") {
            cursor.newRow().apply {
                add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, "locked_placeholder")
                add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, "⚠️ Please unlock container in CryptBridge App")
                add(DocumentsContract.Document.COLUMN_MIME_TYPE, "text/plain")
                add(DocumentsContract.Document.COLUMN_FLAGS, 0)
                add(DocumentsContract.Document.COLUMN_SIZE, 0)
            }
            return cursor
        }

        val volId = parentId.substringBefore("_").toIntOrNull() ?: return cursor
        val session = VeraCryptSession.activeSessions[volId] ?: return cursor

        for (file in session.cachedFilesList) {
            if (file.startsWith("System:")) continue
            
            val isDirectory = file.startsWith("[DIR] ")
            val displayName = if (isDirectory) file.substringAfter("[DIR] ") else file
            val mimeType = if (isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else getMimeType(file)
            
            var flags = DocumentsContract.Document.FLAG_SUPPORTS_DELETE
            if (isDirectory) {
                flags = flags or DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
            } else {
                flags = flags or DocumentsContract.Document.FLAG_SUPPORTS_WRITE
            }

            // Prefix documentId with volId to route read/writes correctly (e.g. "0_photo.png")
            cursor.newRow().apply {
                add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, "${volId}_$file")
                add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, displayName)
                add(DocumentsContract.Document.COLUMN_MIME_TYPE, mimeType)
                add(DocumentsContract.Document.COLUMN_FLAGS, flags)
                add(DocumentsContract.Document.COLUMN_SIZE, 0)
            }
        }
        return cursor
    }

    @Throws(FileNotFoundException::class)
    override fun createDocument(parentDocumentId: String?, mimeType: String?, displayName: String?): String {
        val parentId = parentDocumentId ?: throw FileNotFoundException("No parent ID")
        val volId = parentId.substringBefore("_").toIntOrNull() ?: throw FileNotFoundException("Invalid volume")
        val session = VeraCryptSession.activeSessions[volId] ?: throw FileNotFoundException("No session")
        val fileName = displayName ?: throw FileNotFoundException("No file name")

        val tempFile = File(context?.cacheDir, fileName)
        try {
            tempFile.createNewFile()
            val success = VeraCryptEngine.writeBackFileNative(getFd(session.uri, "rw"), session.password, session.pim, fileName, tempFile.absolutePath, volId)
            tempFile.delete()
            if (!success) throw IOException("Write back failed")
        } catch (e: Exception) {
            throw FileNotFoundException("File creation failed: ${e.message}")
        }

        refreshFilesList(volId)
        return "${volId}_$fileName"
    }

    @Throws(FileNotFoundException::class)
    override fun deleteDocument(documentId: String?) {
        val docId = documentId ?: throw FileNotFoundException("No document ID")
        val volId = VeraCryptSession.getVolumeIdByDocId(docId) ?: throw FileNotFoundException("Invalid volume")
        val session = VeraCryptSession.activeSessions[volId] ?: throw FileNotFoundException("No session")
        val cleanName = docId.substringAfter("_")

        val success = VeraCryptEngine.deleteFileNative(getFd(session.uri, "rw"), session.password, session.pim, cleanName, volId)
        if (!success) throw FileNotFoundException("Delete failed")

        refreshFilesList(volId)
    }

    @Throws(FileNotFoundException::class)
    override fun openDocument(documentId: String?, mode: String?, signal: CancellationSignal?): ParcelFileDescriptor {
        val docId = documentId ?: throw FileNotFoundException("No document ID")
        val volId = VeraCryptSession.getVolumeIdByDocId(docId) ?: throw FileNotFoundException("Invalid volume")
        val session = VeraCryptSession.activeSessions[volId] ?: throw FileNotFoundException("No session")
        val cleanName = docId.substringAfter("_")

        val isWrite = mode?.contains("w") == true || mode?.contains("r+") == true
        val tempFile = File(context?.cacheDir, cleanName)

        if (isWrite) {
            if (!tempFile.exists()) {
                VeraCryptEngine.unlockAndExtractNative(getFd(session.uri, "r"), session.password, session.pim, cleanName, tempFile.absolutePath, volId)
            }
            val handler = Handler(context!!.mainLooper)
            return ParcelFileDescriptor.open(tempFile, ParcelFileDescriptor.MODE_READ_WRITE, handler, ParcelFileDescriptor.OnCloseListener {
                VeraCryptEngine.writeBackFileNative(getFd(session.uri, "rw"), session.password, session.pim, cleanName, tempFile.absolutePath, volId)
                refreshFilesList(volId)
                tempFile.delete()
            })
        } else {
            val success = VeraCryptEngine.unlockAndExtractNative(getFd(session.uri, "r"), session.password, session.pim, cleanName, tempFile.absolutePath, volId)
            if (!success || !tempFile.exists()) throw FileNotFoundException("Decrypt failed")
            return ParcelFileDescriptor.open(tempFile, ParcelFileDescriptor.MODE_READ_ONLY)
        }
    }

    private fun getMimeType(fileName: String): String {
        return when {
            fileName.endsWith(".png", true) -> "image/png"
            fileName.endsWith(".jpg", true) || fileName.endsWith(".jpeg", true) -> "image/jpeg"
            fileName.endsWith(".txt", true) -> "text/plain"
            fileName.endsWith(".pdf", true) -> "application/pdf"
            else -> "application/octet-stream"
        }
    }
}