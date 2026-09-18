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

  /// Returns a raw file descriptor already `detachFd()`'d on the native
  /// side — ownership transfers to the Dart caller, which is responsible
  /// for closing whatever it opens from
  /// `File('/proc/self/fd/$fd')`. [mode] is `"r"`, `"w"`, or `"rw"`.
  Future<int> openFileDescriptor(String treeUri, String documentId, String mode);
}

final class SafTreeInfo {
  const SafTreeInfo({required this.treeUri, required this.displayName});

  final String treeUri;
  final String displayName;
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
