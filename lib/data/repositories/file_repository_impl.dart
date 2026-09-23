import "dart:async";

import "package:path/path.dart" as p;

import "../../core/errors/app_failure.dart";
import "../../domain/entities/storage_root.dart";
import "../../domain/models/file_ref.dart";
import "../../domain/repositories/file_repository.dart";
import "../../domain/repositories/storage_backend.dart";
import "../../domain/value_objects/storage_entry.dart";
import "../../domain/value_objects/write_mode.dart";

/// Resolves a [StorageRoot] to the live [StorageBackend] serving it. Kept as
/// a typedef rather than a class so tests can pass a closure and production
/// can pass a registry lookup.
typedef BackendResolver = StorageBackend Function(StorageRoot root);

/// Default [FileRepository] implementation.
///
/// Its one piece of real logic is [copySingle]: when source and target live
/// in the *same* backend it delegates to that backend's native copy (fast,
/// and lets the OS do the work); when they live in *different* backends
/// (SD card → internal, or later internal → Vault) it streams bytes through
/// [StorageBackend.openRead] into a [StorageWriteHandle], never buffering the
/// whole file (kickoff §12). Either way the write-handle contract guarantees
/// commit/abort safety.
final class FileRepositoryImpl implements FileRepository {
  const FileRepositoryImpl({required BackendResolver resolveBackend})
    : _resolveBackend = resolveBackend;

  final BackendResolver _resolveBackend;

  @override
  Stream<StorageEntry> list(FileRef directory, {String? cursor, int? pageSize}) {
    return _resolveBackend(directory.root)
        .list(directory.path, cursor: cursor, pageSize: pageSize);
  }

  @override
  Future<StorageEntry?> statEntry(FileRef ref) async {
    final StorageStat stat = await _resolveBackend(ref.root).stat(ref.path);
    if (!stat.exists) return null;
    return StorageEntry(
      path: stat.path,
      type: stat.type,
      sizeBytes: stat.sizeBytes,
      modifiedAt: stat.modifiedAt,
      mimeType: stat.mimeType,
    );
  }

  @override
  Future<void> createDirectory(FileRef directory, String name) {
    return _resolveBackend(directory.root).createDirectory(directory.path.child(name));
  }

  @override
  Stream<List<int>> openRead(FileRef ref, {int? start, int? end}) {
    return _resolveBackend(ref.root).openRead(ref.path, start: start, end: end);
  }

  @override
  Future<StorageWriteHandle> openWrite(FileRef ref, {WriteMode mode = WriteMode.create}) {
    return _resolveBackend(ref.root).openWrite(ref.path, mode: mode);
  }

  @override
  Future<void> renameSingle(FileRef source, String newName) {
    return _resolveBackend(source.root).rename(source.path, newName);
  }

  @override
  Future<void> copySingle(
    FileRef source,
    FileRef target, {
    WriteMode mode = WriteMode.create,
  }) async {
    final StorageBackend sourceBackend = _resolveBackend(source.root);
    final StorageBackend targetBackend = _resolveBackend(target.root);

    if (identical(sourceBackend, targetBackend) || sourceBackend.id == targetBackend.id) {
      // Both guards run BEFORE anything is touched. Without them, "Replace"
      // deletes the target first — and if the target is the source (copy or
      // move into the same folder) or contains it, that delete destroys the
      // only copy and the copy that follows then fails. A folder copied into
      // itself would also recurse without end.
      if (target.path.isDescendantOfOrEqualTo(source.path)) {
        throw const InvalidOperationFailure(
          message: "An item can't be copied into itself.",
          debugDetail: "target is inside or equal to source",
        );
      }
      if (mode == WriteMode.replace && source.path.isDescendantOfOrEqualTo(target.path)) {
        throw const InvalidOperationFailure(
          message: "An item can't replace a folder that contains it.",
          debugDetail: "source is inside target",
        );
      }
      if (mode == WriteMode.replace) {
        // Backend copy() refuses an occupied target by contract, so an
        // explicit replace means removing the old entry first. This is the
        // one place the "delete before write" ordering is acceptable: the
        // user explicitly chose Replace, and the source is untouched
        // throughout, so no data is destroyed without a surviving copy.
        final StorageStat existing = await targetBackend.stat(target.path);
        if (existing.exists) {
          await targetBackend.delete(target.path);
        }
      }
      await sourceBackend.copy(source.path, target.path);
      return;
    }

    // Cross-backend: stream through, no full-file buffering.
    final StorageStat sourceStat = await sourceBackend.stat(source.path);
    if (!sourceStat.exists) {
      throw StorageDisconnectedFailure(
        rootId: source.root.id,
        debugDetail: "source missing",
      );
    }
    if (sourceStat.type == StorageEntryType.directory) {
      await _copyDirectoryAcrossBackends(source, target, mode: mode);
      return;
    }

    final StorageWriteHandle handle = await targetBackend.openWrite(target.path, mode: mode);
    try {
      await handle.sink.addStream(sourceBackend.openRead(source.path));
      final int written = await handle.commit();

      // Verify before the caller is allowed to treat this as done — the
      // "verify" step of temp → verify → commit (doc §26). A size mismatch
      // means the copy is not trustworthy, so it's removed rather than left
      // behind looking valid.
      if (sourceStat.sizeBytes != null && written != sourceStat.sizeBytes) {
        await targetBackend.delete(target.path);
        throw const UnexpectedFailure(debugDetail: "copy size mismatch");
      }
    } catch (_) {
      await handle.abort();
      rethrow;
    }
  }

  Future<void> _copyDirectoryAcrossBackends(
    FileRef source,
    FileRef target, {
    required WriteMode mode,
  }) async {
    final StorageBackend sourceBackend = _resolveBackend(source.root);
    final StorageBackend targetBackend = _resolveBackend(target.root);

    final StorageStat targetStat = await targetBackend.stat(target.path);
    if (!targetStat.exists) {
      await targetBackend.createDirectory(target.path);
    }

    await for (final StorageEntry entry in sourceBackend.list(source.path)) {
      final FileRef childSource = FileRef(root: source.root, path: entry.path);
      final FileRef childTarget = FileRef(
        root: target.root,
        path: target.path.child(entry.name),
      );
      await copySingle(childSource, childTarget, mode: mode);
    }
  }

  @override
  Future<void> deletePermanently(FileRef ref) {
    return _resolveBackend(ref.root).delete(ref.path);
  }

  @override
  Future<String> resolveNonConflictingName(FileRef directory, String desiredName) async {
    final StorageBackend backend = _resolveBackend(directory.root);

    final StorageStat direct = await backend.stat(directory.path.child(desiredName));
    if (!direct.exists) return desiredName;

    final String extension = p.extension(desiredName);
    final String stem = p.basenameWithoutExtension(desiredName);

    // Bounded rather than unbounded: an attacker-supplied or pathological
    // directory shouldn't spin here forever. 1000 is far past any realistic
    // "Keep Both" case.
    for (int counter = 1; counter <= 1000; counter++) {
      final String candidate = "$stem ($counter)$extension";
      final StorageStat stat = await backend.stat(directory.path.child(candidate));
      if (!stat.exists) return candidate;
    }
    throw PathConflictFailure(path: directory.path.child(desiredName).normalized);
  }
}
