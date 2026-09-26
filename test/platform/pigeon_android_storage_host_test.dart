import "dart:typed_data";

import "package:flutter/services.dart" show PlatformException;
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/platform/adapters/android_storage_host.dart";
import "package:vaultbox/platform/adapters/pigeon_android_storage_host.dart";
import "package:vaultbox/platform/pigeon/storage_api.g.dart";

/// Fake of the generated Pigeon client. `extends` (not `implements`) so the
/// generated constructor and its private plumbing come along for free; every
/// method the adapter calls is overridden.
final class FakeApi extends AndroidStorageApi {
  SafTreeMessage? tree;
  List<SafEntryMessage> children = <SafEntryMessage>[];
  PlatformException? failWith;
  List<PickedFileMessage> picked = <PickedFileMessage>[];

  void _maybeFail() {
    final PlatformException? failure = failWith;
    if (failure != null) throw failure;
  }

  @override
  Future<SafTreeMessage?> openDocumentTree() async {
    _maybeFail();
    return tree;
  }

  @override
  Future<List<SafEntryMessage>> listChildren(String treeUri, String parentDocumentId) async {
    _maybeFail();
    return children;
  }

  @override
  Future<List<PickedFileMessage>> pickFilesToCache() async {
    _maybeFail();
    return picked;
  }

  final List<String> calls = <String>[];

  @override
  Future<int> openStream(String treeUri, String documentId, String mode, int start) async {
    _maybeFail();
    calls.add("open $documentId $mode $start");
    return 42;
  }

  @override
  Future<Uint8List> readChunk(int handle, int maxBytes) async {
    _maybeFail();
    calls.add("read $handle $maxBytes");
    return Uint8List.fromList(<int>[1, 2, 3]);
  }

  @override
  Future<void> writeChunk(int handle, Uint8List bytes) async {
    _maybeFail();
    calls.add("write $handle ${bytes.length}");
  }

  @override
  Future<void> closeStream(int handle) async {
    _maybeFail();
    calls.add("close $handle");
  }
}

void main() {
  late FakeApi api;
  late PigeonAndroidStorageHost host;

  setUp(() {
    api = FakeApi();
    host = PigeonAndroidStorageHost(api: api);
  });

  test("a cancelled picker (null from native) comes back as null", () async {
    api.tree = null;
    expect(await host.openDocumentTree(), isNull);
  });

  test("maps a picked tree, including the root document id", () async {
    api.tree = SafTreeMessage(
      treeUri: "content://com.android.externalstorage.documents/tree/primary%3ADocuments",
      displayName: "Documents",
      rootDocumentId: "primary:Documents",
    );

    final SafTreeInfo? info = await host.openDocumentTree();
    expect(info, isNotNull);
    expect(info!.displayName, "Documents");
    expect(info.rootDocumentId, "primary:Documents");
    expect(info.treeUri, contains("primary%3ADocuments"));
  });

  test("a tree message missing required fields fails loudly, not silently", () async {
    api.tree = SafTreeMessage(displayName: "no uri");
    expect(host.openDocumentTree(), throwsA(isA<UnexpectedFailure>()));
  });

  test("maps directory and file entries; an unknown size stays null (not zero)", () async {
    api.children = <SafEntryMessage>[
      SafEntryMessage(documentId: "d1", name: "Photos", type: SafEntryTypeMessage.directory),
      SafEntryMessage(
        documentId: "f1",
        name: "a.jpg",
        type: SafEntryTypeMessage.file,
        sizeBytes: 1234,
        lastModifiedMillis: 1000,
        mimeType: "image/jpeg",
      ),
      SafEntryMessage(documentId: "f2", name: "mystery.bin", type: SafEntryTypeMessage.file),
    ];

    final List<SafEntryInfo> entries = await host.listChildren("tree", "root");
    expect(entries.map((SafEntryInfo e) => e.kind), <SafEntryKind>[
      SafEntryKind.directory,
      SafEntryKind.file,
      SafEntryKind.file,
    ]);
    expect(entries[1].sizeBytes, 1234);
    expect(entries[1].mimeType, "image/jpeg");
    expect(entries[2].sizeBytes, isNull);
  });

  test("an entry missing its documentId or name is rejected", () async {
    api.children = <SafEntryMessage>[SafEntryMessage(name: "orphan")];
    expect(host.listChildren("tree", "root"), throwsA(isA<UnexpectedFailure>()));
  });

  test("permission_revoked from native becomes PermissionRevokedFailure", () async {
    api.failWith = PlatformException(code: "permission_revoked", message: "grant gone");
    expect(host.listChildren("tree", "root"), throwsA(isA<PermissionRevokedFailure>()));
  });

  test("any other native error becomes UnexpectedFailure and keeps the detail", () async {
    api.failWith = PlatformException(code: "io_error", message: "disk on fire");
    expect(
      host.openStream("tree", "doc", mode: "r"),
      throwsA(
        isA<UnexpectedFailure>().having(
          (UnexpectedFailure f) => f.debugDetail,
          "debugDetail",
          contains("io_error"),
        ),
      ),
    );
  });

  test("passes stream calls straight through", () async {
    final int handle = await host.openStream("tree", "doc", mode: "r", start: 7);
    expect(await host.readChunk(handle, 1024), <int>[1, 2, 3]);
    await host.writeChunk(handle, Uint8List(5));
    await host.closeStream(handle);
    expect(api.calls, <String>["open doc r 7", "read 42 1024", "write 42 5", "close 42"]);
  });

  test("maps picked files (cache path, real name, size, mime)", () async {
    api.picked = <PickedFileMessage>[
      PickedFileMessage(cachePath: "/cache/imports/x/0", name: "report.pdf", sizeBytes: 42, mimeType: "application/pdf"),
    ];

    final List<PickedFile> files = await host.pickFilesToCache();
    expect(files.single.cachePath, "/cache/imports/x/0");
    expect(files.single.name, "report.pdf");
    expect(files.single.sizeBytes, 42);
    expect(files.single.mimeType, "application/pdf");
  });

  test("a cancelled pick is an empty list", () async {
    expect(await host.pickFilesToCache(), isEmpty);
  });

  test("a picked-file message missing its path or name is rejected", () async {
    api.picked = <PickedFileMessage>[PickedFileMessage(name: "no path")];
    expect(host.pickFilesToCache(), throwsA(isA<UnexpectedFailure>()));
  });
}
