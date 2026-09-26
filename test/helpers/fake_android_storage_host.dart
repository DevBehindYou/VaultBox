import "dart:typed_data";

import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/platform/adapters/android_storage_host.dart";

/// In-memory double for [AndroidStorageHost]. DocumentIds are simply the
/// joined path here for readability — real SAF documentIds are opaque
/// provider-assigned strings with no relationship to the path at all, which
/// [SafStorageBackend] never assumes (it only ever compares them for
/// equality, never parses one) — the fake being "too readable" doesn't leak
/// into what the class under test can rely on.
final class FakeAndroidStorageHost implements AndroidStorageHost {
  /// What the next `openDocumentTree()` returns (null = user cancelled).
  SafTreeInfo? nextTree;

  /// What the next `pickFilesToCache()` returns (empty = cancelled).
  List<PickedFile> nextPicked = <PickedFile>[];

  /// When set, `pickFilesToCache` throws it.
  AppFailure? failPick;

  /// Tree URIs passed to `releasePersistedUri`.
  final List<String> released = <String>[];

  /// What `hasManageExternalStoragePermission()` returns.
  bool manageExternalStorageGranted = true;

  /// Incremented each time `requestManageExternalStoragePermission()` is called.
  int manageExternalStorageRequestCount = 0;

  /// When set, `createDirectory` throws it (simulates a revoked/refused grant).
  AppFailure? failCreateDirectory;

  final Map<String, _FakeNode> _nodes = <String, _FakeNode>{
    "root": _FakeNode.directory(name: ""),
  };
  int _idCounter = 0;

  /// When set, `writeChunk` throws it once this many bytes have been written
  /// to a stream (simulates a card pulled mid-write).
  AppFailure? failWriteAfter;
  int failWriteAfterBytes = 0;

  final Map<int, _FakeStream> _streams = <int, _FakeStream>{};
  int _handleCounter = 0;

  /// Streams opened and not yet closed — must be 0 after every operation.
  int get openStreamCount => _streams.length;

  void seedFile({
    required List<String> parentPath,
    required String name,
    int sizeBytes = 0,
    List<int>? content,
  }) {
    final String parentId = _idFor(parentPath);
    final String id = "file-${_idCounter++}";
    _nodes[id] = _FakeNode.file(name: name, bytes: content ?? List<int>.filled(sizeBytes, 0));
    _nodes[parentId]!.childIds.add(id);
  }

  /// The stored bytes of the file at [path], or null if there is none.
  Uint8List? contentOf(List<String> path) {
    try {
      final _FakeNode node = _nodes[_idFor(path)]!;
      return node.isDirectory ? null : Uint8List.fromList(node.bytes);
    } on StateError {
      return null;
    }
  }

  String _idFor(List<String> segments) {
    String current = "root";
    for (final String segment in segments) {
      current = _nodes[current]!.childIds.firstWhere(
        (String id) => _nodes[id]!.name == segment,
      );
    }
    return current;
  }

  @override
  Future<List<SafEntryInfo>> listChildren(String treeUri, String parentDocumentId) async {
    final _FakeNode? parent = _nodes[parentDocumentId];
    if (parent == null) {
      throw ArgumentError("unknown parent $parentDocumentId");
    }
    return parent.childIds.map((String id) {
      final _FakeNode node = _nodes[id]!;
      return SafEntryInfo(
        documentId: id,
        name: node.name,
        kind: node.isDirectory ? SafEntryKind.directory : SafEntryKind.file,
        sizeBytes: node.isDirectory ? null : node.sizeBytes,
      );
    }).toList();
  }

  @override
  Future<SafEntryInfo?> stat(String treeUri, String documentId) async {
    final _FakeNode? node = _nodes[documentId];
    if (node == null) return null;
    return SafEntryInfo(
      documentId: documentId,
      name: node.name,
      kind: node.isDirectory ? SafEntryKind.directory : SafEntryKind.file,
      sizeBytes: node.isDirectory ? null : node.sizeBytes,
    );
  }

  @override
  Future<String> createDirectory(String treeUri, String parentDocumentId, String name) async {
    final AppFailure? failure = failCreateDirectory;
    if (failure != null) throw failure;
    final String id = "dir-${_idCounter++}";
    _nodes[id] = _FakeNode.directory(name: name);
    _nodes[parentDocumentId]!.childIds.add(id);
    return id;
  }

  @override
  Future<String> createFile(
    String treeUri,
    String parentDocumentId,
    String name,
    String mimeType,
  ) async {
    final String id = "file-${_idCounter++}";
    _nodes[id] = _FakeNode.file(name: name, bytes: <int>[]);
    _nodes[parentDocumentId]!.childIds.add(id);
    return id;
  }

  @override
  Future<void> deleteDocument(String treeUri, String documentId) async {
    _nodes.remove(documentId);
    for (final _FakeNode node in _nodes.values) {
      node.childIds.remove(documentId);
    }
  }

  @override
  Future<String> renameDocument(String treeUri, String documentId, String newName) async {
    _nodes[documentId]!.name = newName;
    return newName;
  }

  @override
  Future<int> openStream(String treeUri, String documentId, {required String mode, int start = 0}) async {
    final _FakeNode? node = _nodes[documentId];
    if (node == null || node.isDirectory) {
      throw const UnexpectedFailure(debugDetail: "not_found: no such document");
    }
    final bool writing = mode == "w";
    if (writing) node.bytes = <int>[];
    final int handle = ++_handleCounter;
    _streams[handle] = _FakeStream(node, writing: writing, position: writing ? 0 : start);
    return handle;
  }

  @override
  Future<Uint8List> readChunk(int handle, int maxBytes) async {
    final _FakeStream stream = _streams[handle]!;
    final List<int> bytes = stream.node.bytes;
    final int from = stream.position.clamp(0, bytes.length);
    final int to = (from + maxBytes).clamp(0, bytes.length);
    stream.position = to;
    return Uint8List.fromList(bytes.sublist(from, to));
  }

  @override
  Future<void> writeChunk(int handle, Uint8List bytes) async {
    final _FakeStream stream = _streams[handle]!;
    final AppFailure? failure = failWriteAfter;
    if (failure != null && stream.node.bytes.length + bytes.length > failWriteAfterBytes) throw failure;
    stream.node.bytes.addAll(bytes);
  }

  @override
  Future<void> closeStream(int handle) async {
    _streams.remove(handle);
  }

  @override
  Future<List<PickedFile>> pickFilesToCache() async {
    final AppFailure? failure = failPick;
    if (failure != null) throw failure;
    return nextPicked;
  }

  @override
  Future<SafTreeInfo?> openDocumentTree() async => nextTree;

  @override
  Future<List<SafTreeInfo>> persistedTrees() async => const <SafTreeInfo>[];

  @override
  Future<void> releasePersistedUri(String treeUri) async {
    released.add(treeUri);
  }

  @override
  Future<bool> hasManageExternalStoragePermission() async => manageExternalStorageGranted;

  @override
  Future<void> requestManageExternalStoragePermission() async {
    manageExternalStorageRequestCount++;
  }
}

final class _FakeNode {
  _FakeNode.directory({required this.name}) : isDirectory = true, bytes = <int>[];

  _FakeNode.file({required this.name, required List<int> bytes}) : isDirectory = false, bytes = List<int>.of(bytes);

  String name;
  final bool isDirectory;
  List<int> bytes;
  final List<String> childIds = <String>[];

  int? get sizeBytes => isDirectory ? null : bytes.length;
}

final class _FakeStream {
  _FakeStream(this.node, {required this.writing, required this.position});

  final _FakeNode node;
  final bool writing;
  int position;
}
