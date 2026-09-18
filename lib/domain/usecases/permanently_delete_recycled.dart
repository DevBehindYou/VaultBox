import "../../core/errors/app_failure.dart";
import "../entities/recycle_item.dart";
import "../entities/storage_root.dart";
import "../models/file_ref.dart";
import "../models/operation_batch.dart";
import "../repositories/file_repository.dart";
import "../repositories/recycle_bin_repository.dart";
import "../repositories/storage_root_repository.dart";

/// `PermanentlyDeleteRecycled` — the explicit, no-going-back step doc §27
/// requires ("Permanent delete requires explicit confirmation"). Removes the
/// recycled bytes from storage and the bookkeeping row together; if the byte
/// delete fails, the metadata row is deliberately left in place rather than
/// removed, so the item doesn't silently disappear from the bin while its
/// bytes are still sitting on disk somewhere the user can no longer see.
final class PermanentlyDeleteRecycled {
  const PermanentlyDeleteRecycled(this._files, this._recycleBin, this._roots);

  final FileRepository _files;
  final RecycleBinRepository _recycleBin;
  final StorageRootRepository _roots;

  Future<OperationBatch> call({required List<String> recycleItemIds}) async {
    final List<ItemOutcome> outcomes = <ItemOutcome>[];

    for (final String id in recycleItemIds) {
      RecycleItem? item;
      try {
        item = await _recycleBin.get(id);
        if (item == null) continue; // already gone — nothing to report

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

        await _files.deletePermanently(FileRef(root: root, path: item.recyclePath));
        await _recycleBin.remove(id);
        outcomes.add(ItemOutcome.completed(source: item.originalPath));
      } on AppFailure catch (failure) {
        outcomes.add(ItemOutcome.failed(source: item!.recyclePath, reason: failure.message));
      }
    }

    return OperationBatch(outcomes: outcomes);
  }
}
