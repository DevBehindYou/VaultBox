import "package:drift/drift.dart";

import "../../domain/entities/storage_root.dart";
import "../../domain/repositories/storage_root_repository.dart";
import "../../domain/value_objects/storage_capabilities.dart";
import "../db/app_database.dart";

/// Live [StorageRootRepository] — replaces
/// `InMemoryStorageRootRepository` as the default (see `app/providers.dart`).
/// Every method is a thin, direct translation to/from [StorageRootRow]; the
/// only real logic here is [_capabilitiesFor], and even that is a constant
/// lookup, not a computation.
final class DriftStorageRootRepository implements StorageRootRepository {
  const DriftStorageRootRepository(this._db);

  final AppDatabase _db;

  @override
  Stream<List<StorageRoot>> watchRoots() {
    return _db.select(_db.storageRoots).watch().map(
      (List<StorageRootRow> rows) => rows.map(_toEntity).toList(),
    );
  }

  @override
  Future<List<StorageRoot>> listRoots() async {
    final List<StorageRootRow> rows = await _db.select(_db.storageRoots).get();
    return rows.map(_toEntity).toList();
  }

  @override
  Future<StorageRoot?> getRoot(String id) async {
    final StorageRootRow? row = await (_db.select(
      _db.storageRoots,
    )..where((StorageRoots tbl) => tbl.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toEntity(row);
  }

  @override
  Future<void> addRoot(StorageRoot root) async {
    await _db.into(_db.storageRoots).insertOnConflictUpdate(_toCompanion(root));
  }

  @override
  Future<void> updateRoot(StorageRoot root) async {
    await (_db.update(
      _db.storageRoots,
    )..where((StorageRoots tbl) => tbl.id.equals(root.id))).write(_toCompanion(root));
  }

  @override
  Future<void> removeRoot(String id) async {
    await (_db.delete(
      _db.storageRoots,
    )..where((StorageRoots tbl) => tbl.id.equals(id))).go();
  }

  @override
  Future<void> setDefault(String id) async {
    // Two-statement, one transaction: clear every row's flag, then set the
    // chosen one. Simpler and easier to prove correct than trying to express
    // "everyone except id" as a single WHERE clause, and the transaction
    // keeps a concurrent reader from ever observing zero or two defaults.
    await _db.transaction(() async {
      await _db
          .update(_db.storageRoots)
          .write(const StorageRootsCompanion(isDefault: Value<bool>(false)));
      await (_db.update(_db.storageRoots)..where((StorageRoots tbl) => tbl.id.equals(id)))
          .write(const StorageRootsCompanion(isDefault: Value<bool>(true)));
    });
  }

  StorageRoot _toEntity(StorageRootRow row) {
    final StorageBackendType type = StorageBackendType.values.byName(row.backendType);
    return StorageRoot(
      id: row.id,
      displayName: row.displayName,
      backendType: type,
      uriOrPath: row.uriOrPath,
      capabilities: _capabilitiesFor(type),
      isDefault: row.isDefault,
      isEnabled: row.isEnabled,
      isRemovable: row.isRemovable,
      isAvailable: row.isAvailable,
      freeBytes: row.freeBytes,
      totalBytes: row.totalBytes,
    );
  }

  StorageRootsCompanion _toCompanion(StorageRoot root) {
    return StorageRootsCompanion(
      id: Value<String>(root.id),
      displayName: Value<String>(root.displayName),
      backendType: Value<String>(root.backendType.name),
      uriOrPath: Value<String>(root.uriOrPath),
      isDefault: Value<bool>(root.isDefault),
      isEnabled: Value<bool>(root.isEnabled),
      isRemovable: Value<bool>(root.isRemovable),
      isAvailable: Value<bool>(root.isAvailable),
      freeBytes: Value<int?>(root.freeBytes),
      totalBytes: Value<int?>(root.totalBytes),
    );
  }

  /// Every backend type currently behaves as full local read/write from the
  /// domain's point of view — SAF's real, narrower constraints (Phase 2) get
  /// their own case here once the native bridge exists and actually reports
  /// them, rather than guessing ahead of that work.
  StorageCapabilities _capabilitiesFor(StorageBackendType type) {
    return const StorageCapabilities.fullLocal();
  }
}
