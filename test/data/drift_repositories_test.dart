import "dart:async";

import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/db/app_database.dart";
import "package:vaultbox/data/repositories/drift_account_repository.dart";
import "package:vaultbox/data/repositories/drift_recycle_bin_repository.dart";
import "package:vaultbox/data/repositories/drift_storage_root_repository.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/recycle_item.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";

/// Runs the Drift repositories against `NativeDatabase.memory()` — a real
/// sqlite engine, in memory, per test (doc §59: exercise the real
/// persistence code path, just not against the real device file). This is
/// the test that actually proves the fix for the gap flagged in
/// docs/IMPLEMENTATION_PLAN.md §H: a root or a recycle entry written here
/// must come back identical after being read through the same round-trip a
/// process restart would force it through (row → entity → row).
///
/// `flutter test` runs these on the host machine, not a device, so
/// `NativeDatabase` needs a resolvable libsqlite3 on that host. This is
/// usually present out of the box on macOS; on Linux it may need
/// `libsqlite3-dev` (or equivalent) installed. If this file fails to even
/// load the library rather than failing an assertion, that's the symptom —
/// not a bug in the repository code itself.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  group("DriftStorageRootRepository", () {
    late DriftStorageRootRepository repo;
    setUp(() => repo = DriftStorageRootRepository(db));

    const StorageRoot root = StorageRoot(
      id: "root-1",
      displayName: "This phone",
      backendType: StorageBackendType.direct,
      uriOrPath: "/data/user/0/com.vaultbox.app/files",
      capabilities: StorageCapabilities.fullLocal(),
      isDefault: true,
      freeBytes: 125200000000,
      totalBytes: 228000000000,
    );

    test("round-trips every field, including nullable byte counts", () async {
      await repo.addRoot(root);
      final StorageRoot? loaded = await repo.getRoot("root-1");

      expect(loaded, isNotNull);
      expect(loaded!.displayName, "This phone");
      expect(loaded.backendType, StorageBackendType.direct);
      expect(loaded.uriOrPath, root.uriOrPath);
      expect(loaded.isDefault, isTrue);
      expect(loaded.freeBytes, 125200000000);
      expect(loaded.totalBytes, 228000000000);
    });

    test("a SAF root round-trips its root document id and gets SAF capabilities", () async {
      await repo.addRoot(
        const StorageRoot(
          id: "saf-1",
          displayName: "SD card",
          backendType: StorageBackendType.saf,
          uriOrPath: "content://com.android.externalstorage.documents/tree/1234-ABCD%3A",
          rootDocumentId: "1234-ABCD:",
          capabilities: StorageCapabilities.saf(),
        ),
      );

      final StorageRoot? loaded = await repo.getRoot("saf-1");
      expect(loaded, isNotNull);
      expect(loaded!.rootDocumentId, "1234-ABCD:");
      expect(loaded.backendType, StorageBackendType.saf);
      expect(loaded.capabilities.canMoveWithinBackend, isFalse);
      expect(loaded.capabilities.supportsAtomicReplace, isFalse);
    });

    test("a non-SAF root has no root document id and full local capabilities", () async {
      await repo.addRoot(root);
      final StorageRoot? loaded = await repo.getRoot("root-1");
      expect(loaded!.rootDocumentId, isNull);
      expect(loaded.capabilities.canMoveWithinBackend, isTrue);
    });

    test("getRoot returns null for an id that was never added", () async {
      expect(await repo.getRoot("nope"), isNull);
    });

    test("setDefault clears every other root's flag", () async {
      await repo.addRoot(root);
      await repo.addRoot(
        const StorageRoot(
          id: "root-2",
          displayName: "SD card",
          backendType: StorageBackendType.direct,
          uriOrPath: "/storage/sdcard1",
          capabilities: StorageCapabilities.fullLocal(),
        ),
      );

      await repo.setDefault("root-2");

      final List<StorageRoot> all = await repo.listRoots();
      final Map<String, bool> defaults = <String, bool>{
        for (final StorageRoot r in all) r.id: r.isDefault,
      };
      expect(defaults, <String, bool>{"root-1": false, "root-2": true});
    });

    test("removeRoot deletes it", () async {
      await repo.addRoot(root);
      await repo.removeRoot("root-1");
      expect(await repo.getRoot("root-1"), isNull);
    });

    test("watchRoots emits on every mutation", () async {
      final List<int> counts = <int>[];
      final StreamSubscription<List<StorageRoot>> sub = repo.watchRoots().listen(
        (List<StorageRoot> roots) => counts.add(roots.length),
      );

      await pumpEventQueue();
      await repo.addRoot(root);
      await pumpEventQueue();
      await repo.removeRoot("root-1");
      await pumpEventQueue();

      await sub.cancel();
      expect(counts, <int>[0, 1, 0]);
    });
  });

  group("DriftRecycleBinRepository", () {
    late DriftRecycleBinRepository repo;
    setUp(() => repo = DriftRecycleBinRepository(db));

    final RecycleItem item = RecycleItem(
      id: "recycle-1",
      storageRootId: "root-1",
      recyclePath: StoragePath.parse("root-1", ".vaultbox/recycle/recycle-1__photo.jpg"),
      originalPath: StoragePath.parse("root-1", "DCIM/photo.jpg"),
      originalName: "photo.jpg",
      deletedAt: DateTime.utc(2026, 9, 16, 12, 0),
      purgeAfter: DateTime.utc(2026, 10, 16, 12, 0),
      sizeBytes: 4200000,
    );

    test("round-trips paths through StoragePath.parse correctly", () async {
      await repo.add(item);
      final RecycleItem? loaded = await repo.get("recycle-1");

      expect(loaded, isNotNull);
      expect(loaded!.recyclePath.normalized, "/.vaultbox/recycle/recycle-1__photo.jpg");
      expect(loaded.originalPath.normalized, "/DCIM/photo.jpg");
      expect(loaded.originalName, "photo.jpg");
      // Drift hands back local DateTimes; DateTime == also compares isUtc, so compare the instant.
      expect(loaded.deletedAt.isAtSameMomentAs(item.deletedAt), isTrue);
      expect(loaded.purgeAfter!.isAtSameMomentAs(item.purgeAfter!), isTrue);
      expect(loaded.sizeBytes, 4200000);
    });

    test("listItems only returns items for the requested root, newest first", () async {
      await repo.add(item);
      await repo.add(
        RecycleItem(
          id: "recycle-2",
          storageRootId: "root-1",
          recyclePath: StoragePath.parse("root-1", ".vaultbox/recycle/recycle-2__note.txt"),
          originalPath: StoragePath.parse("root-1", "note.txt"),
          originalName: "note.txt",
          deletedAt: DateTime.utc(2026, 9, 17),
        ),
      );
      await repo.add(
        RecycleItem(
          id: "recycle-3",
          storageRootId: "root-2",
          recyclePath: StoragePath.parse("root-2", ".vaultbox/recycle/recycle-3__x.txt"),
          originalPath: StoragePath.parse("root-2", "x.txt"),
          originalName: "x.txt",
          deletedAt: DateTime.utc(2026, 9, 17),
        ),
      );

      final List<RecycleItem> items = await repo.listItems("root-1");
      expect(items.map((RecycleItem i) => i.id).toList(), <String>["recycle-2", "recycle-1"]);
    });

    test("remove deletes the metadata row", () async {
      await repo.add(item);
      await repo.remove("recycle-1");
      expect(await repo.get("recycle-1"), isNull);
    });
  });

  group("DriftAccountRepository", () {
    late DriftAccountRepository repo;
    setUp(() => repo = DriftAccountRepository(db));

    Account account(String id, String name) =>
        Account(id: id, username: name, passwordHash: r"$argon2id$stub", createdAt: DateTime.utc(2026, 9, 19));

    test("createFirst stores the first account and refuses every later one", () async {
      expect(await repo.count(), 0);
      expect(await repo.createFirst(account("a1", "admin")), isNotNull);
      expect(await repo.createFirst(account("a2", "other")), isNull);
      expect(await repo.count(), 1);
      expect(await repo.findByUsername("other"), isNull, reason: "the refused account was not stored");
    });

    test("findByUsername round-trips every field", () async {
      await repo.createFirst(account("a1", "admin"));
      final Account? loaded = await repo.findByUsername("admin");

      expect(loaded, isNotNull);
      expect(loaded!.id, "a1");
      expect(loaded.passwordHash, r"$argon2id$stub");
      expect(loaded.createdAt.isAtSameMomentAs(DateTime.utc(2026, 9, 19)), isTrue);
      expect(await repo.findByUsername("nobody"), isNull);
    });

    test("updatePasswordHash replaces only the hash", () async {
      await repo.createFirst(account("a1", "admin"));
      await repo.updatePasswordHash("a1", r"$argon2id$upgraded");

      final Account? loaded = await repo.findByUsername("admin");
      expect(loaded!.passwordHash, r"$argon2id$upgraded");
      expect(loaded.username, "admin");
    });
  });
}
