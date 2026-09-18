import "../../core/errors/app_failure.dart";
import "../models/file_ref.dart";
import "../models/operation_batch.dart";
import "../repositories/file_repository.dart";
import "../repositories/storage_backend.dart";
import "../value_objects/storage_path.dart";
import "../value_objects/write_mode.dart";

/// One file to bring into VaultBox, described without any platform types: a
/// name, an optional expected size, and a way to open its bytes as a stream.
class ImportSource {
  const ImportSource({
    required this.name,
    required this.open,
    this.sizeBytes,
    this.dispose,
  });

  /// What the imported file should be called.
  final String name;

  /// Expected size, when known. If given, the import is verified against it.
  final int? sizeBytes;

  /// Opens the bytes. Always streamed — never `readAsBytes()`.
  final Stream<List<int>> Function() open;

  /// Called exactly once when this source has been processed, success or not
  /// (e.g. delete the temporary copy the picker made).
  final Future<void> Function()? dispose;
}

/// `ImportFiles` — write a set of [ImportSource]s into a destination folder.
///
/// Same rules as every other batch operation: one bad file never aborts the
/// rest (ADR-011), conflicts follow the chosen [ConflictPolicy], and the result
/// is one [ItemOutcome] per file.
///
/// Safety: bytes are streamed through the backend's [StorageWriteHandle]
/// (temp -> commit), the written size is checked against the expected size, and
/// a copy that fails verification is removed rather than left looking valid.
/// Keep-both resolves a free name first and then writes in `create` mode, so
/// even a race can never overwrite something.
final class ImportFiles {
  const ImportFiles(this._files);

  final FileRepository _files;

  Future<OperationBatch> call({
    required List<ImportSource> sources,
    required FileRef destinationDirectory,
    required ConflictPolicy conflictPolicy,
  }) async {
    final List<ItemOutcome> outcomes = <ItemOutcome>[];

    for (final ImportSource source in sources) {
      final StoragePath label = _label(destinationDirectory, source.name);
      try {
        outcomes.add(await _importOne(source, destinationDirectory, conflictPolicy, label));
      } finally {
        try {
          await source.dispose?.call();
        } on Object {
          // Cleanup is best-effort; it must never turn a finished import into a failure.
        }
      }
    }

    return OperationBatch(outcomes: outcomes);
  }

  Future<ItemOutcome> _importOne(
    ImportSource source,
    FileRef destination,
    ConflictPolicy policy,
    StoragePath label,
  ) async {
    try {
      FileRef target = FileRef(
        root: destination.root,
        path: destination.path.child(source.name),
      );
      if (policy == ConflictPolicy.keepBoth) {
        final String resolved = await _files.resolveNonConflictingName(destination, source.name);
        target = FileRef(root: destination.root, path: destination.path.child(resolved));
      }
      // Replace overwrites; Skip and (already-resolved) Keep-both must refuse an
      // occupied target, which surfaces below as a conflict outcome.
      final WriteMode mode = policy == ConflictPolicy.replace ? WriteMode.replace : WriteMode.create;

      final StorageWriteHandle handle = await _files.openWrite(target, mode: mode);
      try {
        await handle.sink.addStream(source.open());
        final int written = await handle.commit();
        final int? expected = source.sizeBytes;
        if (expected != null && written != expected) {
          await _files.deletePermanently(target);
          throw const UnexpectedFailure(debugDetail: "import size mismatch");
        }
      } catch (_) {
        await handle.abort(); // no-op if already committed
        rethrow;
      }
      return ItemOutcome.completed(source: label, target: target.path);
    } on PathTraversalRejectedFailure {
      return ItemOutcome.failed(source: label, reason: "This file's name can't be used here");
    } on PathConflictFailure {
      return policy == ConflictPolicy.skip
          ? ItemOutcome.skipped(source: label, reason: "Already exists at destination")
          : ItemOutcome.failed(source: label, reason: "Couldn't resolve naming conflict");
    } on AppFailure catch (failure) {
      return ItemOutcome.failed(source: label, reason: failure.message);
    } on Object {
      // e.g. the source file couldn't be read. Never surface a raw exception string.
      return ItemOutcome.failed(source: label, reason: "Couldn't read this file");
    }
  }

  /// A display-only path for the outcome; an unrepresentable name falls back to
  /// the destination folder rather than throwing.
  StoragePath _label(FileRef destination, String name) {
    try {
      return destination.path.child(name);
    } on AppFailure {
      return destination.path;
    }
  }
}
