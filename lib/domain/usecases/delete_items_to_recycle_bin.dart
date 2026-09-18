import "../../core/errors/app_failure.dart";
import "../entities/recycle_item.dart";
import "../entities/storage_root.dart";
import "../models/file_ref.dart";
import "../models/operation_batch.dart";
import "../repositories/clock.dart";
import "../repositories/file_repository.dart";
import "../repositories/id_generator.dart";
import "../repositories/recycle_bin_repository.dart";
import "../value_objects/storage_path.dart";
import "../value_objects/write_mode.dart";

/// `DeleteItemsToRecycleBin` — the default delete path (ADR-012: "Recycle
/// Bin by default. Permanent deletion is explicit."). Moves each item into a
/// per-root managed recycle location (doc §11) and records restore metadata;
/// never calls [FileRepository.deletePermanently] itself.
///
/// Recycle location convention: `/.vaultbox/recycle/<recycleItemId>__<name>`
/// within the *same root* as the source, so a same-root rename-based move
/// stays cheap and the item never has to cross backends to be "deleted".
final class DeleteItemsToRecycleBin {
  const DeleteItemsToRecycleBin(this._files, this._recycleBin, this._clock, this._ids);

  final FileRepository _files;
  final RecycleBinRepository _recycleBin;
  final Clock _clock;
  final IdGenerator _ids;

  static const List<String> _recycleDirSegments = <String>[".vaultbox", "recycle"];
  static const Duration _defaultRetention = Duration(days: 30);

  Future<OperationBatch> call({required List<FileRef> sources}) async {
    final List<ItemOutcome> outcomes = <ItemOutcome>[];

    for (final FileRef source in sources) {
      try {
        final String itemId = _ids.newId();
        final String recycleFileName = "${itemId}__${source.name}";

        final StoragePath recycleDir = await _ensureRecycleDirectory(source.root);
        final StoragePath recyclePath = recycleDir.child(recycleFileName);
        final FileRef recycleRef = FileRef(root: source.root, path: recyclePath);

        await _files.copySingle(source, recycleRef, mode: WriteMode.create);
        await _files.deletePermanently(source);

        final DateTime deletedAt = _clock.now();
        await _recycleBin.add(
          RecycleItem(
            id: itemId,
            storageRootId: source.root.id,
            recyclePath: recyclePath,
            originalPath: source.path,
            originalName: source.name,
            deletedAt: deletedAt,
            purgeAfter: deletedAt.add(_defaultRetention),
          ),
        );

        outcomes.add(ItemOutcome.completed(source: source.path, target: recyclePath));
      } on AppFailure catch (failure) {
        outcomes.add(ItemOutcome.failed(source: source.path, reason: failure.message));
      }
    }

    return OperationBatch(outcomes: outcomes);
  }

  /// Walks `/.vaultbox/recycle` from the root, creating each segment if
  /// missing. `createDirectory` on an existing name throws
  /// [PathConflictFailure] (FR-FIL-002 expects normal "create folder" calls
  /// to reject duplicates) — here that failure means "already there", which
  /// is exactly what idempotent `mkdir -p`-style plumbing wants, so it's
  /// caught and treated as success rather than propagated.
  Future<StoragePath> _ensureRecycleDirectory(StorageRoot root) async {
    StoragePath current = StoragePath.root(root.id);
    for (final String segment in _recycleDirSegments) {
      final FileRef parentRef = FileRef(root: root, path: current);
      try {
        await _files.createDirectory(parentRef, segment);
      } on PathConflictFailure {
        // Already exists — fine.
      }
      current = current.child(segment);
    }
    return current;
  }
}
