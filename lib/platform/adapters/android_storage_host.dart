import "dart:typed_data";

/// Hand-authored contract [SafStorageBackend] depends on, deliberately
/// decoupled from Pigeon's generated types (see `pigeons/storage_api.dart`)
/// so this interface — and everything built on it, including
/// [SafStorageBackend] itself — compiles and is unit-testable via a fake
/// today, without waiting on Pigeon codegen to run.
///
/// `PigeonAndroidStorageHost` (in `pigeon_android_storage_host.dart`) is the
/// thin adapter that implements this by calling the real generated
/// `AndroidStorageApi`; nothing above this interface needs to know that
/// adapter exists. This mirrors how `StorageBackend` itself decouples the
/// domain from any one storage implementation (ADR-004) — same pattern, one
/// layer further down.
abstract interface class AndroidStorageHost {
  /// Launches the SAF tree picker. Returns null if the user cancelled.
  Future<SafTreeInfo?> openDocumentTree();

  Future<List<SafTreeInfo>> persistedTrees();

  Future<void> releasePersistedUri(String treeUri);

  Future<List<SafEntryInfo>> listChildren(String treeUri, String parentDocumentId);

  Future<SafEntryInfo?> stat(String treeUri, String documentId);

  Future<String> createDirectory(String treeUri, String parentDocumentId, String name);

  Future<String> createFile(
    String treeUri,
    String parentDocumentId,
    String name,
    String mimeType,
  );

  Future<void> deleteDocument(String treeUri, String documentId);

  Future<String> renameDocument(String treeUri, String documentId, String newName);

  /// Opens a document for chunked streaming; returns a handle. [mode] is `"r"`
  /// (reading from byte [start]) or `"w"` (truncate, then write). The caller
  /// must [closeStream] the handle, also on error or cancellation.
  Future<int> openStream(String treeUri, String documentId, {required String mode, int start = 0});

  /// Up to [maxBytes] bytes; empty means end of file.
  Future<Uint8List> readChunk(int handle, int maxBytes);

  Future<void> writeChunk(int handle, Uint8List bytes);

  /// Flushes and releases [handle]. Safe on an already-closed handle.
  Future<void> closeStream(int handle);

  /// System file picker (multi-select). The native side copies each picked
  /// document into the app's cache and returns the copies; the caller OWNS them
  /// and must delete every [PickedFile.cachePath] when done. Empty = cancelled.
  Future<List<PickedFile>> pickFilesToCache();

  /// Whether the app currently holds "All files access". Always true below
  /// Android 11 (API 30), where MANAGE_EXTERNAL_STORAGE doesn't exist.
  Future<bool> hasManageExternalStoragePermission();

  /// Opens the system "All files access" settings screen for this app.
  /// Fire-and-forget — re-check [hasManageExternalStoragePermission] when the
  /// app resumes rather than waiting for a result here.
  Future<void> requestManageExternalStoragePermission();
}

/// A document the user picked, already copied to a plain file in the app cache.
final class PickedFile {
  const PickedFile({required this.cachePath, required this.name, this.sizeBytes, this.mimeType});

  final String cachePath;

  /// The document's real display name (what the imported file should be called).
  final String name;
  final int? sizeBytes;
  final String? mimeType;
}

final class SafTreeInfo {
  const SafTreeInfo({
    required this.treeUri,
    required this.displayName,
    required this.rootDocumentId,
  });

  final String treeUri;
  final String displayName;

  /// The tree's top-level document id — where [SafStorageBackend] starts
  /// walking path segments.
  final String rootDocumentId;
}

enum SafEntryKind { file, directory }

final class SafEntryInfo {
  const SafEntryInfo({
    required this.documentId,
    required this.name,
    required this.kind,
    this.sizeBytes,
    this.lastModifiedMillis,
    this.mimeType,
  });

  final String documentId;
  final String name;
  final SafEntryKind kind;
  final int? sizeBytes;
  final int? lastModifiedMillis;
  final String? mimeType;
}
