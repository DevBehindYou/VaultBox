import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/data/services/direct_path_storage_backend.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/repositories/storage_backend.dart";
import "package:vaultbox/domain/value_objects/storage_entry.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/domain/value_objects/write_mode.dart";

/// Storage **contract** tests (doc §60). The same suite runs against every
/// backend, which is the only way the in-memory fake stays a trustworthy
/// stand-in for the real one: if memory and direct-path ever disagree, this
/// file fails rather than the divergence surfacing later as a device-only bug.
void main() {
  group("MemoryStorageBackend", () {
    late MemoryStorageBackend backend;
    setUp(() => backend = MemoryStorageBackend(id: "mem"));
    runContractTests(() => backend, "mem");
  });

  group("DirectPathStorageBackend", () {
    late Directory tempDir;
    late DirectPathStorageBackend backend;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync("vaultbox_contract_");
      backend = DirectPathStorageBackend(id: "disk", rootDirectory: tempDir.path);
    });
    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    runContractTests(() => backend, "disk");

    test("refuses to resolve a path belonging to another root", () {
      expect(
        () => backend.stat(StoragePath.parse("some-other-root", "a")),
        throwsA(isA<PathTraversalRejectedFailure>()),
      );
    });

    test("one unrepresentable on-disk name is skipped, not fatal to the listing", () async {
      // A backslash is a legal POSIX file name but can't be one StoragePath
      // segment. It used to throw out of list() and blank the whole folder.
      File("${tempDir.path}/ok.txt").writeAsStringSync("ok");
      File("${tempDir.path}/bad\\name.txt").writeAsStringSync("odd");

      final List<StorageEntry> entries =
          await backend.list(StoragePath.root("disk")).toList();
      expect(entries.map((StorageEntry e) => e.name), <String>["ok.txt"]);
    }, skip: Platform.isWindows ? "backslash is not a legal Windows file name" : false);
  });
}

void runContractTests(StorageBackend Function() backendOf, String rootId) {
  StoragePath at(String path) => StoragePath.parse(rootId, path);

  Future<void> writeFile(StorageBackend backend, String path, String content) async {
    final StorageWriteHandle handle = await backend.openWrite(at(path));
    handle.sink.add(utf8.encode(content));
    await handle.commit();
  }

  Future<String> readFile(StorageBackend backend, String path) async {
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in backend.openRead(at(path))) {
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  test("names are literal: percent sequences and edge spaces survive a round-trip", () async {
    final StorageBackend backend = backendOf();
    // These previously came back from list() as a DIFFERENT path (decoded /
    // trimmed), so the row pointed at a file other than the one shown.
    const List<String> names = <String>["100%25 done.txt", "%41.txt", " lead.txt", "1:1 notes.txt"];
    for (final String name in names) {
      final StoragePath path = StoragePath.root(rootId).child(name);
      final StorageWriteHandle handle = await backend.openWrite(path);
      handle.sink.add(utf8.encode(name));
      await handle.commit();
    }

    final List<StorageEntry> listed = await backend.list(StoragePath.root(rootId)).toList();
    expect(listed.map((StorageEntry e) => e.name).toList()..sort(), <String>[...names]..sort());

    for (final StorageEntry entry in listed) {
      final List<int> bytes = <int>[];
      await for (final List<int> chunk in backend.openRead(entry.path)) {
        bytes.addAll(chunk);
      }
      expect(utf8.decode(bytes), entry.name, reason: "listed path must open the file it names");
    }
  });

  test("stat reports non-existence rather than throwing", () async {
    final StorageStat stat = await backendOf().stat(at("nope.txt"));
    expect(stat.exists, isFalse);
  });

  test("write then read round-trips content", () async {
    final StorageBackend backend = backendOf();
    await writeFile(backend, "hello.txt", "hello vaultbox");
    expect(await readFile(backend, "hello.txt"), "hello vaultbox");

    final StorageStat stat = await backend.stat(at("hello.txt"));
    expect(stat.exists, isTrue);
    expect(stat.type, StorageEntryType.file);
    expect(stat.sizeBytes, 14);
  });

  test("aborted write leaves nothing at the destination", () async {
    final StorageBackend backend = backendOf();
    final StorageWriteHandle handle = await backend.openWrite(at("partial.txt"));
    handle.sink.add(utf8.encode("half written"));
    await handle.abort();

    final StorageStat stat = await backend.stat(at("partial.txt"));
    expect(
      stat.exists,
      isFalse,
      reason: "abort must not publish a partial file (doc §26)",
    );
  });

  test("openWrite in create mode refuses an existing path", () async {
    final StorageBackend backend = backendOf();
    await writeFile(backend, "dup.txt", "first");
    expect(
      () => backend.openWrite(at("dup.txt")),
      throwsA(isA<PathConflictFailure>()),
    );
  });

  test("openWrite in replace mode overwrites", () async {
    final StorageBackend backend = backendOf();
    await writeFile(backend, "replace.txt", "old content");

    final StorageWriteHandle handle =
        await backend.openWrite(at("replace.txt"), mode: WriteMode.replace);
    handle.sink.add(utf8.encode("new"));
    await handle.commit();

    expect(await readFile(backend, "replace.txt"), "new");
  });

  test("createDirectory rejects duplicates", () async {
    final StorageBackend backend = backendOf();
    await backend.createDirectory(at("folder"));
    expect(
      () => backend.createDirectory(at("folder")),
      throwsA(isA<PathConflictFailure>()),
    );
  });

  test("list returns direct children only", () async {
    final StorageBackend backend = backendOf();
    await backend.createDirectory(at("dir"));
    await backend.createDirectory(at("dir/nested"));
    await writeFile(backend, "dir/a.txt", "a");
    await writeFile(backend, "dir/nested/deep.txt", "deep");

    final List<StorageEntry> entries = await backend.list(at("dir")).toList();
    final List<String> names = entries.map((StorageEntry e) => e.name).toList()..sort();
    expect(names, <String>["a.txt", "nested"]);
  });

  test("list pages by entry name cursor", () async {
    final StorageBackend backend = backendOf();
    await backend.createDirectory(at("page"));
    for (int i = 0; i < 5; i++) {
      await writeFile(backend, "page/file_$i.txt", "x");
    }

    final List<StorageEntry> first =
        await backend.list(at("page"), pageSize: 2).toList();
    expect(first.length, 2);

    final List<StorageEntry> second = await backend
        .list(at("page"), cursor: first.last.name, pageSize: 2)
        .toList();
    expect(second.length, 2);
    expect(
      second.map((StorageEntry e) => e.name),
      isNot(contains(first.first.name)),
      reason: "cursor must resume strictly after the named entry",
    );
  });

  test("openRead honours an inclusive byte range", () async {
    final StorageBackend backend = backendOf();
    await writeFile(backend, "range.txt", "0123456789");

    final List<int> bytes = <int>[];
    await for (final List<int> chunk in backend.openRead(at("range.txt"), start: 2, end: 5)) {
      bytes.addAll(chunk);
    }
    expect(
      utf8.decode(bytes),
      "2345",
      reason: "end is inclusive, matching HTTP Range semantics (doc §10)",
    );
  });

  test("copy duplicates a file without touching the source", () async {
    final StorageBackend backend = backendOf();
    await writeFile(backend, "src.txt", "payload");
    await backend.copy(at("src.txt"), at("dst.txt"));

    expect(await readFile(backend, "src.txt"), "payload");
    expect(await readFile(backend, "dst.txt"), "payload");
  });

  test("copy refuses to clobber an existing target", () async {
    final StorageBackend backend = backendOf();
    await writeFile(backend, "a.txt", "a");
    await writeFile(backend, "b.txt", "b");
    expect(
      () => backend.copy(at("a.txt"), at("b.txt")),
      throwsA(isA<PathConflictFailure>()),
    );
  });

  test("copy recurses into directories", () async {
    final StorageBackend backend = backendOf();
    await backend.createDirectory(at("tree"));
    await backend.createDirectory(at("tree/inner"));
    await writeFile(backend, "tree/inner/leaf.txt", "leaf");

    await backend.copy(at("tree"), at("tree-copy"));
    expect(await readFile(backend, "tree-copy/inner/leaf.txt"), "leaf");
  });

  test("rename moves within the same parent", () async {
    final StorageBackend backend = backendOf();
    await writeFile(backend, "before.txt", "same bytes");
    await backend.rename(at("before.txt"), "after.txt");

    expect((await backend.stat(at("before.txt"))).exists, isFalse);
    expect(await readFile(backend, "after.txt"), "same bytes");
  });

  test("delete removes a directory and everything under it", () async {
    final StorageBackend backend = backendOf();
    await backend.createDirectory(at("gone"));
    await writeFile(backend, "gone/child.txt", "x");

    await backend.delete(at("gone"));
    expect((await backend.stat(at("gone"))).exists, isFalse);
    expect((await backend.stat(at("gone/child.txt"))).exists, isFalse);
  });
}
