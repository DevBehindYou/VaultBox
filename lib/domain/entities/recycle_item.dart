import "../value_objects/storage_path.dart";

/// Doc §06 `recycle_items` table, domain shape. One entry per deleted item —
/// created by `DeleteItemsToRecycleBin`, consumed by `RestoreItems` (restore)
/// or the Recycle Bin's own purge sweep (permanent delete after
/// [purgeAfter]).
final class RecycleItem {
  const RecycleItem({
    required this.id,
    required this.storageRootId,
    required this.recyclePath,
    required this.originalPath,
    required this.originalName,
    required this.deletedAt,
    this.purgeAfter,
    this.sizeBytes,
  });

  final String id;
  final String storageRootId;

  /// Where the bytes actually live right now, inside the same root's
  /// managed recycle location (doc §11: "Prefer per-root managed location").
  final StoragePath recyclePath;

  /// Where it should go back to on restore.
  final StoragePath originalPath;
  final String originalName;
  final DateTime deletedAt;
  final DateTime? purgeAfter;
  final int? sizeBytes;
}
