/// What a given [StorageBackend] can actually do. UI and server protocol
/// handlers adapt to this rather than assuming every backend behaves like a
/// normal filesystem — verbatim capability list from
/// `11_Storage_File_Manager_and_Transfer_Engine.md`.
final class StorageCapabilities {
  const StorageCapabilities({
    required this.canRead,
    required this.canWrite,
    required this.canCreateDirectory,
    required this.canDelete,
    required this.canRename,
    required this.canMoveWithinBackend,
    required this.canCopyWithinBackend,
    required this.supportsRandomAccess,
    required this.supportsAtomicReplace,
    required this.supportsFreeSpaceQuery,
    required this.supportsWatch,
  });

  /// Read-only backend with none of the mutating capabilities — useful for
  /// public/share-only surfaces and as a safe default.
  const StorageCapabilities.readOnly()
    : canRead = true,
      canWrite = false,
      canCreateDirectory = false,
      canDelete = false,
      canRename = false,
      canMoveWithinBackend = false,
      canCopyWithinBackend = false,
      supportsRandomAccess = false,
      supportsAtomicReplace = false,
      supportsFreeSpaceQuery = false,
      supportsWatch = false;

  /// Full read/write local filesystem-style backend (e.g. direct-path,
  /// in-memory test backend).
  const StorageCapabilities.fullLocal()
    : canRead = true,
      canWrite = true,
      canCreateDirectory = true,
      canDelete = true,
      canRename = true,
      canMoveWithinBackend = true,
      canCopyWithinBackend = true,
      supportsRandomAccess = true,
      supportsAtomicReplace = true,
      supportsFreeSpaceQuery = true,
      supportsWatch = false;

  final bool canRead;
  final bool canWrite;
  final bool canCreateDirectory;
  final bool canDelete;
  final bool canRename;
  final bool canMoveWithinBackend;
  final bool canCopyWithinBackend;

  /// Range/seek support — relevant for media playback seeking and resumed
  /// downloads (doc §10 "Range requests").
  final bool supportsRandomAccess;

  /// Backend can replace a file's content atomically (rename-over-existing
  /// semantics) rather than needing an app-level temp→verify→commit dance.
  /// Direct-path filesystems typically do; some SAF providers do not.
  final bool supportsAtomicReplace;
  final bool supportsFreeSpaceQuery;
  final bool supportsWatch;
}
