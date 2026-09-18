import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/data/repositories/file_repository_impl.dart";
import "package:vaultbox/data/repositories/in_memory_recycle_bin_repository.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/recycle_item.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/models/file_ref.dart";
import "package:vaultbox/domain/models/operation_batch.dart";
import "package:vaultbox/domain/repositories/clock.dart";
import "package:vaultbox/domain/repositories/id_generator.dart";
import "package:vaultbox/domain/repositories/storage_backend.dart";
import "package:vaultbox/domain/usecases/copy_items.dart";
import "package:vaultbox/domain/usecases/delete_items_to_recycle_bin.dart";
import "package:vaultbox/domain/usecases/move_items.dart";
import "package:vaultbox/domain/usecases/permanently_delete_recycled.dart";
import "package:vaultbox/domain/usecases/restore_items.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/domain/value_objects/storage_entry.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/domain/value_objects/write_mode.dart";

/// Fakes required by doc §59 — a fixed clock and a predictable id source, so
/// recycle-bin behaviour is deterministic.
final class FakeClock implements Clock {
  FakeClock(this._now);
  final DateTime _now;
  @override
  DateTime now() => _now;
}

final class SequentialIds implements IdGenerator {
  int _next = 0;
  @override
  String newId() => "id-${_next++}";
}

/// Wraps a backend and makes one named file fail on read, so batch isolation
/// (ADR-011) can be tested without contorting the real backend.
final class FlakyBackend implements StorageBackend {
  FlakyBackend(this._inner, this.failingName);

  final StorageBackend _inner;
  final String failingName;

  @override
  String get id => _inner.id;

  @override
  Future<StorageCapabilities> capabilities() => _inner.capabilities();

  @override
  Future<void> copy(StoragePath source, StoragePath target) {
    if (source.name == failingName) {
      throw const PermissionRevokedFailure(debugDetail: "injected");
    }
    return _inner.copy(source, target);
  }

  @override
  Future<void> createDirectory(StoragePath path) => _inner.createDirectory(path);

  @override
  Future<void> delete(StoragePath path) => _inner.delete(path);

  @override
  Stream<StorageEntry> list(StoragePath directory, {String? cursor, int? pageSize}) =>
      _inner.list(directory, cursor: cursor, pageSize: pageSize);

  @override
  Future<void> move(StoragePath source, StoragePath target) => _inner.move(source, target);

  @override
  Stream<List<int>> openRead(StoragePath path, {int? start, int? end}) =>
      _inner.openRead(path, start: start, end: end);

  @override
  Future<StorageWriteHandle> openWrite(StoragePath path, {WriteMode mode = WriteMode.create}) =>
      _inner.openWrite(path, mode: mode);

  @override
  Future<void> rename(StoragePath source, String newName) => _inner.rename(source, newName);

  @override
  Future<StorageStat> stat(StoragePath path) => _inner.stat(path);
}

void main() {
  const StorageRoot root = StorageRoot(
    id: "mem",
    displayName: "Test root",
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://test",
    capabilities: StorageCapabilities.fullLocal(),
  );

  late MemoryStorageBackend backend;
  late FileRepositoryImpl files;

  FileRef ref(String path) =>
      FileRef(root: root, path: StoragePath.parse(root.id, path));

  Future<String?> read(String path) async {
    final StorageStat stat = await backend.stat(StoragePath.parse(root.id, path));
    if (!stat.exists) return null;
    final List<int> bytes = <int>[];
    await for (final List<int> chunk
        in backend.openRead(StoragePath.parse(root.id, path))) {
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  setUp(() {
    backend = MemoryStorageBackend(id: root.id);
    files = FileRepositoryImpl(resolveBackend: (_) => backend);
  });

  group("CopyItems", () {
    test("copies every item and reports each outcome", () async {
      backend
        ..seedDirectory("/dest")
        ..seedFile("/a.txt", utf8.encode("A"))
        ..seedFile("/b.txt", utf8.encode("B"));

      final OperationBatch batch = await CopyItems(files).call(
        sources: <FileRef>[ref("a.txt"), ref("b.txt")],
        destinationDirectory: ref("dest"),
        conflictPolicy: ConflictPolicy.keepBoth,
      );

      expect(batch.completedCount, 2);
      expect(batch.hasFailures, isFalse);
      expect(await read("/dest/a.txt"), "A");
      expect(await read("/dest/b.txt"), "B");
    });

    test("one failing item does not abort the batch (ADR-011)", () async {
      backend
        ..seedDirectory("/dest")
        ..seedFile("/good1.txt", utf8.encode("1"))
        ..seedFile("/bad.txt", utf8.encode("X"))
        ..seedFile("/good2.txt", utf8.encode("2"));

      final FlakyBackend flaky = FlakyBackend(backend, "bad.txt");
      final FileRepositoryImpl flakyFiles =
          FileRepositoryImpl(resolveBackend: (_) => flaky);

      final OperationBatch batch = await CopyItems(flakyFiles).call(
        sources: <FileRef>[ref("good1.txt"), ref("bad.txt"), ref("good2.txt")],
        destinationDirectory: ref("dest"),
        conflictPolicy: ConflictPolicy.keepBoth,
      );

      expect(batch.completedCount, 2);
      expect(batch.failedCount, 1);
      expect(batch.summary, "2 completed · 1 failed");
      expect(await read("/dest/good1.txt"), "1");
      expect(await read("/dest/good2.txt"), "2");
    });

    test("keepBoth resolves a naming conflict instead of failing", () async {
      backend
        ..seedDirectory("/dest")
        ..seedFile("/dest/report.pdf", utf8.encode("existing"))
        ..seedFile("/report.pdf", utf8.encode("new"));

      final OperationBatch batch = await CopyItems(files).call(
        sources: <FileRef>[ref("report.pdf")],
        destinationDirectory: ref("dest"),
        conflictPolicy: ConflictPolicy.keepBoth,
      );

      expect(batch.completedCount, 1);
      expect(await read("/dest/report.pdf"), "existing");
      expect(await read("/dest/report (1).pdf"), "new");
    });

    test("skip policy reports skipped, not failed", () async {
      backend
        ..seedDirectory("/dest")
        ..seedFile("/dest/same.txt", utf8.encode("existing"))
        ..seedFile("/same.txt", utf8.encode("incoming"));

      final OperationBatch batch = await CopyItems(files).call(
        sources: <FileRef>[ref("same.txt")],
        destinationDirectory: ref("dest"),
        conflictPolicy: ConflictPolicy.skip,
      );

      expect(batch.skippedCount, 1);
      expect(batch.failedCount, 0);
      expect(await read("/dest/same.txt"), "existing");
    });
  });

  group("MoveItems", () {
    test("removes the source only after the copy lands", () async {
      backend
        ..seedDirectory("/dest")
        ..seedFile("/move-me.txt", utf8.encode("payload"));

      final OperationBatch batch = await MoveItems(files).call(
        sources: <FileRef>[ref("move-me.txt")],
        destinationDirectory: ref("dest"),
        conflictPolicy: ConflictPolicy.keepBoth,
      );

      expect(batch.completedCount, 1);
      expect(await read("/dest/move-me.txt"), "payload");
      expect(await read("/move-me.txt"), isNull);
    });

    test("a failed copy leaves the source intact (doc §26)", () async {
      backend
        ..seedDirectory("/dest")
        ..seedFile("/precious.txt", utf8.encode("irreplaceable"));

      final FlakyBackend flaky = FlakyBackend(backend, "precious.txt");
      final FileRepositoryImpl flakyFiles =
          FileRepositoryImpl(resolveBackend: (_) => flaky);

      final OperationBatch batch = await MoveItems(flakyFiles).call(
        sources: <FileRef>[ref("precious.txt")],
        destinationDirectory: ref("dest"),
        conflictPolicy: ConflictPolicy.keepBoth,
      );

      expect(batch.failedCount, 1);
      expect(
        await read("/precious.txt"),
        "irreplaceable",
        reason: "the only valid copy must never be destroyed on a failed move",
      );
    });
  });

  group("DeleteItemsToRecycleBin", () {
    test("moves items into the per-root recycle location and records metadata", () async {
      backend.seedFile("/trash-me.txt", utf8.encode("bytes"));

      final InMemoryRecycleBinRepository bin = InMemoryRecycleBinRepository();
      final OperationBatch batch = await DeleteItemsToRecycleBin(
        files,
        bin,
        FakeClock(DateTime.utc(2026, 9, 16)),
        SequentialIds(),
      ).call(sources: <FileRef>[ref("trash-me.txt")]);

      expect(batch.completedCount, 1);
      expect(await read("/trash-me.txt"), isNull);
      expect(await read("/.vaultbox/recycle/id-0__trash-me.txt"), "bytes");

      final List<RecycleItem> items = await bin.listItems(root.id);
      expect(items.length, 1);
      await bin.dispose();
    });

    test("is idempotent about creating the recycle directory", () async {
      backend
        ..seedFile("/one.txt", utf8.encode("1"))
        ..seedFile("/two.txt", utf8.encode("2"));

      final InMemoryRecycleBinRepository bin = InMemoryRecycleBinRepository();
      final OperationBatch batch = await DeleteItemsToRecycleBin(
        files,
        bin,
        FakeClock(DateTime.utc(2026, 9, 16)),
        SequentialIds(),
      ).call(sources: <FileRef>[ref("one.txt"), ref("two.txt")]);

      expect(batch.completedCount, 2, reason: "second delete must reuse the directory");
      await bin.dispose();
    });
  });

  group("RestoreItems and PermanentlyDeleteRecycled", () {
    test("restore copies bytes back and removes the recycled copy + metadata", () async {
      backend.seedFile("/come-back.txt", utf8.encode("payload"));
      final InMemoryRecycleBinRepository bin = InMemoryRecycleBinRepository();
      final InMemoryStorageRootRepository roots =
          InMemoryStorageRootRepository(initial: <StorageRoot>[root]);

      final OperationBatch deleteBatch = await DeleteItemsToRecycleBin(
        files,
        bin,
        FakeClock(DateTime.utc(2026, 9, 16)),
        SequentialIds(),
      ).call(sources: <FileRef>[ref("come-back.txt")]);
      expect(deleteBatch.completedCount, 1);

      final RecycleItem recycled = (await bin.listItems(root.id)).single;
      final OperationBatch restoreBatch = await RestoreItems(
        files,
        bin,
        roots,
      ).call(recycleItemIds: <String>[recycled.id]);

      expect(restoreBatch.completedCount, 1);
      expect(await read("/come-back.txt"), "payload");
      expect(await read("/.vaultbox/recycle/${recycled.id}__come-back.txt"), isNull);
      expect(await bin.get(recycled.id), isNull, reason: "metadata row removed on restore");

      await bin.dispose();
      await roots.dispose();
    });

    test("restore reports a conflict without overwriting what's now there", () async {
      backend.seedFile("/contested.txt", utf8.encode("original"));
      final InMemoryRecycleBinRepository bin = InMemoryRecycleBinRepository();
      final InMemoryStorageRootRepository roots =
          InMemoryStorageRootRepository(initial: <StorageRoot>[root]);

      await DeleteItemsToRecycleBin(
        files,
        bin,
        FakeClock(DateTime.utc(2026, 9, 16)),
        SequentialIds(),
      ).call(sources: <FileRef>[ref("contested.txt")]);
      final RecycleItem recycled = (await bin.listItems(root.id)).single;

      // Something new now occupies the original path.
      backend.seedFile("/contested.txt", utf8.encode("someone else's new file"));

      final OperationBatch restoreBatch =
          await RestoreItems(files, bin, roots).call(recycleItemIds: <String>[recycled.id]);

      expect(restoreBatch.skippedCount, 1);
      expect(
        await read("/contested.txt"),
        "someone else's new file",
        reason: "restore must never clobber what's occupying the original path now",
      );
      expect(
        await bin.get(recycled.id),
        isNotNull,
        reason: "item stays in the bin when restore is skipped, not silently dropped",
      );

      await bin.dispose();
      await roots.dispose();
    });

    test("permanent delete removes bytes and metadata together", () async {
      backend.seedFile("/gone-for-good.txt", utf8.encode("bye"));
      final InMemoryRecycleBinRepository bin = InMemoryRecycleBinRepository();
      final InMemoryStorageRootRepository roots =
          InMemoryStorageRootRepository(initial: <StorageRoot>[root]);

      await DeleteItemsToRecycleBin(
        files,
        bin,
        FakeClock(DateTime.utc(2026, 9, 16)),
        SequentialIds(),
      ).call(sources: <FileRef>[ref("gone-for-good.txt")]);
      final RecycleItem recycled = (await bin.listItems(root.id)).single;

      final OperationBatch batch = await PermanentlyDeleteRecycled(
        files,
        bin,
        roots,
      ).call(recycleItemIds: <String>[recycled.id]);

      expect(batch.completedCount, 1);
      expect(await read("/.vaultbox/recycle/${recycled.id}__gone-for-good.txt"), isNull);
      expect(await bin.get(recycled.id), isNull);

      await bin.dispose();
      await roots.dispose();
    });

    test("permanent delete on an id that's already gone is a silent no-op", () async {
      final InMemoryRecycleBinRepository bin = InMemoryRecycleBinRepository();
      final InMemoryStorageRootRepository roots =
          InMemoryStorageRootRepository(initial: <StorageRoot>[root]);

      final OperationBatch batch = await PermanentlyDeleteRecycled(
        files,
        bin,
        roots,
      ).call(recycleItemIds: <String>["never-existed"]);

      expect(batch.outcomes, isEmpty);
      await bin.dispose();
      await roots.dispose();
    });
  });
}
