import "../entities/storage_root.dart";

/// Owns storage-root metadata (doc §06 `storage_roots` table / EPIC-STORAGE).
/// Persistence-agnostic on purpose — the Phase 1 implementation
/// (`InMemoryStorageRootRepository`) and the eventual Drift-backed one both
/// satisfy this same contract, so nothing above this layer needs to change
/// when persistence lands.
abstract interface class StorageRootRepository {
  /// Reactive root list — ViewModels watch this rather than polling, so a
  /// root going offline (doc §11 "Storage disconnect") propagates to the UI
  /// automatically.
  Stream<List<StorageRoot>> watchRoots();

  Future<List<StorageRoot>> listRoots();

  Future<StorageRoot?> getRoot(String id);

  Future<void> addRoot(StorageRoot root);

  Future<void> updateRoot(StorageRoot root);

  Future<void> removeRoot(String id);

  /// Clears [StorageRoot.isDefault] on every other root first — exactly one
  /// root is ever default.
  Future<void> setDefault(String id);
}
