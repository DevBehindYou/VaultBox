import "../../core/errors/app_failure.dart";
import "../entities/recycle_item.dart";
import "../entities/storage_root.dart";
import "../models/file_ref.dart";
import "../models/operation_batch.dart";
import "../repositories/file_repository.dart";
import "../repositories/recycle_bin_repository.dart";
import "../repositories/storage_root_repository.dart";
import "../value_objects/write_mode.dart";

/// `RestoreItems` — the inverse of [DeleteItemsToRecycleBin]. Copies each
/// recycled item back to its recorded original path, then removes both the
/// recycled copy and its bookkeeping row.
///
/// Same ordering discipline as the move path (doc §26): the recycled copy is
/// only deleted *after* the restore copy has landed. If the original location
/// is now occupied, the item is reported as a conflict rather than silently
/// overwriting whatever the user has since put there.
final class RestoreItems {
  const RestoreItems(this._files, this._recycleBin, this._roots);

  final FileRepository _files;
  final RecycleBinRepository _recycleBin;
  final StorageRootRepository _roots;

  Future<OperationBatch> call({required List<String> recycleItemIds}) async {
    final List<ItemOutcome> outcomes = <ItemOutcome>[];

    for (final String id in recycleItemIds) {
      RecycleItem? item;
      try {
        item = await _recycleBin.get(id);
        if (item == null) {
          continue; // Already restored or purged by another surface — no-op.
        }

        final StorageRoot? root = await _roots.getRoot(item.storageRootId);
        if (root == null) {
          outcomes.add(
            ItemOutcome.failed(
              source: item.recyclePath,
              reason: "The storage location this came from is no longer set up",
            ),
          );
          continue;
        }

        final FileRef from = FileRef(root: root, path: item.recyclePath);
        final FileRef to = FileRef(root: root, path: item.originalPath);

        // WriteMode.create makes the backend reject an occupied destination,
        // which surfaces below as a conflict outcome instead of clobbering.
        await _files.copySingle(from, to, mode: WriteMode.create);
        await _files.deletePermanently(from);
        await _recycleBin.remove(id);

        outcomes.add(ItemOutcome.completed(source: item.recyclePath, target: item.originalPath));
      } on PathConflictFailure {
        outcomes.add(
          ItemOutcome.skipped(
            source: item!.recyclePath,
            reason: "Something else is already at the original location",
          ),
        );
      } on AppFailure catch (failure) {
        outcomes.add(
          ItemOutcome.failed(source: item!.recyclePath, reason: failure.message),
        );
      }
    }

    return OperationBatch(outcomes: outcomes);
  }
}
