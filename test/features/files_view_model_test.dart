import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/data/repositories/file_repository_impl.dart";
import "package:vaultbox/data/repositories/in_memory_recycle_bin_repository.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/data/services/system_clock.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/models/file_ref.dart";
import "package:vaultbox/domain/repositories/file_repository.dart";
import "package:vaultbox/domain/usecases/copy_items.dart";
import "package:vaultbox/domain/usecases/delete_items_to_recycle_bin.dart";
import "package:vaultbox/domain/usecases/import_files.dart";
import "package:vaultbox/domain/usecases/move_items.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/domain/value_objects/storage_entry.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/features/files/viewmodel/files_view_model.dart";

import "../helpers/fake_android_storage_host.dart";

/// Built by constructing [FilesCubit] directly rather than through a widget
/// tree — no more family provider to look one up from, and this Cubit's own
/// logic is exactly what's under test here (KB vol2 §4.3's "no widgets
/// needed" style, now via flutter_bloc rather than a `ProviderContainer`).
void main() {
  const StorageRoot root = StorageRoot(
    id: "mem",
    displayName: "Test root",
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://test",
    capabilities: StorageCapabilities.fullLocal(),
  );

  late MemoryStorageBackend backend;
  late FileRef dirRef;
  final List<FilesCubit> cubits = <FilesCubit>[];

  FilesCubit buildCubit(FileRef directory) {
    final BackendRegistry registry = BackendRegistry()..register(backend);
    final FileRepository files = FileRepositoryImpl(resolveBackend: registry.forRoot);
    final FilesCubit cubit = FilesCubit(
      directory: directory,
      files: files,
      deleteItems: DeleteItemsToRecycleBin(
        files,
        InMemoryRecycleBinRepository(),
        const SystemClock(),
        UuidIdGenerator(),
      ),
      copyItems: CopyItems(files),
      moveItems: MoveItems(files),
      importFiles: ImportFiles(files),
      androidStorageHost: FakeAndroidStorageHost(),
    );
    cubits.add(cubit);
    return cubit;
  }

  setUp(() {
    backend = MemoryStorageBackend(id: root.id)
      ..seedDirectory("/dest")
      ..seedFile("/dest/taken.txt", utf8.encode("existing"))
      ..seedFile("/taken.txt", utf8.encode("incoming"))
      ..seedFile("/free.txt", utf8.encode("z"))
      ..seedDirectory("/sub")
      ..seedDirectory("/sub/nested");

    dirRef = FileRef(root: root, path: StoragePath.root(root.id));
  });

  tearDown(() async {
    for (final FilesCubit cubit in cubits) {
      await cubit.close();
    }
    cubits.clear();
  });

  test("findConflicts reports only names that collide at the destination", () async {
    final FilesCubit cubit = buildCubit(dirRef);
    await cubit.loadFirstPage();

    final FilesState state = cubit.state;
    cubit.toggleSelection(state.entries.firstWhere((StorageEntry e) => e.name == "taken.txt"));
    cubit.toggleSelection(state.entries.firstWhere((StorageEntry e) => e.name == "free.txt"));

    final FileRef dest = FileRef(root: root, path: StoragePath.parse(root.id, "dest"));
    final List<String> conflicts = await cubit.findConflicts(dest);

    expect(conflicts, <String>["taken.txt"]);
  });

  test("the internal .vaultbox folder is hidden at the root but not below it", () async {
    backend
      ..seedDirectory("/.vaultbox")
      ..seedDirectory("/sub/.vaultbox");

    final FilesCubit cubit = buildCubit(dirRef);
    await cubit.loadFirstPage();

    final List<String> rootNames = cubit.state.entries.map((StorageEntry e) => e.name).toList();
    expect(rootNames, isNot(contains(".vaultbox")), reason: "Recycle Bin bookkeeping stays out of the UI");
    expect(rootNames, containsAll(<String>["dest", "sub", "taken.txt", "free.txt"]));

    // Only the top-level one is reserved; a user's own folder of that name is not.
    final FileRef subRef = FileRef(root: root, path: StoragePath.parse(root.id, "sub"));
    final FilesCubit subCubit = buildCubit(subRef);
    await subCubit.loadFirstPage();
    final List<String> subNames = subCubit.state.entries.map((StorageEntry e) => e.name).toList();
    expect(subNames, contains(".vaultbox"));
  });

  test("validateDestination allows an unrelated folder", () async {
    final FilesCubit cubit = buildCubit(dirRef);
    await cubit.loadFirstPage();

    final FilesState state = cubit.state;
    cubit.toggleSelection(state.entries.firstWhere((StorageEntry e) => e.name == "free.txt"));

    final FileRef dest = FileRef(root: root, path: StoragePath.parse(root.id, "dest"));
    expect(cubit.validateDestination(dest), isNull);
  });

  test("validateDestination blocks copying a folder into itself", () async {
    final FilesCubit cubit = buildCubit(dirRef);
    await cubit.loadFirstPage();

    final FilesState state = cubit.state;
    cubit.toggleSelection(state.entries.firstWhere((StorageEntry e) => e.name == "sub"));

    final FileRef self = FileRef(root: root, path: StoragePath.parse(root.id, "sub"));
    final FileRef nested = FileRef(root: root, path: StoragePath.parse(root.id, "sub/nested"));

    expect(cubit.validateDestination(self), isNotNull);
    expect(cubit.validateDestination(nested), isNotNull);
  });
}
