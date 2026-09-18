// Gradle dependency this file needs and `flutter create .` will NOT add on
// its own: `kotlinx-coroutines-android` (for `suspendCancellableCoroutine`).
// Add to android/app/build.gradle's dependencies block if it isn't already
// present transitively — check before assuming a missing-symbol error here
// means something else is wrong.
package com.vaultbox.app.storage

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

// These three types come from the Pigeon-generated file
// (android/app/src/main/kotlin/com/vaultbox/app/pigeon/StorageApi.g.kt) —
// does not exist until `dart run pigeon` has been run (see README.md). This
// import will fail to resolve until then; that's expected, not a bug in
// this file.
import com.vaultbox.app.pigeon.SafEntryMessage
import com.vaultbox.app.pigeon.SafEntryTypeMessage
import com.vaultbox.app.pigeon.SafTreeMessage

// Implements the generated `AndroidStorageApi` HostApi interface from
// `pigeons/storage_api.dart` (see android/app/src/main/kotlin/com/vaultbox/app/pigeon/StorageApi.g.kt
// once `dart run pigeon` has been run — that file does not exist yet in this
// delivery, see README.md).
//
// IMPORTANT — reconcile before wiring up: this class is written against this
// project's own best understanding of what Pigeon should generate for the
// spec in `pigeons/storage_api.dart` (method names, nullability, and
// whether HostApi methods come out as ordinary functions or `suspend fun`
// for the ones with a `Future<T>` Dart return type). The Pigeon spec file
// itself flags this as unverified. Once codegen has actually run, diff this
// file's method signatures against the real generated interface and adjust
// — the *bodies* below (the actual SAF calls) don't depend on that; only
// the `override fun` signatures might need small adjustments.
//
// Every operation here is a direct, standard Storage Access Framework call
// — DocumentFile / DocumentsContract / ContentResolver, all from
// developer.android.com's own SAF documentation, nothing invented. What
// HASN'T been exercised on a real device from this delivery: multi-provider
// interop (different manufacturers' SAF providers vary in what they
// support), very large files through `openFileDescriptor`, and behaviour
// across the specific Android versions VaultBox targets (minSdk 29). Treat
// this class as a strong first draft, not a validated implementation — see
// docs/IMPLEMENTATION_PLAN.md's risk register.
// This class deliberately does NOT declare `: AndroidStorageApi` yet — see
// the reconciliation note above. Two steps remain once codegen has run and
// the signatures are confirmed:
//   1. Add `: AndroidStorageApi` to the class declaration below (Kotlin will
//      point out any signature mismatches immediately).
//   2. Register it from `MainActivity.configureFlutterEngine`:
//        AndroidStorageApi.setUp(
//            flutterEngine.dartExecutor.binaryMessenger,
//            SafStorageHostApi(applicationContext, treePickerLauncher),
//        )
//      (exact call shape per whatever Pigeon actually generates for
//      HostApi registration — this is the other half of the "don't assume"
//      note at the top of this file.)
class SafStorageHostApi(
    private val context: Context,
    private val treePicker: TreePickerLauncher,
) {
    private val resolver: ContentResolver
        get() = context.contentResolver

    // --- Tree grants ---

    suspend fun openDocumentTree(): SafTreeMessage? {
        val treeUri = treePicker.launch() ?: return null

        val takeFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
        // Persisting the grant is what makes it survive process death and
        // device reboot — without this call the picker result is only good
        // for the current process lifetime, which would silently break
        // every storage root the next time the app launches.
        resolver.takePersistableUriPermission(treeUri, takeFlags)

        val displayName = queryDisplayName(treeUri) ?: treeUri.lastPathSegment ?: "Storage"
        return SafTreeMessage(treeUri = treeUri.toString(), displayName = displayName)
    }

    fun persistedTrees(): List<SafTreeMessage> {
        return resolver.persistedUriPermissions
            .filter { it.isReadPermission && it.isWritePermission }
            .map { permission ->
                val name = queryDisplayName(permission.uri) ?: permission.uri.lastPathSegment ?: "Storage"
                SafTreeMessage(treeUri = permission.uri.toString(), displayName = name)
            }
    }

    fun releasePersistedUri(treeUri: String) {
        val uri = Uri.parse(treeUri)
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        resolver.releasePersistableUriPermission(uri, flags)
    }

    // --- Directory listing / metadata ---

    fun listChildren(treeUri: String, parentDocumentId: String): List<SafEntryMessage> {
        val tree = Uri.parse(treeUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentDocumentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )

        val results = mutableListOf<SafEntryMessage>()
        resolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
            val modifiedCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED)

            while (cursor.moveToNext()) {
                val mimeType = cursor.getString(mimeCol)
                val isDirectory = mimeType == DocumentsContract.Document.MIME_TYPE_DIR
                results.add(
                    SafEntryMessage(
                        documentId = cursor.getString(idCol),
                        name = cursor.getString(nameCol),
                        type = if (isDirectory) SafEntryTypeMessage.DIRECTORY else SafEntryTypeMessage.FILE,
                        sizeBytes = if (isDirectory) null else cursor.getLong(sizeCol),
                        lastModifiedMillis = if (cursor.isNull(modifiedCol)) null else cursor.getLong(modifiedCol),
                        mimeType = if (isDirectory) null else mimeType,
                    ),
                )
            }
        }
        return results
    }

    fun stat(treeUri: String, documentId: String): SafEntryMessage? {
        val tree = Uri.parse(treeUri)
        val documentUri = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )

        resolver.query(documentUri, projection, null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) return null
            val mimeType = cursor.getString(cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE))
            val isDirectory = mimeType == DocumentsContract.Document.MIME_TYPE_DIR
            val sizeCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
            val modifiedCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            return SafEntryMessage(
                documentId = cursor.getString(cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)),
                name = cursor.getString(cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)),
                type = if (isDirectory) SafEntryTypeMessage.DIRECTORY else SafEntryTypeMessage.FILE,
                sizeBytes = if (isDirectory) null else cursor.getLong(sizeCol),
                lastModifiedMillis = if (cursor.isNull(modifiedCol)) null else cursor.getLong(modifiedCol),
                mimeType = if (isDirectory) null else mimeType,
            )
        }
        return null
    }

    // --- Mutations ---

    fun createDirectory(treeUri: String, parentDocumentId: String, name: String): String {
        val tree = Uri.parse(treeUri)
        val parentUri = DocumentsContract.buildDocumentUriUsingTree(tree, parentDocumentId)
        val newUri = DocumentsContract.createDocument(
            resolver,
            parentUri,
            DocumentsContract.Document.MIME_TYPE_DIR,
            name,
        ) ?: throw IllegalStateException("Provider refused to create directory '$name'")
        return DocumentsContract.getDocumentId(newUri)
    }

    fun createFile(treeUri: String, parentDocumentId: String, name: String, mimeType: String): String {
        val tree = Uri.parse(treeUri)
        val parentUri = DocumentsContract.buildDocumentUriUsingTree(tree, parentDocumentId)
        val newUri = DocumentsContract.createDocument(resolver, parentUri, mimeType, name)
            ?: throw IllegalStateException("Provider refused to create file '$name'")
        return DocumentsContract.getDocumentId(newUri)
    }

    fun deleteDocument(treeUri: String, documentId: String) {
        val tree = Uri.parse(treeUri)
        val documentUri = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
        val deleted = DocumentsContract.deleteDocument(resolver, documentUri)
        if (!deleted) throw IllegalStateException("Provider refused to delete document")
    }

    fun renameDocument(treeUri: String, documentId: String, newName: String): String {
        val tree = Uri.parse(treeUri)
        val documentUri = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
        // The returned URI's documentId (and sometimes its display name, if
        // the provider resolved a naming conflict on its own) can differ
        // from what was requested — some providers implement rename as
        // delete+recreate under a new id. Query the actual result rather
        // than echoing back the input, so a caller that checks the returned
        // name for a "(1)"-style suffix sees the truth.
        val renamedUri = DocumentsContract.renameDocument(resolver, documentUri, newName)
            ?: throw IllegalStateException("Provider refused to rename document")
        return queryDisplayName(renamedUri) ?: newName
    }

    // --- Byte I/O ---

    fun openFileDescriptor(treeUri: String, documentId: String, mode: String): Long {
        val tree = Uri.parse(treeUri)
        val documentUri = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
        val pfd = resolver.openFileDescriptor(documentUri, mode)
            ?: throw IllegalStateException("Provider refused to open a file descriptor")
        // detachFd() transfers ownership to the caller — this is exactly
        // what lets the raw fd cross the platform-channel boundary safely.
        // The Dart side (SafStorageBackend) is now responsible for closing
        // whatever it opens from this fd; see that class's doc comment.
        return pfd.detachFd().toLong()
    }

    private fun queryDisplayName(uri: Uri): String? {
        val documentUri = if (DocumentsContract.isTreeUri(uri)) {
            DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
        } else {
            uri
        }
        resolver.query(
            documentUri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                return cursor.getString(0)
            }
        }
        return null
    }
}

/// Bridges the SAF tree-picker Intent (`ACTION_OPEN_DOCUMENT_TREE`) to a
/// suspend call. Real implementation lives on `MainActivity` — an
/// `ActivityResultLauncher<Uri?>` registered via
/// `registerForActivityResult(ActivityResultContracts.OpenDocumentTree())`
/// in `onCreate`, wired to resume whatever continuation is pending here.
/// Kept as an interface so `SafStorageHostApi` doesn't need an `Activity`
/// reference directly (a plain `Context` — e.g. the application context — is
/// enough for every other method on this class).
interface TreePickerLauncher {
    suspend fun launch(): Uri?
}

/// Reference implementation of [TreePickerLauncher] for `MainActivity` to
/// instantiate and hand to [SafStorageHostApi]. `MainActivity` must call
/// [onResult] from the `ActivityResultCallback` it registers — this class
/// only holds the coroutine handoff, not the registration itself, since
/// `registerForActivityResult` must be called unconditionally during
/// Activity initialization (a well-known Android platform constraint, not a
/// design choice made here).
class ActivityResultTreePickerLauncher : TreePickerLauncher {
    private var pendingContinuation: ((Uri?) -> Unit)? = null
    private var launchAction: (() -> Unit)? = null

    /** Called once from `MainActivity.onCreate` after registering the launcher. */
    fun bind(launch: () -> Unit) {
        launchAction = launch
    }

    /** Called from the `ActivityResultCallback` `MainActivity` registered. */
    fun onResult(uri: Uri?) {
        pendingContinuation?.invoke(uri)
        pendingContinuation = null
    }

    override suspend fun launch(): Uri? = suspendCancellableCoroutine { continuation ->
        pendingContinuation = { uri -> continuation.resume(uri) }
        launchAction?.invoke()
            ?: continuation.resume(null) // launcher never bound — fail closed, not silently hang
    }
}
