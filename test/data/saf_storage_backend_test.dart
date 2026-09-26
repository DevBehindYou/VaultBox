import "dart:async";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/data/services/saf_storage_backend.dart";
import "package:vaultbox/domain/value_objects/storage_entry.dart";
import "package:vaultbox/domain/repositories/storage_backend.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/domain/value_objects/write_mode.dart";

import "../helpers/fake_android_storage_host.dart";

/// [SafStorageBackend] against an in-memory [FakeAndroidStorageHost]: path to
/// documentId resolution, metadata operations, and byte I/O through the
/// chunked `openStream`/`readChunk`/`writeChunk`/`closeStream` bridge.
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

  group("byte I/O", () {
    List<int> pattern(int length) => List<int>.generate(length, (int i) => (i * 31 + 7) & 0xff);

    Future<List<int>> readAll(Stream<List<int>> stream) async =>
        (await stream.toList()).expand((List<int> c) => c).toList();

    test("a file larger than one chunk writes and reads back byte for byte", () async {
      final List<int> data = pattern(SafStorageBackend.chunkSize * 2 + 12345);
      final StorageWriteHandle handle = await backend.openWrite(at("/big.bin"));
      await handle.sink.addStream(Stream<List<int>>.fromIterable(<List<int>>[
        for (int i = 0; i < data.length; i += 65536) data.sublist(i, i + 65536 > data.length ? data.length : i + 65536),
      ]));
      expect(await handle.commit(), data.length);

      expect(host.contentOf(<String>["big.bin"]), data);
      expect(await readAll(backend.openRead(at("/big.bin"))), data);
      expect(host.openStreamCount, 0);
    });

    test("a byte range reads exactly start..end inclusive", () async {
      host.seedFile(parentPath: <String>[], name: "r.bin", content: pattern(2000));
      expect(await readAll(backend.openRead(at("/r.bin"), start: 100, end: 199)), pattern(2000).sublist(100, 200));
      expect(await readAll(backend.openRead(at("/r.bin"), start: 1990)), pattern(2000).sublist(1990));
      expect(host.openStreamCount, 0);
    });

    test("cancelling a read part-way releases the native stream", () async {
      host.seedFile(parentPath: <String>[], name: "c.bin", content: pattern(SafStorageBackend.chunkSize * 3));
      final Completer<void> first = Completer<void>();
      final StreamSubscription<List<int>> sub = backend.openRead(at("/c.bin")).listen((_) {
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      await sub.cancel();
      expect(host.openStreamCount, 0);
    });

    test("a write that fails mid-way reports the error, removes the new file and releases the stream", () async {
      host
        ..failWriteAfter = const PermissionRevokedFailure(debugDetail: "card pulled")
        ..failWriteAfterBytes = SafStorageBackend.chunkSize;
      final StorageWriteHandle handle = await backend.openWrite(at("/half.bin"));
      await expectLater(
        handle.sink.addStream(Stream<List<int>>.value(pattern(SafStorageBackend.chunkSize * 3))),
        throwsA(isA<PermissionRevokedFailure>()),
      );
      await handle.abort();

      expect((await backend.stat(at("/half.bin"))).exists, isFalse);
      expect(host.openStreamCount, 0);
    });

    test("replace truncates: a shorter overwrite leaves no old tail", () async {
      host.seedFile(parentPath: <String>[], name: "t.txt", content: pattern(5000));
      final StorageWriteHandle handle = await backend.openWrite(at("/t.txt"), mode: WriteMode.replace);
      await handle.sink.addStream(Stream<List<int>>.value(<int>[1, 2, 3]));
      await handle.commit();
      expect(host.contentOf(<String>["t.txt"]), <int>[1, 2, 3]);
    });

    test("create refuses an existing file", () async {
      host.seedFile(parentPath: <String>[], name: "x.bin", sizeBytes: 3);
      expect(backend.openWrite(at("/x.bin")), throwsA(isA<PathConflictFailure>()));
    });

    test("copy duplicates the bytes and keeps the source", () async {
      host.seedFile(parentPath: <String>[], name: "src.bin", content: pattern(700000));
      await backend.copy(at("/src.bin"), at("/dst.bin"));
      expect(host.contentOf(<String>["dst.bin"]), pattern(700000));
      expect(host.contentOf(<String>["src.bin"]), pattern(700000));
      expect(host.openStreamCount, 0);
    });

    test("an empty file round-trips", () async {
      final StorageWriteHandle handle = await backend.openWrite(at("/empty.bin"));
      await handle.sink.addStream(const Stream<List<int>>.empty());
      expect(await handle.commit(), 0);
      expect(await readAll(backend.openRead(at("/empty.bin"))), isEmpty);
      expect(host.contentOf(<String>["empty.bin"]), Uint8List(0));
    });
  });
}
