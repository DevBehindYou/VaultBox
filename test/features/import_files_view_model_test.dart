import "dart:convert";
import "dart:io";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/models/file_ref.dart";
import "package:vaultbox/domain/models/operation_batch.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/domain/value_objects/storage_entry.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/domain/value_objects/write_mode.dart";
import "package:vaultbox/features/files/viewmodel/files_view_model.dart";
import "package:vaultbox/platform/adapters/android_storage_host.dart";

import "../helpers/fake_android_storage_host.dart";

/// "Add files": picker -> conflict prompt -> import -> cleanup. Uses REAL temp
/// files (plain `test`, real event loop) because the point is that the picker's
/// cache copies are actually read and then actually deleted.
void main() {
  const StorageRoot root = StorageRoot(
    id: "mem",
    displayName: "Test root",
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://test",
    capabilities: StorageCapabilities.fullLocal(),
  );

  late Directory cache;
  late MemoryStorageBackend backend;
  late FakeAndroidStorageHost host;
  late ProviderContainer container;
  late FileRef dirRef;

  PickedFile cached(String name, String content) {
    final File file = File("${cache.path}/${cache.listSync().length}_$name")..writeAsStringSync(content);
    return PickedFile(cachePath: file.path, name: name, sizeBytes: utf8.encode(content).length);
  }

  List<String> names() => container
      .read(filesViewModelProvider(dirRef))
      .entries
      .map((StorageEntry e) => e.name)
      .toList()
    ..sort();

  Future<String> read(String path) async {
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in backend.openRead(StoragePath.parse(root.id, path))) {
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  setUp(() async {
    cache = Directory.systemTemp.createTempSync("vaultbox_pick_");
    backend = MemoryStorageBackend(id: root.id);
    host = FakeAndroidStorageHost();
    final BackendRegistry registry = BackendRegistry()..register(backend);
    container = ProviderContainer(
      overrides: [
        backendRegistryProvider.overrideWithValue(registry),
        androidStorageHostProvider.overrideWithValue(host),
      ],
    );
    dirRef = FileRef(root: root, path: StoragePath.root(root.id));
    container.listen(filesViewModelProvider(dirRef), (FilesState? previous, FilesState next) {});
    await container.read(filesViewModelProvider(dirRef).notifier).loadFirstPage();
  });

  tearDown(() {
    container.dispose();
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  FilesViewModel notifier() => container.read(filesViewModelProvider(dirRef).notifier);

  test("imports the picked files, refreshes the list, and deletes the cache copies", () async {
    final PickedFile a = cached("a.txt", "AAA");
    final PickedFile b = cached("b.txt", "BB");
    host.nextPicked = <PickedFile>[a, b];

    final OperationBatch? batch = await notifier().importFiles(
      onConflicts: (List<String> names) async => fail("no conflicts expected"),
    );

    expect(batch!.completedCount, 2);
    expect(names(), <String>["a.txt", "b.txt"]);
    expect(await read("/a.txt"), "AAA");
    expect(File(a.cachePath).existsSync(), isFalse, reason: "the picker's temp copy must not linger");
    expect(File(b.cachePath).existsSync(), isFalse);
  });

  test("a cancelled picker does nothing", () async {
    host.nextPicked = <PickedFile>[];
    final OperationBatch? batch = await notifier().importFiles(
      onConflicts: (List<String> names) async => fail("picker was cancelled"),
    );
    expect(batch, isNull);
    expect(names(), isEmpty);
  });

  test("only names that already exist are offered as conflicts", () async {
    backend.seedFile("/taken.txt", utf8.encode("existing"));
    await notifier().loadFirstPage();
    host.nextPicked = <PickedFile>[cached("taken.txt", "new"), cached("free.txt", "z")];

    List<String>? offered;
    await notifier().importFiles(
      onConflicts: (List<String> names) async {
        offered = names;
        return ConflictPolicy.keepBoth;
      },
    );

    expect(offered, <String>["taken.txt"]);
    expect(names(), <String>["free.txt", "taken (1).txt", "taken.txt"]);
    expect(await read("/taken.txt"), "existing");
  });

  test("cancelling at the conflict prompt imports nothing and still deletes the copies", () async {
    backend.seedFile("/taken.txt", utf8.encode("existing"));
    await notifier().loadFirstPage();
    final PickedFile clash = cached("taken.txt", "new");
    final PickedFile other = cached("other.txt", "o");
    host.nextPicked = <PickedFile>[clash, other];

    final OperationBatch? batch = await notifier().importFiles(
      onConflicts: (List<String> names) async => null,
    );

    expect(batch, isNull);
    expect(names(), <String>["taken.txt"], reason: "nothing was imported");
    expect(File(clash.cachePath).existsSync(), isFalse);
    expect(File(other.cachePath).existsSync(), isFalse);
  });

  test("replace overwrites the existing file with the picked one", () async {
    backend.seedFile("/doc.txt", utf8.encode("old"));
    await notifier().loadFirstPage();
    host.nextPicked = <PickedFile>[cached("doc.txt", "new")];

    await notifier().importFiles(onConflicts: (List<String> names) async => ConflictPolicy.replace);

    expect(await read("/doc.txt"), "new");
  });

  test("a picker failure surfaces as a failure state, not an exception", () async {
    host.failPick = const PermissionRevokedFailure();

    final OperationBatch? batch = await notifier().importFiles(
      onConflicts: (List<String> names) async => fail("unreachable"),
    );

    expect(batch, isNull);
    expect(container.read(filesViewModelProvider(dirRef)).failure, isA<PermissionRevokedFailure>());
  });
}
