import "dart:async";
import "dart:io";

import "../../core/errors/app_failure.dart";
import "../../domain/repositories/storage_backend.dart";
import "../../domain/value_objects/storage_capabilities.dart";
import "../../domain/value_objects/storage_entry.dart";
import "../../domain/value_objects/storage_path.dart";
import "../../domain/value_objects/write_mode.dart";
import "../../platform/adapters/android_storage_host.dart";

/// SAF-backed [StorageBackend] — the real implementation this time, not the
/// stub described in earlier build sessions (see
/// docs/IMPLEMENTATION_PLAN.md's former R-11, now resolved by this file).
/// Depends only on [AndroidStorageHost], so it's fully unit-testable with a
/// fake host today; the real [AndroidStorageHost] implementation
/// (`PigeonAndroidStorageHost`) needs Pigeon codegen and a native Kotlin
/// implementation to exist, neither of which this sandbox can run — see
/// `README.md`.
///
/// **The one structural constraint every method here works around:** SAF
/// addresses content by opaque per-provider `documentId`, not by path.
/// There is no "open `/Documents/Photos/img.jpg`" — only "list the children
/// of this documentId, find the one named `img.jpg`, use *its* documentId."
/// [_resolveDocumentId] is that walk, done fresh on every call. This is
/// correct but not fast: a deeply nested path costs one native round trip
/// per segment. A documentId cache keyed by [StoragePath] would fix that
/// without changing this class's public contract — a reasonable follow-up,
/// not a blocker (kickoff §74 treats this kind of thing as an ongoing
/// question, not a Phase-2 gate).
final class SafStorageBackend implements StorageBackend {
  SafStorageBackend({
    required this.id,
    required AndroidStorageHost host,
    required String treeUri,
    required String rootDocumentId,
  }) : _host = host,
       _treeUri = treeUri,
       _rootDocumentId = rootDocumentId;

  @override
  final String id;

  final AndroidStorageHost _host;
  final String _treeUri;
  final String _rootDocumentId;

  @override
  Future<StorageCapabilities> capabilities() async {
    // Honest, not aspirational: SAF has no OS-level atomic rename-over-
    // existing through this API (a "replace" write truncates in place — see
    // the safety note on `openWrite` below), and no native move/copy this
    // class relies on (composed instead from read+write streaming, further
    // down). Claiming `fullLocal()` parity here would be the exact kind of
    // silently-wrong capability report the interface's own doc comment
    // warns against.
    return const StorageCapabilities(
      canRead: true,
      canWrite: true,
      canCreateDirectory: true,
      canDelete: true,
      canRename: true,
      canMoveWithinBackend: false,
      canCopyWithinBackend: false,
      supportsRandomAccess: false,
      supportsAtomicReplace: false,
      supportsFreeSpaceQuery: false,
      supportsWatch: false,
    );
  }

  @override
  Stream<StorageEntry> list(
    StoragePath directory, {
    String? cursor,
    int? pageSize,
  }) async* {
    final String parentId = await _resolveDocumentId(directory);
    final List<SafEntryInfo> children = await _host.listChildren(_treeUri, parentId);

    // SAF's query doesn't offer a native paging cursor — everything comes
    // back in one call from the provider. Sorted here so the
    // cursor-resumes-by-name contract every other backend honours (see
    // StorageBackend.list's doc comment) still holds for this one too.
    final List<SafEntryInfo> sorted = List<SafEntryInfo>.of(
      children,
    )..sort((SafEntryInfo a, SafEntryInfo b) => a.name.compareTo(b.name));

    bool started = cursor == null;
    int emitted = 0;
    for (final SafEntryInfo entry in sorted) {
      if (!started) {
        if (entry.name == cursor) started = true;
        continue;
      }
      if (pageSize != null && emitted >= pageSize) return;

      // Skip names that can't be one path segment instead of aborting the
      // whole listing (same policy as DirectPathStorageBackend.list).
      final StoragePath childPath;
      try {
        childPath = directory.child(entry.name);
      } on PathTraversalRejectedFailure {
        continue;
      }

      yield StorageEntry(
        path: childPath,
        type: entry.kind == SafEntryKind.directory
            ? StorageEntryType.directory
            : StorageEntryType.file,
        sizeBytes: entry.sizeBytes,
        modifiedAt: _fromMillis(entry.lastModifiedMillis),
        mimeType: entry.mimeType,
      );
      emitted++;
    }
  }

  @override
  Future<StorageStat> stat(StoragePath path) async {
    final String? documentId = await _tryResolveDocumentId(path);
    if (documentId == null) {
      return StorageStat(path: path, type: StorageEntryType.file, exists: false);
    }
    final SafEntryInfo? info = await _host.stat(_treeUri, documentId);
    if (info == null) {
      return StorageStat(path: path, type: StorageEntryType.file, exists: false);
    }
    return StorageStat(
      path: path,
      type: info.kind == SafEntryKind.directory
          ? StorageEntryType.directory
          : StorageEntryType.file,
      exists: true,
      sizeBytes: info.sizeBytes,
      modifiedAt: _fromMillis(info.lastModifiedMillis),
      mimeType: info.mimeType,
    );
  }

  @override
  Stream<List<int>> openRead(StoragePath path, {int? start, int? end}) async* {
    final String documentId = await _resolveDocumentId(path);
    final int fd = await _host.openFileDescriptor(_treeUri, documentId, "r");
    // /proc/self/fd is what makes this a real stream instead of a chunked
    // platform-channel relay — see the doc comment on
    // AndroidStorageApi.openFileDescriptor in pigeons/storage_api.dart for
    // why this needs on-device verification before it's trusted for large
    // files.
    final File fdFile = File("/proc/self/fd/$fd");
    yield* fdFile.openRead(start, end == null ? null : end + 1);
  }

  @override
  Future<StorageWriteHandle> openWrite(
    StoragePath path, {
    WriteMode mode = WriteMode.create,
  }) async {
    final String parentId = await _resolveDocumentId(path.parent);
    final String? existingId = await _findChildId(parentId, path.name);

    if (existingId != null && mode == WriteMode.create) {
      throw PathConflictFailure(path: path.normalized);
    }

    final bool isFreshCreate = existingId == null;
    final String documentId =
        existingId ??
        await _host.createFile(
          _treeUri,
          parentId,
          path.name,
          "application/octet-stream",
        );

    // SAFETY NOTE, not swept under the rug: opening an *existing* document
    // in write mode truncates it immediately on most SAF providers — there
    // is no SAF-native temp-file-then-atomic-rename the way
    // DirectPathStorageBackend gets for free from the real filesystem. A
    // replace-mode write that fails partway through can leave the old
    // content gone and the new content incomplete. `capabilities()` reports
    // `supportsAtomicReplace: false` specifically so `FileRepositoryImpl`
    // and the use-case layer know not to assume otherwise; the honest fix
    // (write to a sibling temp document, then delete-old + rename-new) is a
    // real option SAF supports but adds a second native round trip to every
    // write, so it's deferred here rather than half-implemented — tracked
    // in docs/IMPLEMENTATION_PLAN.md.
    final int fd = await _host.openFileDescriptor(_treeUri, documentId, "w");
    final File fdFile = File("/proc/self/fd/$fd");

    return _SafWriteHandle(
      sink: fdFile.openWrite(),
      onAbort: isFreshCreate
          ? () => _host.deleteDocument(_treeUri, documentId)
          : () async {}, // can't un-truncate an in-place overwrite — see note above
    );
  }

  @override
  Future<void> createDirectory(StoragePath path) async {
    final String parentId = await _resolveDocumentId(path.parent);
    final String? existing = await _findChildId(parentId, path.name);
    if (existing != null) {
      throw PathConflictFailure(path: path.normalized);
    }
    await _host.createDirectory(_treeUri, parentId, path.name);
  }

  @override
  Future<void> rename(StoragePath source, String newName) async {
    final String documentId = await _resolveDocumentId(source);
    await _host.renameDocument(_treeUri, documentId, newName);
  }

  @override
  Future<void> move(StoragePath source, StoragePath target) async {
    // No native SAF move relied on here (provider support for
    // DocumentsContract.moveDocument is inconsistent — see this class's doc
    // comment) — composed the same safe way FileRepositoryImpl composes a
    // cross-backend move: copy, verify, then delete the source.
    await copy(source, target);
    await delete(source);
  }

  @override
  Future<void> copy(StoragePath source, StoragePath target) async {
    final StorageStat sourceStat = await stat(source);
    if (!sourceStat.exists) {
      throw StorageDisconnectedFailure(rootId: id, debugDetail: "no such source");
    }
    final StorageStat targetStat = await stat(target);
    if (targetStat.exists) {
      throw PathConflictFailure(path: target.normalized);
    }

    if (sourceStat.type == StorageEntryType.directory) {
      await createDirectory(target);
      await for (final StorageEntry entry in list(source)) {
        await copy(entry.path, target.child(entry.name));
      }
      return;
    }

    final StorageWriteHandle handle = await openWrite(target);
    try {
      await handle.sink.addStream(openRead(source));
      final int written = await handle.commit();
      if (sourceStat.sizeBytes != null && written != sourceStat.sizeBytes) {
        await delete(target);
        throw const UnexpectedFailure(debugDetail: "SAF copy size mismatch");
      }
    } catch (_) {
      await handle.abort();
      rethrow;
    }
  }

  @override
  Future<void> delete(StoragePath path) async {
    final String documentId = await _resolveDocumentId(path);
    await _host.deleteDocument(_treeUri, documentId);
  }

  // --- Path <-> documentId resolution ---

  Future<String> _resolveDocumentId(StoragePath path) async {
    final String? id = await _tryResolveDocumentId(path);
    if (id == null) {
      throw StorageDisconnectedFailure(rootId: this.id, debugDetail: "no such path");
    }
    return id;
  }

  Future<String?> _tryResolveDocumentId(StoragePath path) async {
    if (path.isRoot) return _rootDocumentId;

    String currentId = _rootDocumentId;
    for (final String segment in path.segments) {
      final String? childId = await _findChildId(currentId, segment);
      if (childId == null) return null;
      currentId = childId;
    }
    return currentId;
  }

  Future<String?> _findChildId(String parentDocumentId, String name) async {
    final List<SafEntryInfo> children = await _host.listChildren(_treeUri, parentDocumentId);
    for (final SafEntryInfo child in children) {
      if (child.name == name) return child.documentId;
    }
    return null;
  }

  static DateTime? _fromMillis(int? millis) {
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }
}

final class _SafWriteHandle implements StorageWriteHandle {
  _SafWriteHandle({required IOSink sink, required Future<void> Function() onAbort})
    : _sink = sink,
      _onAbort = onAbort;

  final IOSink _sink;
  final Future<void> Function() _onAbort;
  bool _finished = false;
  int _written = 0;
  // ignore: close_sinks — closed via _sink in commit()/abort(); this only wraps it.
  _CountingSink? _countingSink;

  @override
  StreamSink<List<int>> get sink =>
      _countingSink ??= _CountingSink(_sink, (int n) => _written += n);

  @override
  Future<int> commit() async {
    if (_finished) return _written;
    _finished = true;
    await _sink.flush();
    await _sink.close();
    return _written;
  }

  @override
  Future<void> abort() async {
    if (_finished) return;
    _finished = true;
    try {
      await _sink.close();
    } on FileSystemException {
      // Best-effort — the fd may already be in a bad state, which is exactly
      // why we're aborting.
    }
    await _onAbort();
  }
}

/// Wraps an [IOSink] to track bytes written without needing
/// [_SafWriteHandle] to double-buffer — `commit()` needs a byte count to
/// verify against, and the underlying `File.openWrite()` sink doesn't expose
/// one itself.
final class _CountingSink implements StreamSink<List<int>> {
  _CountingSink(this._inner, this._onBytes);

  final IOSink _inner;
  final void Function(int) _onBytes;

  @override
  void add(List<int> event) {
    _onBytes(event.length);
    _inner.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    return _inner.addStream(
      stream.map((List<int> chunk) {
        _onBytes(chunk.length);
        return chunk;
      }),
    );
  }

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;
}
