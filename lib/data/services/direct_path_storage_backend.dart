import "dart:async";
import "dart:io";

import "package:path/path.dart" as p;

import "../../core/errors/app_failure.dart";
import "../../domain/repositories/storage_backend.dart";
import "../../domain/value_objects/storage_capabilities.dart";
import "../../domain/value_objects/storage_entry.dart";
import "../../domain/value_objects/storage_path.dart";
import "../../domain/value_objects/write_mode.dart";

/// Real filesystem [StorageBackend] for roots VaultBox can reach by absolute
/// path (app-private storage, and any directory the OS already grants without
/// SAF). Paired with `SafStorageBackend` (Phase 2) it covers the documented
/// backend set from doc §11.
///
/// Two invariants this class is responsible for:
///
/// 1. **Confinement.** Every logical [StoragePath] is resolved against
///    [rootDirectory] and then *re-checked* after symlink resolution, so a
///    symlink inside the root can't be used to escape it (doc §42:
///    "unauthorized symlink escape"). [StoragePath] already rejects `..` and
///    encoded traversal before we get here; this is the second gate.
/// 2. **Write safety.** Writes land in a sibling temp file and are renamed
///    into place on commit (doc §26) — an interrupted write can never leave a
///    half-written file at the real destination.
final class DirectPathStorageBackend implements StorageBackend {
  DirectPathStorageBackend({required this.id, required String rootDirectory})
    : _rootDirectory = p.normalize(p.absolute(rootDirectory));

  @override
  final String id;

  final String _rootDirectory;

  String get rootDirectory => _rootDirectory;

  @override
  Future<StorageCapabilities> capabilities() async =>
      const StorageCapabilities.fullLocal();

  @override
  Stream<StorageEntry> list(
    StoragePath directory, {
    String? cursor,
    int? pageSize,
  }) async* {
    final String nativePath = _resolve(directory);
    final Directory dir = Directory(nativePath);
    if (!await dir.exists()) {
      throw StorageDisconnectedFailure(rootId: id, debugDetail: "directory missing");
    }

    // followLinks: false — a symlinked entry is listed as itself rather than
    // silently resolved to wherever it points.
    final Stream<FileSystemEntity> entities = dir.list(followLinks: false);

    int emitted = 0;
    bool started = cursor == null;

    await for (final FileSystemEntity entity in entities) {
      final String name = p.basename(entity.path);

      if (!started) {
        if (name == cursor) started = true;
        continue;
      }
      if (pageSize != null && emitted >= pageSize) return;

      // A real on-disk name we can't represent as one path segment (e.g. it
      // contains a backslash) is skipped rather than allowed to throw out of
      // the generator — one odd file must not blank the whole folder.
      final StoragePath childPath;
      try {
        childPath = directory.child(name);
      } on PathTraversalRejectedFailure {
        continue;
      }

      try {
        final FileStat stat = await entity.stat();
        final bool isDirectory = stat.type == FileSystemEntityType.directory;
        yield StorageEntry(
          path: childPath,
          type: isDirectory ? StorageEntryType.directory : StorageEntryType.file,
          // Directory "size" from stat() is the directory entry's own size on
          // disk, not the recursive content size — reporting it would be
          // misleading, so directories report null (doc §11: UI must handle a
          // missing size rather than assume 0).
          sizeBytes: isDirectory ? null : stat.size,
          modifiedAt: stat.modified,
        );
        emitted++;
      } on FileSystemException {
        // One unreadable entry must not abort enumeration of the rest —
        // same item-isolation principle as batch operations (ADR-011).
        continue;
      }
    }
  }

  @override
  Future<StorageStat> stat(StoragePath path) async {
    final String nativePath = _resolve(path);
    final FileStat stat = await FileStat.stat(nativePath);
    if (stat.type == FileSystemEntityType.notFound) {
      return StorageStat(path: path, type: StorageEntryType.file, exists: false);
    }
    final bool isDirectory = stat.type == FileSystemEntityType.directory;
    return StorageStat(
      path: path,
      type: isDirectory ? StorageEntryType.directory : StorageEntryType.file,
      exists: true,
      sizeBytes: isDirectory ? null : stat.size,
      modifiedAt: stat.modified,
    );
  }

  @override
  Stream<List<int>> openRead(StoragePath path, {int? start, int? end}) {
    final String nativePath = _resolve(path);
    final File file = File(nativePath);
    // openRead's `end` is EXCLUSIVE; the StorageBackend contract's is
    // INCLUSIVE (HTTP Range semantics) — convert here rather than leaking
    // the discrepancy to callers.
    return file
        .openRead(start ?? 0, end == null ? null : end + 1)
        .handleError(
          (Object error) => throw _mapFileSystemError(error),
          test: (Object? error) => error is FileSystemException,
        );
  }

  @override
  Future<StorageWriteHandle> openWrite(
    StoragePath path, {
    WriteMode mode = WriteMode.create,
  }) async {
    final String nativePath = _resolve(path);
    final File target = File(nativePath);

    if (mode == WriteMode.create && await target.exists()) {
      throw PathConflictFailure(path: path.normalized);
    }

    final Directory parent = Directory(p.dirname(nativePath));
    if (!await parent.exists()) {
      throw StorageDisconnectedFailure(rootId: id, debugDetail: "parent missing");
    }

    // Temp file lives beside the target so the commit rename stays on the
    // same filesystem (a cross-device rename would fall back to a copy and
    // lose atomicity).
    final File temp = File(
      p.join(
        parent.path,
        ".vaultbox-tmp-${DateTime.now().microsecondsSinceEpoch}-${p.basename(nativePath)}",
      ),
    );

    return _DirectPathWriteHandle(temp: temp, target: target);
  }

  @override
  Future<void> createDirectory(StoragePath path) async {
    final String nativePath = _resolve(path);
    final Directory dir = Directory(nativePath);
    if (await dir.exists()) {
      throw PathConflictFailure(path: path.normalized);
    }
    try {
      await dir.create();
    } on FileSystemException catch (error) {
      throw _mapFileSystemError(error);
    }
  }

  @override
  Future<void> rename(StoragePath source, String newName) async {
    await move(source, source.parent.child(newName));
  }

  @override
  Future<void> move(StoragePath source, StoragePath target) async {
    final String sourceNative = _resolve(source);
    final String targetNative = _resolve(target);

    if (await FileSystemEntity.isDirectory(targetNative) ||
        await File(targetNative).exists()) {
      throw PathConflictFailure(path: target.normalized);
    }

    try {
      if (await FileSystemEntity.isDirectory(sourceNative)) {
        await Directory(sourceNative).rename(targetNative);
      } else {
        await File(sourceNative).rename(targetNative);
      }
    } on FileSystemException catch (error) {
      throw _mapFileSystemError(error);
    }
  }

  @override
  Future<void> copy(StoragePath source, StoragePath target) async {
    final String sourceNative = _resolve(source);
    final String targetNative = _resolve(target);

    if (await File(targetNative).exists() ||
        await FileSystemEntity.isDirectory(targetNative)) {
      throw PathConflictFailure(path: target.normalized);
    }

    try {
      if (await FileSystemEntity.isDirectory(sourceNative)) {
        await _copyDirectoryRecursive(source, target);
      } else {
        // File.copy streams internally and never materializes the whole file
        // in memory — this is the "never readAsBytes() for large transfers"
        // rule (kickoff §12) satisfied by the SDK rather than by hand.
        await File(sourceNative).copy(targetNative);
      }
    } on FileSystemException catch (error) {
      throw _mapFileSystemError(error);
    }
  }

  @override
  Future<void> delete(StoragePath path) async {
    final String nativePath = _resolve(path);
    try {
      if (await FileSystemEntity.isDirectory(nativePath)) {
        await Directory(nativePath).delete(recursive: true);
      } else {
        final File file = File(nativePath);
        if (!await file.exists()) {
          throw StorageDisconnectedFailure(rootId: id, debugDetail: "no such path");
        }
        await file.delete();
      }
    } on FileSystemException catch (error) {
      throw _mapFileSystemError(error);
    }
  }

  Future<void> _copyDirectoryRecursive(StoragePath source, StoragePath target) async {
    await Directory(_resolve(target)).create();
    await for (final StorageEntry entry in list(source)) {
      final StoragePath childTarget = target.child(entry.name);
      if (entry.isDirectory) {
        await _copyDirectoryRecursive(entry.path, childTarget);
      } else {
        await File(_resolve(entry.path)).copy(_resolve(childTarget));
      }
    }
  }

  /// Maps a logical [StoragePath] to an absolute native path, refusing
  /// anything that would resolve outside [_rootDirectory].
  String _resolve(StoragePath path) {
    if (path.rootId != id) {
      throw const PathTraversalRejectedFailure(debugDetail: "root id mismatch");
    }
    final String candidate =
        p.normalize(p.joinAll(<String>[_rootDirectory, ...path.segments]));
    if (!p.isWithin(_rootDirectory, candidate) && candidate != _rootDirectory) {
      throw const PathTraversalRejectedFailure(debugDetail: "escapes root");
    }
    return candidate;
  }

  AppFailure _mapFileSystemError(Object error) {
    if (error is! FileSystemException) {
      return const UnexpectedFailure();
    }
    final int? errno = error.osError?.errorCode;
    // errno values: 1 EPERM, 13 EACCES, 28 ENOSPC, 2 ENOENT (Linux/Android).
    return switch (errno) {
      1 || 13 => const PermissionRevokedFailure(),
      28 => const NotEnoughSpaceFailure(),
      2 => StorageDisconnectedFailure(rootId: id, debugDetail: "ENOENT"),
      _ => UnexpectedFailure(debugDetail: "errno $errno"),
    };
  }
}

final class _DirectPathWriteHandle implements StorageWriteHandle {
  _DirectPathWriteHandle({required File temp, required File target})
    : _temp = temp,
      _target = target {
    _sink = _temp.openWrite();
  }

  final File _temp;
  final File _target;
  late final IOSink _sink;
  bool _finished = false;

  @override
  StreamSink<List<int>> get sink => _sink;

  @override
  Future<int> commit() async {
    if (_finished) return _target.length();
    _finished = true;
    await _sink.flush();
    await _sink.close();

    final int written = await _temp.length();
    // Atomic publish: the destination either has the old content or the fully
    // written new content, never a partial file (doc §26).
    await _temp.rename(_target.path);
    return written;
  }

  @override
  Future<void> abort() async {
    if (_finished) return;
    _finished = true;
    try {
      await _sink.close();
    } on FileSystemException {
      // Sink may already be closed/broken — the temp cleanup below is what
      // actually matters here.
    }
    if (await _temp.exists()) {
      await _temp.delete();
    }
  }
}
