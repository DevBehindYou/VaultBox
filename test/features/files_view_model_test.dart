import "dart:convert";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/models/file_ref.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/domain/value_objects/storage_entry.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/features/files/viewmodel/files_view_model.dart";

/// Built with `ProviderContainer` directly rather than a widget tree —
/// exactly the pattern KB vol2 §4.3 calls out ("no widgets needed") for
/// exercising a Notifier's own logic in isolation.
void main() {
  const StorageRoot root = StorageRoot(
    id: "mem",
    displayName: "Test root",
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://test",
    capabilities: StorageCapabilities.fullLocal(),
  );

  late MemoryStorageBackend backend;
  late ProviderContainer container;
  late FileRef dirRef;

  setUp(() {
    backend = MemoryStorageBackend(id: root.id)
      ..seedDirectory("/dest")
      ..seedFile("/dest/taken.txt", utf8.encode("existing"))
      ..seedFile("/taken.txt", utf8.encode("incoming"))
      ..seedFile("/free.txt", utf8.encode("z"))
      ..seedDirectory("/sub")
      ..seedDirectory("/sub/nested");

    final BackendRegistry registry = BackendRegistry()..register(backend);
    container = ProviderContainer(
      overrides: [backendRegistryProvider.overrideWithValue(registry)],
    );
    dirRef = FileRef(root: root, path: StoragePath.root(root.id));
    // autoDispose tears the element down once nothing is listening — a bare
    // container.read() doesn't count. Keep it alive for the test's duration
    // the same way a widget's watch would (KB vol2 §4.3 "autoDispose"
    // gotcha), rather than racing disposal against the awaited work below.
    container.listen(
      filesViewModelProvider(dirRef),
      (FilesState? previous, FilesState next) {},
    );
  });

  tearDown(() => container.dispose());

  test("findConflicts reports only names that collide at the destination", () async {
    final FilesViewModel notifier = container.read(filesViewModelProvider(dirRef).notifier);
    await notifier.loadFirstPage();

    final FilesState state = container.read(filesViewModelProvider(dirRef));
    notifier.toggleSelection(state.entries.firstWhere((StorageEntry e) => e.name == "taken.txt"));
    notifier.toggleSelection(state.entries.firstWhere((StorageEntry e) => e.name == "free.txt"));

    final FileRef dest = FileRef(root: root, path: StoragePath.parse(root.id, "dest"));
    final List<String> conflicts = await notifier.findConflicts(dest);

    expect(conflicts, <String>["taken.txt"]);
  });

  test("the internal .vaultbox folder is hidden at the root but not below it", () async {
    backend
      ..seedDirectory("/.vaultbox")
      ..seedDirectory("/sub/.vaultbox");

    final FilesViewModel notifier = container.read(filesViewModelProvider(dirRef).notifier);
    await notifier.loadFirstPage();

    final List<String> rootNames = container
        .read(filesViewModelProvider(dirRef))
        .entries
        .map((StorageEntry e) => e.name)
        .toList();
    expect(rootNames, isNot(contains(".vaultbox")), reason: "Recycle Bin bookkeeping stays out of the UI");
    expect(rootNames, containsAll(<String>["dest", "sub", "taken.txt", "free.txt"]));

    // Only the top-level one is reserved; a user's own folder of that name is not.
    final FileRef subRef = FileRef(root: root, path: StoragePath.parse(root.id, "sub"));
    container.listen(
      filesViewModelProvider(subRef),
      (FilesState? previous, FilesState next) {},
    );
    await container.read(filesViewModelProvider(subRef).notifier).loadFirstPage();
    final List<String> subNames = container
        .read(filesViewModelProvider(subRef))
        .entries
        .map((StorageEntry e) => e.name)
        .toList();
    expect(subNames, contains(".vaultbox"));
  });

  test("validateDestination allows an unrelated folder", () async {
    final FilesViewModel notifier = container.read(filesViewModelProvider(dirRef).notifier);
    await notifier.loadFirstPage();

    final FilesState state = container.read(filesViewModelProvider(dirRef));
    notifier.toggleSelection(state.entries.firstWhere((StorageEntry e) => e.name == "free.txt"));

    final FileRef dest = FileRef(root: root, path: StoragePath.parse(root.id, "dest"));
    expect(notifier.validateDestination(dest), isNull);
  });

  test("validateDestination blocks copying a folder into itself", () async {
    final FilesViewModel notifier = container.read(filesViewModelProvider(dirRef).notifier);
    await notifier.loadFirstPage();

    final FilesState state = container.read(filesViewModelProvider(dirRef));
    notifier.toggleSelection(state.entries.firstWhere((StorageEntry e) => e.name == "sub"));

    final FileRef self = FileRef(root: root, path: StoragePath.parse(root.id, "sub"));
    final FileRef nested = FileRef(root: root, path: StoragePath.parse(root.id, "sub/nested"));

    expect(notifier.validateDestination(self), isNotNull);
    expect(notifier.validateDestination(nested), isNotNull);
  });
}
