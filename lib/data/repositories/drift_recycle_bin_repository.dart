import "package:drift/drift.dart";

import "../../domain/entities/recycle_item.dart";
import "../../domain/repositories/recycle_bin_repository.dart";
import "../../domain/value_objects/storage_path.dart";
import "../db/app_database.dart";

/// Live [RecycleBinRepository] — replaces `InMemoryRecycleBinRepository` as
/// the default. This is the fix for the gap flagged in
/// docs/IMPLEMENTATION_PLAN.md §H (R-1 / "works in a session ≠ works"):
/// restore metadata now survives a process restart, matching the recycled
/// bytes themselves, which were always safe on disk.
final class DriftRecycleBinRepository implements RecycleBinRepository {
  const DriftRecycleBinRepository(this._db);

  final AppDatabase _db;

  @override
  Stream<List<RecycleItem>> watchItems(String storageRootId) {
    return (_db.select(_db.recycleItems)
          ..where((RecycleItems tbl) => tbl.storageRootId.equals(storageRootId))
          ..orderBy([(RecycleItems tbl) => OrderingTerm.desc(tbl.deletedAt)]))
        .watch()
        .map((List<RecycleItemRow> rows) => rows.map(_toEntity).toList());
  }

  @override
  Future<List<RecycleItem>> listItems(String storageRootId) async {
    final List<RecycleItemRow> rows = await (_db.select(_db.recycleItems)
          ..where((RecycleItems tbl) => tbl.storageRootId.equals(storageRootId))
          ..orderBy([(RecycleItems tbl) => OrderingTerm.desc(tbl.deletedAt)]))
        .get();
    return rows.map(_toEntity).toList();
  }

  @override
  Future<void> add(RecycleItem item) async {
    await _db.into(_db.recycleItems).insertOnConflictUpdate(_toCompanion(item));
  }

  @override
  Future<RecycleItem?> get(String id) async {
    final RecycleItemRow? row = await (_db.select(
      _db.recycleItems,
    )..where((RecycleItems tbl) => tbl.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toEntity(row);
  }

  @override
  Future<void> remove(String id) async {
    await (_db.delete(
      _db.recycleItems,
    )..where((RecycleItems tbl) => tbl.id.equals(id))).go();
  }

  RecycleItem _toEntity(RecycleItemRow row) {
    return RecycleItem(
      id: row.id,
      storageRootId: row.storageRootId,
      // Re-parsed, not trusted verbatim — doc §42's traversal checks apply
      // to a path coming out of our own database exactly as they do to one
      // coming off the wire.
      recyclePath: StoragePath.parse(row.storageRootId, row.recyclePath),
      originalPath: StoragePath.parse(row.storageRootId, row.originalPath),
      originalName: row.originalName,
      deletedAt: row.deletedAt,
      purgeAfter: row.purgeAfter,
      sizeBytes: row.sizeBytes,
    );
  }

  RecycleItemsCompanion _toCompanion(RecycleItem item) {
    return RecycleItemsCompanion(
      id: Value<String>(item.id),
      storageRootId: Value<String>(item.storageRootId),
      recyclePath: Value<String>(item.recyclePath.normalized),
      originalPath: Value<String>(item.originalPath.normalized),
      originalName: Value<String>(item.originalName),
      deletedAt: Value<DateTime>(item.deletedAt),
      purgeAfter: Value<DateTime?>(item.purgeAfter),
      sizeBytes: Value<int?>(item.sizeBytes),
    );
  }
}
