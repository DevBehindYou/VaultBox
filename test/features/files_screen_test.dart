import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/data/repositories/file_repository_impl.dart";
import "package:vaultbox/data/repositories/in_memory_recycle_bin_repository.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/data/services/system_clock.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/repositories/file_repository.dart";
import "package:vaultbox/domain/repositories/recycle_bin_repository.dart";
import "package:vaultbox/domain/repositories/storage_root_repository.dart";
import "package:vaultbox/domain/usecases/copy_items.dart";
import "package:vaultbox/domain/usecases/delete_items_to_recycle_bin.dart";
import "package:vaultbox/domain/usecases/import_files.dart";
import "package:vaultbox/domain/usecases/move_items.dart";
import "package:vaultbox/domain/usecases/permanently_delete_recycled.dart";
import "package:vaultbox/domain/usecases/restore_items.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/features/files/presentation/files_screen.dart";
import "package:vaultbox/features/files/viewmodel/files_view_model.dart";
import "package:vaultbox/platform/adapters/android_storage_host.dart";

import "../helpers/fake_android_storage_host.dart";

/// Widget tests run entirely against in-memory fakes — doc §59's whole
/// point: UI development must never depend on device or network state.
///
/// [BackendRegistry], [StorageRootRepository] and [RecycleBinRepository] are
/// all fakes/in-memory doubles here, not just the backend registry. The
/// app's real, production-wired versions of the latter two now open a
/// Drift/sqlite database (see `app/providers.dart`), which needs
/// `path_provider`'s platform channel — unavailable in a plain widget test.
/// Any screen this harness renders that reaches for storage roots (the
/// destination picker's root switcher) or the Recycle Bin must find these
/// in-memory fakes instead, or the test would fail on a `MissingPluginException`
/// having nothing to do with the behaviour under test.
void main() {
  const StorageRoot root = StorageRoot(
    id: "mem",
    displayName: "Test storage",
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://test",
    capabilities: StorageCapabilities.fullLocal(),
    isDefault: true,
  );

  Widget harness(
    MemoryStorageBackend backend, {
    StorageRootRepository? storageRoots,
    RecycleBinRepository? recycleBin,
  }) {
    final BackendRegistry registry = BackendRegistry()..register(backend);
    final FileRepository fileRepository = FileRepositoryImpl(resolveBackend: registry.forRoot);
    final RecycleBinRepository recycleBinRepository = recycleBin ?? InMemoryRecycleBinRepository();
    final StorageRootRepository storageRootRepository =
        storageRoots ?? InMemoryStorageRootRepository(initial: <StorageRoot>[root]);

    return MultiRepositoryProvider(
      providers: <RepositoryProvider<dynamic>>[
        RepositoryProvider<BackendRegistry>.value(value: registry),
        RepositoryProvider<FileRepository>.value(value: fileRepository),
        RepositoryProvider<StorageRootRepository>.value(value: storageRootRepository),
        RepositoryProvider<RecycleBinRepository>.value(value: recycleBinRepository),
        RepositoryProvider<AndroidStorageHost>.value(value: FakeAndroidStorageHost()),
        RepositoryProvider<DeleteItemsToRecycleBin>.value(
          value: DeleteItemsToRecycleBin(
            fileRepository,
            recycleBinRepository,
            const SystemClock(),
            UuidIdGenerator(),
          ),
        ),
        RepositoryProvider<CopyItems>.value(value: CopyItems(fileRepository)),
        RepositoryProvider<MoveItems>.value(value: MoveItems(fileRepository)),
        RepositoryProvider<ImportFiles>.value(value: ImportFiles(fileRepository)),
        RepositoryProvider<RestoreItems>.value(
          value: RestoreItems(fileRepository, recycleBinRepository, storageRootRepository),
        ),
        RepositoryProvider<PermanentlyDeleteRecycled>.value(
          value: PermanentlyDeleteRecycled(fileRepository, recycleBinRepository, storageRootRepository),
        ),
      ],
      child: MaterialApp(
        theme: AuroraTheme.light(),
        home: FilesScreen(directory: rootRef(root)),
      ),
    );
  }

  /// Every visible Text on screen — attached to failure messages so a red CI
  /// run shows what the UI actually rendered (no local device to look at).
  String screenTexts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((Text t) => t.data ?? t.textSpan?.toPlainText() ?? "")
      .toList()
      .toString();

  testWidgets("renders folders and files from the backend", (WidgetTester tester) async {
    final MemoryStorageBackend backend = MemoryStorageBackend(id: root.id)
      ..seedDirectory("/Documents")
      ..seedFile("/notes.txt", utf8.encode("hello"));

    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();

    expect(find.text("Documents"), findsOneWidget);
    expect(find.text("notes.txt"), findsOneWidget);
  });

  testWidgets("shows an empty state for an empty folder", (WidgetTester tester) async {
    await tester.pumpWidget(harness(MemoryStorageBackend(id: root.id)));
    await tester.pumpAndSettle();

    expect(find.text("This folder is empty"), findsOneWidget);
  });

  testWidgets("long press enters selection mode with Copy/Move/Delete all live",
      (WidgetTester tester) async {
    final MemoryStorageBackend backend = MemoryStorageBackend(id: root.id)
      ..seedFile("/a.txt", utf8.encode("a"))
      ..seedFile("/b.txt", utf8.encode("b"));

    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();

    await tester.longPress(find.text("a.txt"));
    await tester.pumpAndSettle();

    expect(find.text("1 selected"), findsOneWidget);
    expect(find.text("Copy"), findsOneWidget);
    expect(find.text("Move"), findsOneWidget);
    expect(find.text("Delete"), findsOneWidget);
  });

  testWidgets("one selected file offers Share, but not Ask for files", (WidgetTester tester) async {
    final MemoryStorageBackend backend = MemoryStorageBackend(id: root.id)
      ..seedFile("/a.txt", utf8.encode("a"));

    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await tester.longPress(find.text("a.txt"));
    await tester.pumpAndSettle();

    expect(find.text("Share"), findsOneWidget);
    expect(find.text("Ask for files"), findsNothing, reason: "people can only send files into a folder");
  });

  testWidgets("one selected folder offers both Share and Ask for files", (WidgetTester tester) async {
    final MemoryStorageBackend backend = MemoryStorageBackend(id: root.id)..seedDirectory("/Inbox");

    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await tester.longPress(find.text("Inbox"));
    await tester.pumpAndSettle();

    expect(find.text("Share"), findsOneWidget);
    expect(find.text("Ask for files"), findsOneWidget);
  });

  testWidgets("several selected items offer neither, since a link is for one item", (WidgetTester tester) async {
    final MemoryStorageBackend backend = MemoryStorageBackend(id: root.id)
      ..seedFile("/a.txt", utf8.encode("a"))
      ..seedFile("/b.txt", utf8.encode("b"));

    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await tester.longPress(find.text("a.txt"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("b.txt"));
    await tester.pumpAndSettle();

    expect(find.text("2 selected"), findsOneWidget);
    expect(find.text("Share"), findsNothing);
    expect(find.text("Ask for files"), findsNothing);
    expect(find.text("Copy"), findsOneWidget, reason: "the other actions stay");
  });

  testWidgets("Share opens the link dialog for the selected item", (WidgetTester tester) async {
    final MemoryStorageBackend backend = MemoryStorageBackend(id: root.id)
      ..seedFile("/a.txt", utf8.encode("a"));

    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await tester.longPress(find.text("a.txt"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Share"));
    await tester.pumpAndSettle();

    expect(find.text("Share a link"), findsOneWidget);
    expect(find.textContaining("can download “a.txt”"), findsOneWidget);
  });

  testWidgets("creating a folder refreshes the listing", (WidgetTester tester) async {
    await tester.pumpWidget(harness(MemoryStorageBackend(id: root.id)));
    await tester.pumpAndSettle();

    await tester.tap(find.text("New folder"));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)),
      "Photos",
    );
    await tester.tap(find.text("Create"));
    await tester.pumpAndSettle();

    expect(find.text("Photos"), findsOneWidget, reason: "screen: ${screenTexts(tester)}");
  });

  testWidgets("delete then restore round-trips through the Recycle Bin",
      (WidgetTester tester) async {
    final MemoryStorageBackend backend = MemoryStorageBackend(id: root.id)
      ..seedFile("/keepsake.txt", utf8.encode("precious"));
    final InMemoryRecycleBinRepository recycleBin = InMemoryRecycleBinRepository();

    await tester.pumpWidget(harness(backend, recycleBin: recycleBin));
    await tester.pumpAndSettle();

    // Select and delete.
    await tester.longPress(find.text("keepsake.txt"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Delete"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Move to Recycle Bin"));
    await tester.pumpAndSettle();

    expect(
      find.text("keepsake.txt"),
      findsNothing,
      reason: "gone from the live folder; screen: ${screenTexts(tester)}",
    );

    // Open the Recycle Bin and restore it.
    await tester.tap(find.byTooltip("Recycle Bin"));
    await tester.pumpAndSettle();

    expect(find.text("keepsake.txt"), findsOneWidget, reason: "shows up in the bin");
    await tester.tap(find.text("Restore"));
    await tester.pumpAndSettle();

    expect(find.text("Recycle Bin is empty"), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(
      find.text("keepsake.txt"),
      findsOneWidget,
      reason: "back in the live folder after restore",
    );
  });
}
