import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/data/services/saf_storage_backend.dart";
import "package:vaultbox/domain/value_objects/storage_entry.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/platform/adapters/android_storage_host.dart";

/// **Scope note, read before extending this file.** [SafStorageBackend]'s
/// `openRead`/`openWrite`/`copy` depend on `File('/proc/self/fd/$fd')` — a
/// real Android/Linux kernel feature backed by an actual open file
/// descriptor on the native side (see the class's own doc comment and
/// `pigeons/storage_api.dart`). `dart:io` has no portable way to fabricate a
/// raw OS file descriptor from pure Dart, so [FakeAndroidStorageHost] below
/// cannot faithfully back those three methods — faking them would mean
/// testing a fake's behaviour, not the class's. Untested here on purpose,
/// not by oversight; validating the byte-I/O path is on-device/integration
/// work (docs/IMPLEMENTATION_PLAN.md risk register).
///
/// Everything this file DOES cover — path→documentId resolution,
/// list/stat/createDirectory/rename/delete, and the metadata half of `copy`
/// (directory recursion, conflict detection) — has no such dependency and is
/// fully exercised here.
void main() {
  late FakeAndroidStorageHost host;
  late SafStorageBackend backend;

  setUp(() {
    host = FakeAndroidStorageHost();
    backend = SafStorageBackend(
      id: "saf-1",
      host: host,
      treeUri: "content://com.android.externalstorage.documents/tree/primary",
      rootDocumentId: "root",
    );
  });

  StoragePath at(String path) => StoragePath.parse("saf-1", path);

  test("stat reports non-existence for an unknown path without throwing", () async {
    final StorageStat stat = await backend.stat(at("nope.txt"));
    expect(stat.exists, isFalse);
  });

  test("createDirectory then stat resolves it as a directory", () async {
    await backend.createDirectory(at("Photos"));
    final StorageStat stat = await backend.stat(at("Photos"));

    expect(stat.exists, isTrue);
    expect(stat.type, StorageEntryType.directory);
  });

  test("createDirectory rejects a duplicate name", () async {
    await backend.createDirectory(at("Photos"));
    expect(
      () => backend.createDirectory(at("Photos")),
      throwsA(isA<PathConflictFailure>()),
    );
  });

  test("list resolves nested paths by walking documentIds level by level", () async {
    await backend.createDirectory(at("Photos"));
    await backend.createDirectory(at("Photos/2026"));
    host.seedFile(parentPath: <String>["Photos", "2026"], name: "beach.jpg", sizeBytes: 4200);

    final List<StorageEntry> entries = await backend.list(at("Photos/2026")).toList();
    expect(entries.map((StorageEntry e) => e.name), <String>["beach.jpg"]);
    expect(entries.single.sizeBytes, 4200);
  });

  test("list on an unknown directory reports StorageDisconnectedFailure", () async {
    expect(
      () => backend.list(at("nowhere")).toList(),
      throwsA(isA<StorageDisconnectedFailure>()),
    );
  });

  test("rename changes the name the entry is found under", () async {
    await backend.createDirectory(at("Old"));
    await backend.rename(at("Old"), "New");

    expect((await backend.stat(at("Old"))).exists, isFalse);
    expect((await backend.stat(at("New"))).exists, isTrue);
  });

  test("delete removes the entry", () async {
    await backend.createDirectory(at("Temp"));
    await backend.delete(at("Temp"));
    expect((await backend.stat(at("Temp"))).exists, isFalse);
  });

  test("copy of an empty directory tree recurses without touching file I/O", () async {
    await backend.createDirectory(at("Src"));
    await backend.createDirectory(at("Src/Inner"));

    await backend.copy(at("Src"), at("Dst"));

    expect((await backend.stat(at("Dst"))).exists, isTrue);
    expect((await backend.stat(at("Dst/Inner"))).exists, isTrue);
  });

  test("copy refuses to clobber an existing target", () async {
    await backend.createDirectory(at("A"));
    await backend.createDirectory(at("B"));
    expect(
      () => backend.copy(at("A"), at("B")),
      throwsA(isA<PathConflictFailure>()),
    );
  });
}

/// In-memory double for [AndroidStorageHost]. DocumentIds are simply the
/// joined path here for readability — real SAF documentIds are opaque
/// provider-assigned strings with no relationship to the path at all, which
/// [SafStorageBackend] never assumes (it only ever compares them for
/// equality, never parses one) — the fake being "too readable" doesn't leak
/// into what the class under test can rely on.
final class FakeAndroidStorageHost implements AndroidStorageHost {
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
  Future<SafTreeInfo?> openDocumentTree() async => null;

  @override
  Future<List<SafTreeInfo>> persistedTrees() async => const <SafTreeInfo>[];

  @override
  Future<void> releasePersistedUri(String treeUri) async {}
}

final class _FakeNode {
  _FakeNode.directory({required this.name}) : isDirectory = true, sizeBytes = null;

  _FakeNode.file({required this.name, required int this.sizeBytes}) : isDirectory = false;

  String name;
  final bool isDirectory;
  final int? sizeBytes;
  final List<String> childIds = <String>[];
}
