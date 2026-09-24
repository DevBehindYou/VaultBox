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

  void seedFile({
    required List<String> parentPath,
    required String name,
    int sizeBytes = 0,
  }) {
    final String parentId = _idFor(parentPath);
    final String id = "file-${_idCounter++}";
    _nodes[id] = _FakeNode.file(name: name, sizeBytes: sizeBytes);
    _nodes[parentId]!.childIds.add(id);
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
    _nodes[id] = _FakeNode.file(name: name, sizeBytes: 0);
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
  Future<int> openFileDescriptor(String treeUri, String documentId, String mode) {
    throw UnsupportedError(
      "FakeAndroidStorageHost cannot fabricate a real OS file descriptor — "
      "see this test file's top-of-file scope note.",
    );
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
  _FakeNode.directory({required this.name}) : isDirectory = true, sizeBytes = null;

  _FakeNode.file({required this.name, required int this.sizeBytes}) : isDirectory = false;

  String name;
  final bool isDirectory;
  final int? sizeBytes;
  final List<String> childIds = <String>[];
}
