import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/repositories/file_repository_impl.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/models/file_ref.dart";
import "package:vaultbox/domain/models/operation_batch.dart";
import "package:vaultbox/domain/usecases/import_files.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/domain/value_objects/write_mode.dart";

void main() {
  const StorageRoot root = StorageRoot(
    id: "mem",
    displayName: "Test root",
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://test",
    capabilities: StorageCapabilities.fullLocal(),
  );

  late MemoryStorageBackend backend;
  late ImportFiles importFiles;
  late List<String> disposed;

  FileRef dest([String path = ""]) => FileRef(root: root, path: StoragePath.parse(root.id, path));

  ImportSource text(String name, String content, {int? claimedSize}) => ImportSource(
    name: name,
    sizeBytes: claimedSize ?? utf8.encode(content).length,
    open: () => Stream<List<int>>.value(utf8.encode(content)),
    dispose: () async => disposed.add(name),
  );

  Future<String?> read(String path) async {
    final StoragePath p = StoragePath.parse(root.id, path);
    if (!(await backend.stat(p)).exists) return null;
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in backend.openRead(p)) {
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  setUp(() {
    backend = MemoryStorageBackend(id: root.id)..seedDirectory("/dest");
    importFiles = ImportFiles(FileRepositoryImpl(resolveBackend: (_) => backend));
    disposed = <String>[];
  });

  test("imports every file, reports each outcome, and disposes every source", () async {
    final OperationBatch batch = await importFiles(
      sources: <ImportSource>[text("a.txt", "AAA"), text("b.txt", "BB")],
      destinationDirectory: dest("dest"),
      conflictPolicy: ConflictPolicy.keepBoth,
    );

    expect(batch.completedCount, 2);
    expect(await read("/dest/a.txt"), "AAA");
    expect(await read("/dest/b.txt"), "BB");
    expect(disposed, <String>["a.txt", "b.txt"]);
  });

  test("keep-both never overwrites: the incoming file gets a free name", () async {
    backend.seedFile("/dest/report.pdf", utf8.encode("existing"));

    final OperationBatch batch = await importFiles(
      sources: <ImportSource>[text("report.pdf", "incoming")],
      destinationDirectory: dest("dest"),
      conflictPolicy: ConflictPolicy.keepBoth,
    );

    expect(batch.completedCount, 1);
    expect(await read("/dest/report.pdf"), "existing");
    expect(await read("/dest/report (1).pdf"), "incoming");
  });

  test("skip leaves the existing file alone and reports skipped, not failed", () async {
    backend.seedFile("/dest/same.txt", utf8.encode("existing"));

    final OperationBatch batch = await importFiles(
      sources: <ImportSource>[text("same.txt", "incoming")],
      destinationDirectory: dest("dest"),
      conflictPolicy: ConflictPolicy.skip,
    );

    expect(batch.skippedCount, 1);
    expect(batch.failedCount, 0);
    expect(await read("/dest/same.txt"), "existing");
    expect(disposed, <String>["same.txt"], reason: "the temp copy is still cleaned up");
  });

  test("replace overwrites the existing file", () async {
    backend.seedFile("/dest/doc.txt", utf8.encode("old"));

    final OperationBatch batch = await importFiles(
      sources: <ImportSource>[text("doc.txt", "new")],
      destinationDirectory: dest("dest"),
      conflictPolicy: ConflictPolicy.replace,
    );

    expect(batch.completedCount, 1);
    expect(await read("/dest/doc.txt"), "new");
  });

  test("a size mismatch fails the item and leaves no half-copy behind", () async {
    final OperationBatch batch = await importFiles(
      sources: <ImportSource>[text("bad.txt", "12345", claimedSize: 999)],
      destinationDirectory: dest("dest"),
      conflictPolicy: ConflictPolicy.keepBoth,
    );

    expect(batch.failedCount, 1);
    expect(await read("/dest/bad.txt"), isNull, reason: "a copy that failed verification is removed");
  });

  test("one unreadable file does not stop the rest (ADR-011)", () async {
    final ImportSource broken = ImportSource(
      name: "broken.bin",
      open: () => Stream<List<int>>.error(Exception("disk on fire")),
      dispose: () async => disposed.add("broken.bin"),
    );

    final OperationBatch batch = await importFiles(
      sources: <ImportSource>[text("first.txt", "1"), broken, text("last.txt", "2")],
      destinationDirectory: dest("dest"),
      conflictPolicy: ConflictPolicy.keepBoth,
    );

    expect(batch.completedCount, 2);
    expect(batch.failedCount, 1);
    expect(batch.outcomes.firstWhere((ItemOutcome o) => o.source.name == "broken.bin").userMessage, "Couldn't read this file");
    expect(await read("/dest/first.txt"), "1");
    expect(await read("/dest/last.txt"), "2");
    expect(await read("/dest/broken.bin"), isNull, reason: "the aborted write publishes nothing");
    expect(disposed, containsAll(<String>["first.txt", "broken.bin", "last.txt"]));
  });

  test("a file name that can't be a single path segment fails cleanly", () async {
    final OperationBatch batch = await importFiles(
      sources: <ImportSource>[text("../escape.txt", "x"), text("fine.txt", "ok")],
      destinationDirectory: dest("dest"),
      conflictPolicy: ConflictPolicy.keepBoth,
    );

    expect(batch.failedCount, 1);
    expect(batch.completedCount, 1);
    expect(await read("/dest/fine.txt"), "ok");
    expect(await read("/escape.txt"), isNull);
  });

  test("a dispose that throws never turns a finished import into a failure", () async {
    final ImportSource fragile = ImportSource(
      name: "x.txt",
      sizeBytes: 1,
      open: () => Stream<List<int>>.value(<int>[120]),
      dispose: () async => throw Exception("cleanup failed"),
    );

    final OperationBatch batch = await importFiles(
      sources: <ImportSource>[fragile],
      destinationDirectory: dest("dest"),
      conflictPolicy: ConflictPolicy.keepBoth,
    );

    expect(batch.completedCount, 1);
  });
}
