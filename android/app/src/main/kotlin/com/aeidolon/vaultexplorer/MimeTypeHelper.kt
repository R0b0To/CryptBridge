package com.aeidolon.vaultexplorer

object MimeTypeHelper {
    fun getMimeType(fileName: String): String = when {
        fileName.endsWith(".png",  ignoreCase = true)                                         -> "image/png"
        fileName.endsWith(".jpg",  ignoreCase = true) || fileName.endsWith(".jpeg", ignoreCase = true) -> "image/jpeg"
        fileName.endsWith(".webp", ignoreCase = true)                                         -> "image/webp"
        fileName.endsWith(".gif",  ignoreCase = true)                                         -> "image/gif"
        fileName.endsWith(".mp4",  ignoreCase = true) || fileName.endsWith(".m4v",  ignoreCase = true) -> "video/mp4"
        fileName.endsWith(".webm", ignoreCase = true)                                         -> "video/webm"
        fileName.endsWith(".mkv",  ignoreCase = true)                                         -> "video/x-matroska"
        fileName.endsWith(".mov",  ignoreCase = true)                                         -> "video/quicktime"
        fileName.endsWith(".avi",  ignoreCase = true)                                         -> "video/x-msvideo"
        fileName.endsWith(".mp3",  ignoreCase = true)                                         -> "audio/mpeg"
        fileName.endsWith(".m4a",  ignoreCase = true)                                         -> "audio/mp4"
        fileName.endsWith(".wav",  ignoreCase = true)                                         -> "audio/wav"
        fileName.endsWith(".flac", ignoreCase = true)                                         -> "audio/flac"
        fileName.endsWith(".ogg",  ignoreCase = true)                                         -> "audio/ogg"
        fileName.endsWith(".aac",  ignoreCase = true)                                         -> "audio/aac"
        fileName.endsWith(".txt",  ignoreCase = true)                                         -> "text/plain"
        fileName.endsWith(".pdf",  ignoreCase = true)                                         -> "application/pdf"
        fileName.endsWith(".doc",  ignoreCase = true)                                         -> "application/msword"
        fileName.endsWith(".docx", ignoreCase = true)                                         -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        fileName.endsWith(".xls",  ignoreCase = true)                                         -> "application/vnd.ms-excel"
        fileName.endsWith(".xlsx", ignoreCase = true)                                         -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        fileName.endsWith(".zip",  ignoreCase = true)                                         -> "application/zip"
        else                                                                                   -> "application/octet-stream"
    }
}