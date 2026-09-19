import "../../core/errors/app_failure.dart";
import "../../domain/entities/account.dart";
import "../../domain/entities/storage_root.dart";
import "../../domain/repositories/storage_root_repository.dart";
import "../../domain/security/authorizer.dart";
import "../../domain/value_objects/storage_path.dart";

/// Why a storage request was refused, independent of the protocol that asked.
/// The web API and WebDAV each map these to their own status codes.
enum FaultKind {
  /// No such (enabled) storage root.
  rootNotFound,

  /// The root exists but can't be reached right now (unplugged SD card…).
  unavailable,

  /// The root is read-only and the request would change it.
  readOnly,

  /// The path is malformed or tries to escape its root.
  invalidPath,

  /// Nothing at that path (or it is VaultBox's hidden bookkeeping folder).
  notFound,

  /// The caller may not do that to that path.
  forbidden,

  /// A file was needed, a folder was found.
  notAFile,

  /// A folder was needed, a file was found.
  notADirectory,

  /// The parent folder doesn't exist.
  parentMissing,

  /// A copy/move destination folder doesn't exist.
  destinationMissing,

  /// Something already exists at the target (and overwriting wasn't asked for).
  exists,

  /// A folder is in the way of a file.
  isADirectory,

  /// The client's connection broke mid-upload; nothing was kept.
  interrupted,

  /// A byte range outside the file.
  rangeNotSatisfiable,
}

final class StorageFault implements Exception {
  const StorageFault(this.kind, {this.size});

  final FaultKind kind;

  /// For [FaultKind.rangeNotSatisfiable]: the file's real size.
  final int? size;

  @override
  String toString() => "StorageFault($kind)";
}

/// The single doorway from a remote request to storage. Every protocol front
/// end (web API, WebDAV, and later shares) resolves roots, validates paths and
/// asks permission HERE, so a rule can't be enforced on one surface and missed
/// on another:
///  - client paths only ever enter through [StoragePath.parse];
///  - VaultBox's own `.vaultbox` folder (Recycle Bin) does not exist to clients;
///  - a read-only root refuses every mutation;
///  - the [Authorizer] is asked per path, per action.
final class StorageGate {
  StorageGate({required StorageRootRepository roots, required Authorizer authorizer})
    : _roots = roots,
      _authorizer = authorizer;

  final StorageRootRepository _roots;
  final Authorizer _authorizer;

  /// VaultBox's bookkeeping folder. Compared lower-cased: some Android storage
  /// is case-insensitive.
  static const String reservedDirName = ".vaultbox";

  /// Whether [path] is (inside) the hidden bookkeeping folder.
  static bool isReserved(StoragePath path) =>
      path.segments.isNotEmpty && path.segments.first.toLowerCase() == reservedDirName;

  /// Whether a single top-level [name] would collide with it.
  static bool isReservedName(String name) => name.toLowerCase() == reservedDirName;

  /// Roots a client may see (enabled ones), whether or not they are reachable.
  Future<List<StorageRoot>> visibleRoots() async {
    final List<StorageRoot> roots = await _roots.listRoots();
    return <StorageRoot>[
      for (final StorageRoot root in roots)
        if (root.isEnabled) root,
    ];
  }

  Future<StorageRoot> root(String rootId, {bool forWrite = false}) async {
    final StorageRoot? root = await _roots.getRoot(rootId);
    if (root == null || !root.isEnabled) throw const StorageFault(FaultKind.rootNotFound);
    if (!root.isAvailable) throw const StorageFault(FaultKind.unavailable);
    if (forWrite && !root.capabilities.canWrite) throw const StorageFault(FaultKind.readOnly);
    return root;
  }

  /// Parses a client path that the HTTP layer already percent-decoded once (see
  /// [StoragePath.parseDecoded]). Malformed or escaping -> [FaultKind.invalidPath];
  /// the hidden folder -> [FaultKind.notFound].
  StoragePath parse(StorageRoot root, String? raw, {bool allowRoot = true}) {
    final StoragePath path;
    try {
      path = StoragePath.parseDecoded(root.id, raw ?? "/");
    } on AppFailure {
      throw const StorageFault(FaultKind.invalidPath);
    }
    if (isReserved(path)) throw const StorageFault(FaultKind.notFound);
    if (!allowRoot && path.isRoot) throw const StorageFault(FaultKind.invalidPath);
    return path;
  }

  void require(Account account, Permission permission, StorageRoot root, StoragePath path) {
    if (!_authorizer.allows(account, permission, root, path)) {
      throw const StorageFault(FaultKind.forbidden);
    }
  }
}
