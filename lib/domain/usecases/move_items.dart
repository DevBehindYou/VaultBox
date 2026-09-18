import "../../core/errors/app_failure.dart";
import "../models/file_ref.dart";
import "../models/operation_batch.dart";
import "../repositories/file_repository.dart";
import "../value_objects/write_mode.dart";

/// `MoveItems` — doc §11 "Generic move": *"If safe backend-native move
/// exists: move. Otherwise: copy → verify → delete source. Never delete
/// source first."*
///
/// This implementation always takes the copy→verify→delete path via
/// [FileRepository.copySingle] + [FileRepository.deletePermanently]. A
/// same-backend native-rename fast path (skipping the byte copy entirely
/// when source and target share one backend) is a valid later optimization
/// — kickoff §74 treats "can this stream / can this avoid I/O" as an
/// ongoing question, not a Phase-1 blocker — but correctness (never losing
/// data, never deleting before the copy is confirmed) matters more than that
/// optimization for this delivery.
final class MoveItems {
  const MoveItems(this._files);

  final FileRepository _files;

  Future<OperationBatch> call({
    required List<FileRef> sources,
    required FileRef destinationDirectory,
    required ConflictPolicy conflictPolicy,
  }) async {
    final List<ItemOutcome> outcomes = <ItemOutcome>[];

    for (final FileRef source in sources) {
      try {
        final WriteMode mode = switch (conflictPolicy) {
          ConflictPolicy.replace => WriteMode.replace,
          ConflictPolicy.keepBoth => WriteMode.keepBoth,
          ConflictPolicy.skip => WriteMode.create,
        };

        FileRef target = FileRef(
          root: destinationDirectory.root,
          path: destinationDirectory.path.child(source.name),
        );
        if (conflictPolicy == ConflictPolicy.keepBoth) {
          final String resolvedName = await _files.resolveNonConflictingName(
            destinationDirectory,
            source.name,
          );
          target = FileRef(root: destinationDirectory.root, path: destinationDirectory.path.child(resolvedName));
        }

        // Step 1: copy. The backend's write handle is responsible for its
        // own temp-file safety internally; from this use case's point of
        // view, a successful `copySingle` return means "verified at the
        // destination" (§26 motto).
        await _files.copySingle(source, target, mode: mode);

        // Step 2: only now delete the source — never before step 1 confirmed.
        await _files.deletePermanently(source);

        outcomes.add(ItemOutcome.completed(source: source.path, target: target.path));
      } on PathConflictFailure {
        if (conflictPolicy == ConflictPolicy.skip) {
          outcomes.add(
            ItemOutcome.skipped(source: source.path, reason: "Already exists at destination"),
          );
        } else {
          outcomes.add(
            ItemOutcome.failed(source: source.path, reason: "Couldn't resolve naming conflict"),
          );
        }
      } on AppFailure catch (failure) {
        // Note: if the copy step itself throws, we never reach the delete —
        // the source is guaranteed intact. If delete throws *after* a
        // successful copy, the item is reported failed even though a copy
        // now exists at the destination; surfacing that clearly (rather than
        // silently leaving a duplicate) is preferable to guessing intent.
        outcomes.add(ItemOutcome.failed(source: source.path, reason: failure.message));
      }
    }

    return OperationBatch(outcomes: outcomes);
  }
}
