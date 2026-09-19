import "package:drift/drift.dart";
import "package:drift_flutter/drift_flutter.dart";

part "app_database.g.dart";

/// Doc §06 `storage_roots` table — persisted [StorageRoot] metadata.
///
/// Capabilities are deliberately NOT a column: [StorageCapabilities] is a
/// pure function of [backendType] (see `storage_root_mapper.dart`), and
/// storing a derived value alongside its source invites the two drifting
/// apart across an app update. Recomputing it on read is one cheap constant
/// lookup.
@DataClassName("StorageRootRow")
class StorageRoots extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text()();

  /// [StorageBackendType.name] — mapped back via `.byName()` in the
  /// repository, not a Drift enum column, so the domain enum stays the only
  /// place this vocabulary is defined.
  TextColumn get backendType => text()();
  TextColumn get uriOrPath => text()();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
  BoolColumn get isEnabled => boolean().withDefault(const Constant(true))();
  BoolColumn get isRemovable => boolean().withDefault(const Constant(false))();
  BoolColumn get isAvailable => boolean().withDefault(const Constant(true))();
  IntColumn get freeBytes => integer().nullable()();
  IntColumn get totalBytes => integer().nullable()();

  /// Schema v2. SAF roots only (see StorageRoot.rootDocumentId).
  TextColumn get rootDocumentId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Doc §06 `recycle_items` table — restore metadata for
/// `DeleteItemsToRecycleBin` / `RestoreItems`.
///
/// The recycled bytes themselves already live in normal storage, under
/// `/.vaultbox/recycle/` in the same root they came from (see
/// `delete_items_to_recycle_bin.dart`) — losing this table loses the ability
/// to find your way back to a deleted file's original location, but never
/// loses the file itself.
@DataClassName("RecycleItemRow")
class RecycleItems extends Table {
  TextColumn get id => text()();
  TextColumn get storageRootId => text()();

  /// [StoragePath.normalized] strings — reconstructed via
  /// `StoragePath.parse(storageRootId, ...)` on read, which re-validates them
  /// through the same traversal checks as any other path (doc §42: nothing
  /// gets a free pass just because it came from our own database).
  TextColumn get recyclePath => text()();
  TextColumn get originalPath => text()();
  TextColumn get originalName => text()();
  DateTimeColumn get deletedAt => dateTime()();
  DateTimeColumn get purgeAfter => dateTime().nullable()();
  IntColumn get sizeBytes => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Schema v3. Login accounts. Only the PHC-encoded Argon2id hash is stored.
@DataClassName("AccountRow")
class Accounts extends Table {
  TextColumn get id => text()();

  /// Lower-case (see UsernamePolicy); unique so a name can't be claimed twice.
  TextColumn get username => text().unique()();
  TextColumn get passwordHash => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DriftDatabase(tables: <Type>[StorageRoots, RecycleItems, Accounts])
final class AppDatabase extends _$AppDatabase {
  /// Production use: `AppDatabase()` opens (or creates) the on-device
  /// database. `drift_flutter`'s `driftDatabase()` stores `vaultbox.sqlite`
  /// under `getApplicationDocumentsDirectory()` on native platforms
  /// (confirmed against drift_flutter's own docs, not assumed) — the same
  /// directory onboarding already writes app-storage files into, so both
  /// live under one predictable root during Phase 1.
  ///
  /// Test use: pass an in-memory executor —
  /// `AppDatabase(NativeDatabase.memory())` from `package:drift/native.dart`
  /// — so repository tests never touch the real filesystem (doc §59).
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: "vaultbox"));

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) => m.createAll(),
    onUpgrade: (Migrator m, int from, int to) async {
      if (from < 2) {
        // v2: SAF roots need the tree's root document id. Additive + nullable,
        // so existing rows stay valid. (Not covered by an automated migration
        // test yet — see docs/ai-handover/PENDING_TASKS.md.)
        await m.addColumn(storageRoots, storageRoots.rootDocumentId);
      }
      if (from < 3) {
        // v3: login accounts.
        await m.createTable(accounts);
      }
    },
    beforeOpen: (OpeningDetails details) async {
      // The UI engine and the server's engine each open this file. Wait briefly
      // for the other one's write instead of failing the request outright.
      await customStatement("PRAGMA busy_timeout = 5000");
    },
  );
}
