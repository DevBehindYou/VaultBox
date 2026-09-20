import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/core/design/aurora_theme.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/features/settings/presentation/storage_screen.dart";
import "package:vaultbox/platform/adapters/volume_stats_source.dart";

import "../helpers/fake_clock.dart";

final class _FakeStats implements VolumeStatsSource {
  _FakeStats([this.byRoot = const <String, VolumeStats>{}]);

  final Map<String, VolumeStats> byRoot;

  @override
  Future<VolumeStats?> statsFor(StorageRoot root) async => byRoot[root.id];
}

/// Storage & Volumes: what is being served, where it really lives, how full it
/// is, and the things you can do about each location.
void main() {
  const int gb = 1024 * 1024 * 1024;

  const StorageRoot internal = StorageRoot(
    id: "int",
    displayName: "Family files",
    backendType: StorageBackendType.saf,
    uriOrPath: "content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FVaultBox",
    capabilities: StorageCapabilities.fullLocal(),
    isDefault: true,
    rootDocumentId: "primary:Documents/VaultBox",
  );

  const StorageRoot card = StorageRoot(
    id: "sd",
    displayName: "SD card",
    backendType: StorageBackendType.saf,
    uriOrPath: "content://com.android.externalstorage.documents/tree/1A2B-3C4D%3AMedia",
    capabilities: StorageCapabilities.fullLocal(),
    isRemovable: true,
    rootDocumentId: "1A2B-3C4D:Media",
  );

  late InMemoryStorageRootRepository repo;

  setUp(() {
    repo = InMemoryStorageRootRepository(initial: <StorageRoot>[internal, card]);
  });

  Future<void> show(
    WidgetTester tester, {
    Map<String, VolumeStats> stats = const <String, VolumeStats>{},
    InMemoryStorageRootRepository? roots,
  }) async {
    tester.view.physicalSize = const Size(800, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final BackendRegistry registry = BackendRegistry()
      ..register(MemoryStorageBackend(id: "int"))
      ..register(MemoryStorageBackend(id: "sd"));
    final GoRouter router = GoRouter(
      routes: <RouteBase>[
        GoRoute(path: "/", builder: (BuildContext c, GoRouterState s) => const StorageScreen()),
        GoRoute(
          path: "/onboarding/welcome",
          builder: (BuildContext c, GoRouterState s) => const Scaffold(body: Text("route:/onboarding/welcome")),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageRootRepositoryProvider.overrideWithValue(roots ?? repo),
          backendRegistryProvider.overrideWithValue(registry),
          volumeStatsSourceProvider.overrideWithValue(_FakeStats(stats)),
          clockProvider.overrideWithValue(FakeClock()),
        ],
        child: MaterialApp.router(theme: AuroraTheme.light(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  group("what is listed", () {
    testWidgets("each location with its volume, its real path and its state", (WidgetTester tester) async {
      await show(tester);

      expect(find.text("Storage & Volumes"), findsOneWidget);
      expect(find.text("Family files"), findsOneWidget);
      expect(find.text("Internal storage"), findsOneWidget);
      expect(find.text("/storage/emulated/0/Documents/VaultBox"), findsOneWidget);
      expect(find.text("SD card"), findsOneWidget);
      expect(find.text("SD card or USB drive"), findsOneWidget);
      expect(find.text("/storage/1A2B-3C4D/Media"), findsOneWidget);
      expect(find.text("DEFAULT"), findsOneWidget);
      expect(find.text("ONLINE"), findsNWidgets(2));
      expect(find.text("2 configured"), findsOneWidget);
    });

    testWidgets("real capacity: the total, and how full each volume is", (WidgetTester tester) async {
      await show(
        tester,
        stats: <String, VolumeStats>{
          "int": const VolumeStats(freeBytes: 60 * gb, totalBytes: 100 * gb),
          "sd": const VolumeStats(freeBytes: 30 * gb, totalBytes: 60 * gb),
        },
      );

      expect(find.text("TOTAL CAPACITY"), findsOneWidget);
      expect(find.text("90.0 GB"), findsWidgets, reason: "free across both: the headline and the legend");
      expect(find.text("free of 160.0 GB"), findsOneWidget);
      expect(find.text("40.0 GB used"), findsOneWidget);
      expect(find.text("60.0 GB free"), findsOneWidget);
      expect(find.text("30.0 GB used"), findsOneWidget);
      expect(find.text("30.0 GB free"), findsOneWidget);
    });

    testWidgets("when nothing can be measured it says so instead of showing zeros", (WidgetTester tester) async {
      await show(tester);

      expect(find.textContaining("couldn't be read for these locations"), findsOneWidget);
      expect(find.text("How full this volume is couldn't be read."), findsNWidgets(2));
      expect(find.text("TOTAL CAPACITY"), findsNothing);
    });

    testWidgets("an offline location is marked and isn't measured", (WidgetTester tester) async {
      await show(
        tester,
        roots: InMemoryStorageRootRepository(initial: <StorageRoot>[internal, card.copyWith(isAvailable: false)]),
      );

      expect(find.text("OFFLINE"), findsOneWidget);
      expect(find.text("ONLINE"), findsOneWidget);
    });

    testWidgets("a read-only location says people can't add files", (WidgetTester tester) async {
      await show(
        tester,
        roots: InMemoryStorageRootRepository(
          initial: <StorageRoot>[
            StorageRoot(
              id: "ro",
              displayName: "Archive",
              backendType: StorageBackendType.saf,
              uriOrPath: "content://com.android.externalstorage.documents/tree/primary%3AArchive",
              capabilities: const StorageCapabilities.readOnly(),
              rootDocumentId: "primary:Archive",
            ),
          ],
        ),
      );

      expect(find.textContaining("Read-only: people can look and download but not add files."), findsOneWidget);
    });
  });

  group("test read/write", () {
    testWidgets("proves the location works and says how long it took", (WidgetTester tester) async {
      await show(tester);

      await tester.tap(find.text("Test read/write").first);
      await tester.pumpAndSettle();

      expect(find.textContaining("Reading and writing both work."), findsOneWidget);
    });
  });

  group("make default", () {
    testWidgets("is offered only on locations that aren't the default, and switches it", (WidgetTester tester) async {
      await show(tester);
      expect(find.text("Make default"), findsOneWidget, reason: "not on the one that already is");

      await tester.tap(find.text("Make default"));
      await tester.pumpAndSettle();

      expect((await repo.getRoot("sd"))!.isDefault, isTrue);
      expect((await repo.getRoot("int"))!.isDefault, isFalse);
    });
  });

  group("stop serving", () {
    testWidgets("asks first; Keep changes nothing", (WidgetTester tester) async {
      await show(tester);

      await tester.tap(find.text("Stop serving").last);
      await tester.pumpAndSettle();
      expect(find.text("Stop serving “SD card”?"), findsOneWidget);
      expect(find.textContaining("Your files are not deleted"), findsOneWidget);
      await tester.tap(find.text("Keep"));
      await tester.pumpAndSettle();

      expect(await repo.getRoot("sd"), isNotNull);
    });

    testWidgets("forgets the location but never touches its files", (WidgetTester tester) async {
      await show(tester);

      await tester.tap(find.text("Stop serving").last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, "Stop serving"));
      await tester.pumpAndSettle();

      expect(await repo.getRoot("sd"), isNull);
      expect(find.text("SD card"), findsNothing);
      expect(find.text("Family files"), findsOneWidget);
    });
  });

  group("adding", () {
    testWidgets("with nothing added the screen invites you to choose a folder", (WidgetTester tester) async {
      await show(tester, roots: InMemoryStorageRootRepository());

      expect(find.text("Nothing is being served yet"), findsOneWidget);
      await tester.tap(find.text("Add storage location"));
      await tester.pumpAndSettle();

      expect(find.text("route:/onboarding/welcome"), findsOneWidget);
    });

    testWidgets("with some added there is still a way to add another", (WidgetTester tester) async {
      await show(tester);

      await tester.tap(find.text("Add storage location"));
      await tester.pumpAndSettle();

      expect(find.text("route:/onboarding/welcome"), findsOneWidget);
    });
  });
}
