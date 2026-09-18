import "dart:async";
import "dart:typed_data";

import "../../core/errors/app_failure.dart";
import "../../domain/repositories/storage_backend.dart";
import "../../domain/value_objects/storage_capabilities.dart";
import "../../domain/value_objects/storage_entry.dart";
import "../../domain/value_objects/storage_path.dart";
import "../../domain/value_objects/write_mode.dart";

/// In-memory [StorageBackend] — the required replaceable fake from doc §59
/// ("Test-first architecture"), and the backend the Files UI runs against in
/// widget tests so UI work never depends on device storage state.
///
/// Deliberately implements the *full* contract rather than throwing
/// `UnimplementedError` on the awkward parts: if the fake diverges from real
/// backend semantics, storage contract tests (doc §60) stop being meaningful.
final class MemoryStorageBackend implements StorageBackend {
  MemoryStorageBackend({required this.id});

  @override
  final String id;

  /// Flat map of normalized path -> node. A flat map (rather than a tree)
  /// keeps lookups O(1) and makes prefix operations (recursive delete, listing)
  /// simple string-prefix scans, which is adequate at test scale.
  final Map<String, _MemoryNode> _nodes = <String, _MemoryNode>{
    "/": _MemoryNode.directory(),
  };

  @override
  Future<StorageCapabilities> capabilities() async =>
      const StorageCapabilities.fullLocal();

  @override
  Stream<StorageEntry> list(
    StoragePath directory, {
    String? cursor,
    int? pageSize,
  }) async* {
    final String prefix = _prefixOf(directory);
    final _MemoryNode? node = _nodes[directory.normalized];
    if (node == null) {
      throw StorageDisconnectedFailure(rootId: id, debugDetail: "no such directory");
    }
    if (!node.isDirectory) {
      throw const UnexpectedFailure(debugDetail: "list() called on a file");
    }

    final List<String> childPaths = _nodes.keys
        .where((String p) => _isDirectChild(p, prefix))
        .toList()
      ..sort();

    int emitted = 0;
    bool started = cursor == null;
    for (final String childPath in childPaths) {
      final String childName = childPath.substring(prefix.length);
      if (!started) {
        // Cursor is the last-emitted entry NAME (not its full path) — this is
        // the contract every backend shares, so a ViewModel can page without
        // knowing which backend it's talking to.
        if (childName == cursor) started = true;
        continue;
      }
      if (pageSize != null && emitted >= pageSize) return;

      final _MemoryNode child = _nodes[childPath]!;
      yield StorageEntry(
        path: StoragePath.parse(id, childPath),
        type: child.isDirectory ? StorageEntryType.directory : StorageEntryType.file,
        sizeBytes: child.isDirectory ? null : child.bytes!.length,
        modifiedAt: child.modifiedAt,
        mimeType: child.mimeType,
      );
      emitted++;
    }
  }

  @override
  Future<StorageStat> stat(StoragePath path) async {
    final _MemoryNode? node = _nodes[path.normalized];
    if (node == null) {
      return StorageStat(
        path: path,
        type: StorageEntryType.file,
        exists: false,
      );
    }
    return StorageStat(
      path: path,
      type: node.isDirectory ? StorageEntryType.directory : StorageEntryType.file,
      exists: true,
      sizeBytes: node.isDirectory ? null : node.bytes!.length,
      modifiedAt: node.modifiedAt,
      mimeType: node.mimeType,
    );
  }

  @override
  Stream<List<int>> openRead(StoragePath path, {int? start, int? end}) async* {
    final _MemoryNode? node = _nodes[path.normalized];
    if (node == null || node.isDirectory) {
      throw StorageDisconnectedFailure(rootId: id, debugDetail: "no such file");
    }
    final Uint8List bytes = node.bytes!;
    final int from = start ?? 0;
    // `end` is INCLUSIVE in the StorageBackend contract (HTTP Range
    // semantics, doc §10) — sublist's second argument is exclusive, hence +1.
    final int toExclusive = end == null ? bytes.length : (end + 1).clamp(0, bytes.length);
    if (from >= toExclusive) return;

    // Chunked so callers exercise real streaming code paths rather than
    // accidentally relying on one-shot delivery.
    const int chunkSize = 64 * 1024;
    for (int offset = from; offset < toExclusive; offset += chunkSize) {
      final int chunkEnd = (offset + chunkSize).clamp(0, toExclusive);
      yield bytes.sublist(offset, chunkEnd);
    }
  }

  @override
  Future<StorageWriteHandle> openWrite(
    StoragePath path, {
    WriteMode mode = WriteMode.create,
  }) async {
    final bool exists = _nodes.containsKey(path.normalized);
    if (exists && mode == WriteMode.create) {
      throw PathConflictFailure(path: path.normalized);
    }
    final String parent = path.parent.normalized;
    if (!_nodes.containsKey(parent)) {
      throw StorageDisconnectedFailure(rootId: id, debugDetail: "parent missing");
    }
    return _MemoryWriteHandle(
      onCommit: (Uint8List bytes) {
        _nodes[path.normalized] = _MemoryNode.file(bytes);
      },
    );
  }

  @override
  Future<void> createDirectory(StoragePath path) async {
    if (_nodes.containsKey(path.normalized)) {
      throw PathConflictFailure(path: path.normalized);
    }
    if (!_nodes.containsKey(path.parent.normalized)) {
      throw StorageDisconnectedFailure(rootId: id, debugDetail: "parent missing");
    }
    _nodes[path.normalized] = _MemoryNode.directory();
  }

  @override
  Future<void> rename(StoragePath source, String newName) async {
    final StoragePath target = source.parent.child(newName);
    await move(source, target);
  }

  @override
  Future<void> move(StoragePath source, StoragePath target) async {
    await copy(source, target);
    await delete(source);
  }

  @override
  Future<void> copy(StoragePath source, StoragePath target) async {
    final _MemoryNode? node = _nodes[source.normalized];
    if (node == null) {
      throw StorageDisconnectedFailure(rootId: id, debugDetail: "no such source");
    }
    if (_nodes.containsKey(target.normalized)) {
      throw PathConflictFailure(path: target.normalized);
    }

    if (node.isDirectory) {
      // Recursive directory copy — rewrite each descendant's path prefix.
      final String sourcePrefix = _prefixOf(source);
      final String targetPrefix = _prefixOf(target);
      _nodes[target.normalized] = _MemoryNode.directory();
      final List<String> descendants =
          _nodes.keys.where((String p) => p.startsWith(sourcePrefix)).toList();
      for (final String descendant in descendants) {
        final String suffix = descendant.substring(sourcePrefix.length);
        _nodes["$targetPrefix$suffix"] = _nodes[descendant]!.clone();
      }
    } else {
      _nodes[target.normalized] = node.clone();
    }
  }

  @override
  Future<void> delete(StoragePath path) async {
    final _MemoryNode? node = _nodes[path.normalized];
    if (node == null) {
      throw StorageDisconnectedFailure(rootId: id, debugDetail: "no such path");
    }
    if (node.isDirectory) {
      final String prefix = _prefixOf(path);
      _nodes.removeWhere((String p, _) => p == path.normalized || p.startsWith(prefix));
    } else {
      _nodes.remove(path.normalized);
    }
  }

  // --- Test helpers (not part of the StorageBackend contract) ---

  /// Seeds a file directly, creating parent directories as needed. Test-only
  /// convenience so arranging a fixture doesn't require driving the whole
  /// write-handle dance.
  void seedFile(String path, List<int> bytes, {DateTime? modifiedAt}) {
    final StoragePath parsed = StoragePath.parse(id, path);
    _seedParents(parsed);
    _nodes[parsed.normalized] =
        _MemoryNode.file(Uint8List.fromList(bytes), modifiedAt: modifiedAt);
  }

  void seedDirectory(String path) {
    final StoragePath parsed = StoragePath.parse(id, path);
    _seedParents(parsed);
    _nodes[parsed.normalized] = _MemoryNode.directory();
  }

  void _seedParents(StoragePath path) {
    StoragePath current = StoragePath.root(id);
    for (final String segment in path.segments.take(path.segments.length - 1)) {
      current = current.child(segment);
      _nodes.putIfAbsent(current.normalized, _MemoryNode.directory);
    }
  }

  /// Normalized path with a guaranteed trailing slash, for prefix matching.
  /// Root normalizes to "/", so it must not become "//".
  String _prefixOf(StoragePath path) =>
      path.isRoot ? "/" : "${path.normalized}/";

  bool _isDirectChild(String candidate, String parentPrefix) {
    if (!candidate.startsWith(parentPrefix)) return false;
    final String remainder = candidate.substring(parentPrefix.length);
    return remainder.isNotEmpty && !remainder.contains("/");
  }
}

final class _MemoryNode {
  _MemoryNode.directory()
    : isDirectory = true,
      bytes = null,
      mimeType = null,
      modifiedAt = DateTime.fromMillisecondsSinceEpoch(0);

  _MemoryNode.file(this.bytes, {DateTime? modifiedAt, this.mimeType})
    : isDirectory = false,
      modifiedAt = modifiedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  final bool isDirectory;
  final Uint8List? bytes;
  final String? mimeType;
  final DateTime modifiedAt;

  _MemoryNode clone() {
    if (isDirectory) return _MemoryNode.directory();
    return _MemoryNode.file(
      Uint8List.fromList(bytes!),
      modifiedAt: modifiedAt,
      mimeType: mimeType,
    );
  }
}

final class _MemoryWriteHandle implements StorageWriteHandle {
  _MemoryWriteHandle({required void Function(Uint8List) onCommit})
    : _onCommit = onCommit;

  final void Function(Uint8List) _onCommit;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  late final StreamController<List<int>> _controller =
      StreamController<List<int>>()..stream.listen(_buffer.add);

  bool _finished = false;

  @override
  StreamSink<List<int>> get sink => _controller.sink;

  @override
  Future<int> commit() async {
    if (_finished) return _buffer.length;
    _finished = true;
    await _controller.close();
    final Uint8List bytes = _buffer.takeBytes();
    // Commit is the "temp -> verified -> visible" step: nothing is written
    // into the node map until here, mirroring the real backends' behaviour.
    _onCommit(bytes);
    return bytes.length;
  }

  @override
  Future<void> abort() async {
    if (_finished) return;
    _finished = true;
    await _controller.close();
    _buffer.clear();
  }
}
