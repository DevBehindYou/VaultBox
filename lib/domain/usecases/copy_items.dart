import "../../core/errors/app_failure.dart";
import "../models/file_ref.dart";
import "../models/operation_batch.dart";
import "../repositories/file_repository.dart";
import "../value_objects/write_mode.dart";

/// `CopyItems` — one of the use cases doc §03 calls out by name. Copies each
/// of [sources] into [destinationDirectory], resolving conflicts per
/// [conflictPolicy] and isolating failures per item (ADR-011): one bad file
/// never aborts the rest of the batch.
///
/// The actual temp→verify→commit safety (doc §26 "Data-integrity motto")
/// happens one layer down, inside whichever [StorageWriteHandle] the backend
/// hands back for the write side of the copy — this use case's job is batch
/// orchestration and conflict resolution, not raw I/O safety.
final class CopyItems {
  const CopyItems(this._files);

  final FileRepository _files;

  Future<OperationBatch> call({
    required List<FileRef> sources,
    required FileRef destinationDirectory,
    required ConflictPolicy conflictPolicy,
  }) async {
    final List<ItemOutcome> outcomes = <ItemOutcome>[];

    for (final FileRef source in sources) {
      try {
        final FileRef target = FileRef(
          root: destinationDirectory.root,
          path: destinationDirectory.path.child(source.name),
        );

        final WriteMode mode = switch (conflictPolicy) {
          ConflictPolicy.replace => WriteMode.replace,
          ConflictPolicy.keepBoth => WriteMode.keepBoth,
          ConflictPolicy.skip => WriteMode.create,
        };

        FileRef resolvedTarget = target;
        if (conflictPolicy == ConflictPolicy.keepBoth) {
          final String resolvedName = await _files.resolveNonConflictingName(
            destinationDirectory,
            source.name,
          );
          resolvedTarget = FileRef(
            root: destinationDirectory.root,
            path: destinationDirectory.path.child(resolvedName),
          );
        }

        await _files.copySingle(source, resolvedTarget, mode: mode);
        outcomes.add(ItemOutcome.completed(source: source.path, target: resolvedTarget.path));
      } on PathConflictFailure {
        if (conflictPolicy == ConflictPolicy.skip) {
          outcomes.add(
            ItemOutcome.skipped(source: source.path, reason: "Already exists at destination"),
          );
        } else {
          // Replace/KeepBoth already tried to resolve the conflict above —
          // reaching here means the backend still refused, which is worth
          // surfacing as a failure rather than silently skipping.
          outcomes.add(
            ItemOutcome.failed(source: source.path, reason: "Couldn't resolve naming conflict"),
          );
        }
      } on AppFailure catch (failure) {
        outcomes.add(ItemOutcome.failed(source: source.path, reason: failure.message));
      }
    }

    return OperationBatch(outcomes: outcomes);
  }
}
