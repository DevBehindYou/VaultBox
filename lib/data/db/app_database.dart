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

  /// Schema v4. [AccountRole.name]. Rows that existed before v4 are the admin.
  TextColumn get role => text().withDefault(const Constant<String>("admin"))();

  /// Schema v4. A disabled account can't log in.
  BoolColumn get isEnabled => boolean().withDefault(const Constant<bool>(true))();

  /// Schema v4. Bumped on password change / disable; ends existing sessions.
  IntColumn get credentialVersion => integer().withDefault(const Constant<int>(0))();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Schema v4. Folder grants for member accounts (see `AccessRule`).
@DataClassName("AccessRuleRow")
class AccessRules extends Table {
  TextColumn get id => text()();
  TextColumn get accountId => text()();
  TextColumn get rootId => text()();

  /// Normalized folder path; `/` = the whole root.
  TextColumn get pathPrefix => text()();

  /// Comma-separated `Permission.name`s.
  TextColumn get permissions => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Schema v4. Share and upload-request links. Only the token's SHA-256 is kept.
@DataClassName("ShareRow")
class Shares extends Table {
  TextColumn get id => text()();

  /// [ShareKind.name].
  TextColumn get kind => text()();
  TextColumn get rootId => text()();
  TextColumn get path => text()();
  BoolColumn get isDirectory => boolean()();
  TextColumn get createdBy => text()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get tokenHash => text().unique()();
  TextColumn get label => text().nullable()();
  DateTimeColumn get expiresAt => dateTime().nullable()();
  TextColumn get passwordHash => text().nullable()();
  IntColumn get maxUses => integer().nullable()();
  IntColumn get useCount => integer().withDefault(const Constant<int>(0))();
  IntColumn get maxFileBytes => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Schema v5. What happened on the server, one readable sentence each.
@DataClassName("ActivityEventRow")
class ActivityEvents extends Table {
  TextColumn get id => text()();
  DateTimeColumn get occurredAt => dateTime()();

  /// [ActivityKind.name].
  TextColumn get kind => text()();

  /// [ActivitySeverity.name].
  TextColumn get severity => text()();
  TextColumn get message => text()();
  TextColumn get actor => text().nullable()();
  TextColumn get address => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Schema v5. Files moving in or out ([TransferRecord]).
@DataClassName("TransferRow")
class TransferLog extends Table {
  TextColumn get id => text()();

  /// [TransferDirection.name].
  TextColumn get direction => text()();

  /// [AccessVia.name].
  TextColumn get via => text()();
  TextColumn get actor => text()();
  TextColumn get name => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get finishedAt => dateTime().nullable()();
  IntColumn get bytes => integer().withDefault(const Constant<int>(0))();
  IntColumn get totalBytes => integer().nullable()();

  /// [TransferState.name].
  TextColumn get state => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

/// Schema v5. Who has been talking to the server ([ClientRecord]).
@DataClassName("ClientRow")
class ClientSightings extends Table {
  /// `"$actor|$address"`.
  TextColumn get clientKey => text()();
  TextColumn get actor => text()();
  TextColumn get address => text()();

  /// [AccessVia.name].
  TextColumn get via => text()();
  DateTimeColumn get firstSeenAt => dateTime()();
  DateTimeColumn get lastSeenAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{clientKey};
}

/// Schema v6. Small key/value settings (appearance, and later server options).
@DataClassName("AppSettingRow")
class AppSettings extends Table {
  TextColumn get settingKey => text()();
  TextColumn get settingValue => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{settingKey};
}

@DriftDatabase(
  tables: <Type>[
    StorageRoots,
    RecycleItems,
    Accounts,
    AccessRules,
    Shares,
    ActivityEvents,
    TransferLog,
    ClientSightings,
    AppSettings,
  ],
)
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
  int get schemaVersion => 6;

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
      if (from < 4) {
        // v4: member accounts, folder grants and share links. The new account
        // columns have defaults, so the existing (admin) row stays valid.
        await m.addColumn(accounts, accounts.role);
        await m.addColumn(accounts, accounts.isEnabled);
        await m.addColumn(accounts, accounts.credentialVersion);
        await m.createTable(accessRules);
        await m.createTable(shares);
      }
      if (from < 5) {
        // v5: activity (events, transfers, clients) for the Activity tab.
        await m.createTable(activityEvents);
        await m.createTable(transferLog);
        await m.createTable(clientSightings);
      }
      if (from < 6) {
        // v6: key/value settings.
        await m.createTable(appSettings);
      }
    },
    beforeOpen: (OpeningDetails details) async {
      // The UI engine and the server's engine each open this file. Wait briefly
      // for the other one's write instead of failing the request outright.
      await customStatement("PRAGMA busy_timeout = 5000");
    },
  );
}
