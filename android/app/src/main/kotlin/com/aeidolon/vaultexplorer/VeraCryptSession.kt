package com.aeidolon.vaultexplorer

data class ContainerSession(
    val uri: String,
    val password: String,
    val pim: Int,
    val volId: Int,
    var cachedFilesList: List<String>,
    val displayName: String? = null
)

object VeraCryptSession {
    // 4 locks corresponding to the 4 volume slots (0 to 3) [2]
    val locks = Array(4) { Any() }

    val activeSessions = mutableMapOf<Int, ContainerSession>()

    fun isUnlocked(volId: Int): Boolean {
        return activeSessions.containsKey(volId)
    }

    fun hasAnyActiveSessions(): Boolean {
        return activeSessions.isNotEmpty()
    }

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
        return docId.substringBefore("_").toIntOrNull()
    }

    fun removeSession(volId: Int) {
        activeSessions.remove(volId)
    }
}