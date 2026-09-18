import "../entities/recycle_item.dart";

/// Recycle Bin metadata (doc §06 `recycle_items`). Separate from
/// [FileRepository] / [StorageBackend] because this is bookkeeping data
/// (Drift-backed once codegen runs), not file bytes — mirrors the doc's own
/// separation between "files live in storage, metadata lives in SQLite"
/// (§06 "Principle").
abstract interface class RecycleBinRepository {
  Stream<List<RecycleItem>> watchItems(String storageRootId);

  Future<List<RecycleItem>> listItems(String storageRootId);

  Future<void> add(RecycleItem item);

  Future<RecycleItem?> get(String id);

  Future<void> remove(String id);
}
