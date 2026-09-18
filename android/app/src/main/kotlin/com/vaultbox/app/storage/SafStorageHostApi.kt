package com.vaultbox.app.storage

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import com.vaultbox.app.pigeon.AndroidStorageApi
import com.vaultbox.app.pigeon.FlutterError
import com.vaultbox.app.pigeon.SafEntryMessage
import com.vaultbox.app.pigeon.SafEntryTypeMessage
import com.vaultbox.app.pigeon.SafTreeMessage
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
 * STATUS: compiles in CI. NOT exercised on a device — multi-provider interop,
 * very large files through [openFileDescriptor], and behaviour across Android
 * versions are all unverified (IMPLEMENTATION_PLAN R-19/R-20).
 */
class SafStorageHostApi(
    private val context: Context,
    private val treePicker: TreePickerLauncher,
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

    override suspend fun openFileDescriptor(treeUri: String, documentId: String, mode: String): Long =
        withContext(Dispatchers.IO) {
            guarded {
                val documentUri = DocumentsContract.buildDocumentUriUsingTree(Uri.parse(treeUri), documentId)
                // Plain "w" does NOT truncate on many SAF providers, which would
                // leave stale tail bytes after a shorter overwrite. "wt" does.
                val effectiveMode = if (mode == "w") "wt" else mode
                val pfd = resolver.openFileDescriptor(documentUri, effectiveMode)
                    ?: throw IllegalStateException("Provider refused to open a file descriptor")
                // detachFd() transfers ownership to the caller: Dart must close
                // whatever it opens from this fd.
                pfd.detachFd().toLong()
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

    private companion object {
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
