package com.aeidolon.vaultexplorer

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns

/**
 * Shared logic for resolving a human-readable display name for a Uri.
 *
 * Previously duplicated (with minor variations) in both MainActivity
 * (SAF container/tree picker results) and VeraCryptDocumentsProvider
 * (DocumentsProvider root title fallback). Consolidated here since both
 * call sites want the same behavior: query OpenableColumns.DISPLAY_NAME
 * for content:// Uris, falling back to the last path segment, and
 * finally to "Container" if nothing else is available.
 */
object UriNameResolver {
    fun resolve(resolver: ContentResolver?, uri: Uri): String {
        if (resolver != null && uri.scheme == "content") {
            try {
                resolver.query(
                    uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME),
                    null, null, null
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (idx != -1) {
                            cursor.getString(idx)?.let { return it }
                        }
                    }
                }
            } catch (_: Exception) {
                // fall through to path-segment fallback below
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "Container"
    }
}