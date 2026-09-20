package com.vaultbox.app.storage

import android.net.Uri
import android.os.Environment
import android.os.StatFs
import android.provider.DocumentsContract

/**
 * Free and total space of the volume a storage root lives on.
 *
 * A root is either a filesystem path (an app-storage folder) or a Storage Access
 * Framework tree URI (`content://com.android.externalstorage.documents/tree/<volume>:<folder>`).
 * For a tree the volume id is all we need: `primary` is the phone's own storage,
 * anything else (an SD card or USB drive) is mounted at `/storage/<volume id>`.
 * Reading a volume's size needs no permission and reveals nothing about its files.
 */
object VolumeStats {
    /** `{"free": bytes, "total": bytes}`, or `null` when the volume can't be measured. */
    fun of(uriOrPath: String): Map<String, Long>? {
        val path = volumePath(uriOrPath) ?: return null
        return try {
            val stat = StatFs(path)
            mapOf("free" to stat.availableBytes, "total" to stat.totalBytes)
        } catch (e: Exception) {
            null
        }
    }

    private fun volumePath(uriOrPath: String): String? {
        if (uriOrPath.startsWith("/")) return uriOrPath
        val treeId = try {
            DocumentsContract.getTreeDocumentId(Uri.parse(uriOrPath))
        } catch (e: Exception) {
            return null
        }
        val volumeId = treeId.substringBefore(':')
        return if (volumeId == "primary") {
            Environment.getExternalStorageDirectory().absolutePath
        } else {
            "/storage/$volumeId"
        }
    }
}
