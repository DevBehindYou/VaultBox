package com.vaultbox.app.storage

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import com.vaultbox.app.pigeon.AndroidStorageApi
import com.vaultbox.app.pigeon.FlutterError
import com.vaultbox.app.pigeon.PickedFileMessage
import com.vaultbox.app.pigeon.SafEntryMessage
import com.vaultbox.app.pigeon.SafEntryTypeMessage
import com.vaultbox.app.pigeon.SafTreeMessage
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

/**
 * Native half of the SAF storage bridge. Implements the Pigeon-generated
 * [AndroidStorageApi] (see `pigeons/storage_api.dart`).
 *
 * Reconciled against real Pigeon 29.0.2 output (CI run #4+), which is what the
 * first draft could only guess at:
 *  - every method is `suspend fun` (the spec marks them `@async`);
 *  - the generated `setUp` launches each call on `Dispatchers.Main`, so all
 *    ContentResolver work below hops to `Dispatchers.IO`;
 *  - errors are reported by throwing [FlutterError]; the Dart adapter
 *    (`PigeonAndroidStorageHost`) maps its `code` to an `AppFailure`.
 *
 * Byte I/O goes through [openStream]/[readChunk]/[writeChunk]/[closeStream].
 */
class SafStorageHostApi(
    private val context: Context,
    private val treePicker: TreePickerLauncher,
    private val documentPicker: DocumentPickerLauncher,
) : AndroidStorageApi {

    private val resolver: ContentResolver
        get() = context.contentResolver

    // --- Tree grants ---

    override suspend fun openDocumentTree(): SafTreeMessage? {
        // Runs on Main (where the generated handler dispatches us) — the picker
        // needs the Activity, and suspends until onActivityResult delivers.
        val treeUri = treePicker.launch() ?: return null

        return withContext(Dispatchers.IO) {
            guarded {
                // ONLY read/write bits are legal here. Passing
                // FLAG_GRANT_PERSISTABLE_URI_PERMISSION (as the first draft did)
                // makes takePersistableUriPermission throw IllegalArgumentException;
                // that flag belongs on the picker *intent*, not on this call.
                resolver.takePersistableUriPermission(
                    treeUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
                describeTree(treeUri)
            }
        }
    }

    override suspend fun persistedTrees(): List<SafTreeMessage> = withContext(Dispatchers.IO) {
        guarded {
            resolver.persistedUriPermissions
                .filter { it.isReadPermission && it.isWritePermission && DocumentsContract.isTreeUri(it.uri) }
                .map { describeTree(it.uri) }
        }
    }

    override suspend fun releasePersistedUri(treeUri: String) {
        withContext(Dispatchers.IO) {
            guarded {
                resolver.releasePersistableUriPermission(
                    Uri.parse(treeUri),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            }
        }
    }

    // --- Directory listing / metadata ---

    override suspend fun listChildren(treeUri: String, parentDocumentId: String): List<SafEntryMessage> =
        withContext(Dispatchers.IO) {
            guarded {
                val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(Uri.parse(treeUri), parentDocumentId)
                val results = mutableListOf<SafEntryMessage>()
                resolver.query(childrenUri, ENTRY_PROJECTION, null, null, null)?.use { cursor ->
                    while (cursor.moveToNext()) {
                        results.add(entryFrom(cursor))
                    }
                }
                results
            }
        }

    override suspend fun stat(treeUri: String, documentId: String): SafEntryMessage? =
        withContext(Dispatchers.IO) {
            guarded {
                val documentUri = DocumentsContract.buildDocumentUriUsingTree(Uri.parse(treeUri), documentId)
                resolver.query(documentUri, ENTRY_PROJECTION, null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) entryFrom(cursor) else null
                }
            }
        }

    // --- Mutations ---

    override suspend fun createDirectory(treeUri: String, parentDocumentId: String, name: String): String =
        withContext(Dispatchers.IO) {
            guarded {
                val parentUri = DocumentsContract.buildDocumentUriUsingTree(Uri.parse(treeUri), parentDocumentId)
                val created = DocumentsContract.createDocument(
                    resolver, parentUri, DocumentsContract.Document.MIME_TYPE_DIR, name,
                ) ?: throw IllegalStateException("Provider refused to create directory '$name'")
                DocumentsContract.getDocumentId(created)
            }
        }

    override suspend fun createFile(
        treeUri: String,
        parentDocumentId: String,
        name: String,
        mimeType: String,
    ): String = withContext(Dispatchers.IO) {
        guarded {
            val parentUri = DocumentsContract.buildDocumentUriUsingTree(Uri.parse(treeUri), parentDocumentId)
            val created = DocumentsContract.createDocument(resolver, parentUri, mimeType, name)
                ?: throw IllegalStateException("Provider refused to create file '$name'")
            DocumentsContract.getDocumentId(created)
        }
    }

    override suspend fun deleteDocument(treeUri: String, documentId: String) {
        withContext(Dispatchers.IO) {
            guarded {
                val documentUri = DocumentsContract.buildDocumentUriUsingTree(Uri.parse(treeUri), documentId)
                if (!DocumentsContract.deleteDocument(resolver, documentUri)) {
                    throw IllegalStateException("Provider refused to delete document")
                }
            }
        }
    }

    override suspend fun renameDocument(treeUri: String, documentId: String, newName: String): String =
        withContext(Dispatchers.IO) {
            guarded {
                val documentUri = DocumentsContract.buildDocumentUriUsingTree(Uri.parse(treeUri), documentId)
                // Some providers implement rename as delete+recreate under a new
                // id, or resolve a name clash themselves ("name (1)"). Report what
                // actually happened, not what was asked for.
                val renamed = DocumentsContract.renameDocument(resolver, documentUri, newName)
                    ?: throw IllegalStateException("Provider refused to rename document")
                queryDisplayName(renamed) ?: newName
            }
        }

    // --- Byte I/O ---
    //
    // Chunked through the channel instead of handing Dart a raw fd to reopen as
    // /proc/self/fd/N: that reopen resolves to the provider's lower-filesystem
    // path and fails with EACCES on Android 14 for SD-card trees.

    override suspend fun openStream(treeUri: String, documentId: String, mode: String, start: Long): Long =
        withContext(Dispatchers.IO) {
            guarded {
                val documentUri = DocumentsContract.buildDocumentUriUsingTree(Uri.parse(treeUri), documentId)
                val writing = mode == "w"
                // Plain "w" does NOT truncate on many SAF providers, which would
                // leave stale tail bytes after a shorter overwrite. "wt" does.
                val pfd = resolver.openFileDescriptor(documentUri, if (writing) "wt" else "r")
                    ?: throw IllegalStateException("Provider refused to open the document")
                val stream = try {
                    if (writing) {
                        OpenStream(pfd, input = null, output = FileOutputStream(pfd.fileDescriptor))
                    } else {
                        val input = FileInputStream(pfd.fileDescriptor)
                        if (start > 0) input.channel.position(start)
                        OpenStream(pfd, input = input, output = null)
                    }
                } catch (e: Exception) {
                    pfd.close()
                    throw e
                }
                val handle = nextHandle.incrementAndGet()
                streams[handle] = stream
                handle
            }
        }

    override suspend fun readChunk(handle: Long, maxBytes: Long): ByteArray =
        withContext(Dispatchers.IO) {
            guarded {
                val input = streams[handle]?.input ?: throw IllegalStateException("No open read stream $handle")
                val buffer = ByteArray(maxBytes.toInt().coerceIn(1, MAX_CHUNK))
                var filled = 0
                while (filled < buffer.size) {
                    val n = input.read(buffer, filled, buffer.size - filled)
                    if (n < 0) break
                    filled += n
                }
                if (filled == buffer.size) buffer else buffer.copyOf(filled)
            }
        }

    override suspend fun writeChunk(handle: Long, bytes: ByteArray) {
        withContext(Dispatchers.IO) {
            guarded {
                val output = streams[handle]?.output ?: throw IllegalStateException("No open write stream $handle")
                output.write(bytes)
            }
        }
    }

    override suspend fun closeStream(handle: Long) {
        withContext(Dispatchers.IO) {
            val stream = streams.remove(handle) ?: return@withContext
            guarded {
                try {
                    stream.output?.let {
                        it.flush()
                        // Pipe- or network-backed providers can't sync; the flush above already handed the bytes over.
                        try {
                            it.fd.sync()
                        } catch (ignored: java.io.SyncFailedException) {
                        }
                    }
                } finally {
                    stream.input?.close()
                    stream.output?.close()
                    stream.pfd.close()
                }
            }
        }
    }

    // --- Importing files from anywhere (system picker) ---

    override suspend fun pickFilesToCache(): List<PickedFileMessage> {
        // Runs on Main (where the generated handler dispatches us): the picker
        // needs the Activity and suspends until onActivityResult delivers.
        val uris = documentPicker.launch()
        if (uris.isEmpty()) return emptyList()

        return withContext(Dispatchers.IO) {
            guarded {
                val directory = File(context.cacheDir, "imports/${UUID.randomUUID()}")
                if (!directory.mkdirs()) {
                    throw IllegalStateException("Couldn't create the import cache directory")
                }
                // Cache files are named by INDEX, never by the provider-supplied
                // display name, so a hostile provider can't smuggle path segments.
                uris.mapIndexed { index, uri -> copyToCache(uri, File(directory, index.toString())) }
            }
        }
    }

    private fun copyToCache(uri: Uri, target: File): PickedFileMessage {
        var displayName: String? = null
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) displayName = cursor.getString(0)
        }
        val input = resolver.openInputStream(uri)
            ?: throw java.io.FileNotFoundException("Couldn't open the picked document")
        input.use { source ->
            target.outputStream().use { sink -> source.copyTo(sink, 64 * 1024) }
        }
        return PickedFileMessage(
            cachePath = target.absolutePath,
            name = displayName ?: uri.lastPathSegment ?: "file",
            sizeBytes = target.length(),
            mimeType = resolver.getType(uri),
        )
    }

    // --- All files access (lets "This phone" default into public Downloads) ---

    override suspend fun hasManageExternalStoragePermission(): Boolean = withContext(Dispatchers.IO) {
        guarded {
            Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()
        }
    }

    override suspend fun requestManageExternalStoragePermission() {
        withContext(Dispatchers.Main) {
            guarded {
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.fromParts("package", context.packageName, null)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
            }
        }
    }

    // --- helpers ---

    private fun describeTree(treeUri: Uri): SafTreeMessage {
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        return SafTreeMessage(
            treeUri = treeUri.toString(),
            displayName = queryDisplayName(treeUri) ?: rootId,
            rootDocumentId = rootId,
        )
    }

    private fun entryFrom(cursor: android.database.Cursor): SafEntryMessage {
        val mimeType = cursor.getString(cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE))
        val isDirectory = mimeType == DocumentsContract.Document.MIME_TYPE_DIR
        val sizeCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
        val modifiedCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        return SafEntryMessage(
            documentId = cursor.getString(cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)),
            name = cursor.getString(cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)),
            type = if (isDirectory) SafEntryTypeMessage.DIRECTORY else SafEntryTypeMessage.FILE,
            // A NULL size is "unknown", not zero (some providers can't say).
            sizeBytes = if (isDirectory || cursor.isNull(sizeCol)) null else cursor.getLong(sizeCol),
            lastModifiedMillis = if (cursor.isNull(modifiedCol)) null else cursor.getLong(modifiedCol),
            mimeType = if (isDirectory) null else mimeType,
        )
    }

    private fun queryDisplayName(uri: Uri): String? {
        val documentUri = if (DocumentsContract.isTreeUri(uri)) {
            DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
        } else {
            uri
        }
        return resolver.query(
            documentUri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null,
        )?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
    }

    /**
     * Maps platform exceptions onto stable [FlutterError] codes the Dart adapter
     * understands: `permission_revoked`, `not_found`, `io_error`.
     */
    private inline fun <T> guarded(block: () -> T): T = try {
        block()
    } catch (e: FlutterError) {
        throw e
    } catch (e: SecurityException) {
        throw FlutterError(code = "permission_revoked", message = e.message, details = null)
    } catch (e: java.io.FileNotFoundException) {
        throw FlutterError(code = "not_found", message = e.message, details = null)
    } catch (e: Exception) {
        throw FlutterError(code = "io_error", message = e.message, details = e.javaClass.simpleName)
    }

    private class OpenStream(
        val pfd: ParcelFileDescriptor,
        val input: FileInputStream?,
        val output: FileOutputStream?,
    )

    private val streams = ConcurrentHashMap<Long, OpenStream>()
    private val nextHandle = AtomicLong(0)

    private companion object {
        const val MAX_CHUNK = 4 * 1024 * 1024

        val ENTRY_PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
    }
}

/** Suspends until the user picks (or cancels) an `ACTION_OPEN_DOCUMENT_TREE` tree. */
interface TreePickerLauncher {
    suspend fun launch(): Uri?
}

/**
 * Bridges the picker Intent to a suspend call. `MainActivity` supplies the
 * Activity side ([bind] + [onResult]).
 *
 * Uses startActivityForResult rather than the ActivityResult API on purpose:
 * `FlutterActivity` extends plain `android.app.Activity`, NOT `ComponentActivity`,
 * so `registerForActivityResult` is not available on it (the first draft
 * assumed it was).
 */
class ActivityTreePickerLauncher : TreePickerLauncher {
    private var startPicker: ((Intent) -> Unit)? = null
    private var pending: ((Uri?) -> Unit)? = null

    /** Called from `MainActivity.configureFlutterEngine`. */
    fun bind(start: (Intent) -> Unit) {
        startPicker = start
    }

    /** Called from `MainActivity.onActivityResult` with the picked tree, or null if cancelled. */
    fun onResult(uri: Uri?) {
        val callback = pending
        pending = null
        callback?.invoke(uri)
    }

    override suspend fun launch(): Uri? = suspendCancellableCoroutine { continuation ->
        val start = startPicker
        if (start == null) {
            // Not bound: fail closed (report "cancelled") rather than hang forever.
            continuation.resume(null)
            return@suspendCancellableCoroutine
        }
        // A previous request that never got its result resolves as cancelled.
        pending?.invoke(null)
        pending = { uri -> if (continuation.isActive) continuation.resume(uri) }
        continuation.invokeOnCancellation { pending = null }

        start(
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                )
            },
        )
    }
}

/**
 * Pickers need an Activity. The server's background service has none, so in its
 * engine they answer "cancelled" — the service only READS existing grants.
 */
object NoTreePicker : TreePickerLauncher {
    override suspend fun launch(): Uri? = null
}

object NoDocumentPicker : DocumentPickerLauncher {
    override suspend fun launch(): List<Uri> = emptyList()
}

/** Suspends until the user picks (or cancels) documents with `ACTION_OPEN_DOCUMENT`. */
interface DocumentPickerLauncher {
    suspend fun launch(): List<Uri>
}

/** Same Activity hand-off as [ActivityTreePickerLauncher], for multi-select document picking. */
class ActivityDocumentPickerLauncher : DocumentPickerLauncher {
    private var startPicker: ((Intent) -> Unit)? = null
    private var pending: ((List<Uri>) -> Unit)? = null

    /** Called from `MainActivity.configureFlutterEngine`. */
    fun bind(start: (Intent) -> Unit) {
        startPicker = start
    }

    /** Called from `MainActivity.onActivityResult`; pass null when cancelled. */
    fun onResult(data: Intent?) {
        val callback = pending
        pending = null
        val uris = mutableListOf<Uri>()
        val clip = data?.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        } else {
            data?.data?.let { uris.add(it) }
        }
        callback?.invoke(uris)
    }

    override suspend fun launch(): List<Uri> = suspendCancellableCoroutine { continuation ->
        val start = startPicker
        if (start == null) {
            // Not bound: fail closed (report "cancelled") rather than hang forever.
            continuation.resume(emptyList())
            return@suspendCancellableCoroutine
        }
        pending?.invoke(emptyList())
        pending = { uris -> if (continuation.isActive) continuation.resume(uris) }
        continuation.invokeOnCancellation { pending = null }

        start(
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            },
        )
    }
}
