package com.example.cryptbridge

data class ContainerSession(
    val uri: String,
    val password: String,
    val pim: Int,
    val volId: Int,
    var cachedFilesList: List<String>
)

object VeraCryptSession {
    // Map storing active volume ID as key, and ContainerSession as value
    val activeSessions = mutableMapOf<Int, ContainerSession>()

    fun isUnlocked(volId: Int): Boolean {
        return activeSessions.containsKey(volId)
    }

    fun hasAnyActiveSessions(): Boolean {
        return activeSessions.isNotEmpty()
    }

    // Allocate an empty drive slot (0 to 3)
    fun getFreeVolumeId(): Int? {
        for (i in 0..3) {
            if (!activeSessions.containsKey(i)) return i
        }
        return null
    }

    fun getSessionByUri(uri: String): ContainerSession? {
        return activeSessions.values.find { it.uri == uri }
    }

    fun getVolumeIdByUri(uri: String): Int? {
        return activeSessions.entries.find { it.value.uri == uri }?.key
    }

    fun getVolumeIdByDocId(docId: String): Int? {
        // e.g. "0_file.txt" -> extracts "0"
        return docId.substringBefore("_").toIntOrNull()
    }

    fun removeSession(volId: Int) {
        activeSessions.remove(volId)
    }
}