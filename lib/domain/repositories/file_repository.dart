import "../models/file_ref.dart";
import "../value_objects/storage_entry.dart";
import "../value_objects/storage_path.dart";
import "../value_objects/write_mode.dart";
import "storage_backend.dart";

/// Root-aware file primitives. This is the layer that resolves a
/// [FileRef.root] to its [StorageBackend] (via whatever backend factory the
/// data layer wires up) and exposes single-item operations.
///
/// Deliberately thin: batch orchestration (item isolation, conflict
/// resolution, cross-backend copy-then-delete, Recycle Bin bookkeeping) lives
/// one layer up in the use cases (`CopyItems`, `MoveItems`,
/// `DeleteItemsToRecycleBin`) per doc §03 dependency direction
/// (ViewModel → UseCase → Repository → Service). Simple screens that don't
/// need batch semantics (e.g. "list this folder") can call this repository
/// directly from a ViewModel, per doc §18 ("Simple settings CRUD can call
/// repositories directly" — the same relaxation applies to simple reads).
abstract interface class FileRepository {
  Stream<StorageEntry> list(FileRef directory, {String? cursor, int? pageSize});

  Future<StorageEntry?> statEntry(FileRef ref);

  Future<void> createDirectory(FileRef directory, String name);

  /// Opens a read stream for [ref] — used by preview and by protocol
  /// handlers' download path once the server exists (Phase 3+).
  Stream<List<int>> openRead(FileRef ref, {int? start, int? end});

  Future<StorageWriteHandle> openWrite(FileRef ref, {WriteMode mode = WriteMode.create});

  /// Single-item rename, same parent. Throws [PathConflictFailure] if
  /// [newName] already exists and no conflict policy was pre-resolved by the
  /// caller.
  Future<void> renameSingle(FileRef source, String newName);

  /// Single-item copy. May cross roots/backends — implementation streams
  /// through [openRead]/[openWrite] when source and target backends differ,
  /// or delegates to the backend's native `copy` when they're the same
  /// backend and it reports `canCopyWithinBackend`.
  Future<void> copySingle(FileRef source, FileRef target, {WriteMode mode = WriteMode.create});

  /// Single-item **permanent** delete at the backend level — no Recycle Bin
  /// involvement. Recycle Bin semantics live in the `DeleteItemsToRecycleBin`
  /// use case, which calls this only for the final purge step.
  Future<void> deletePermanently(FileRef ref);

  /// Resolves a name that doesn't collide with anything already in
  /// [directory] — used to implement "Keep Both" (doc §11: `filename (1).ext`).
  Future<String> resolveNonConflictingName(FileRef directory, String desiredName);
}
