import "../../core/errors/app_failure.dart";
import "../entities/storage_root.dart";
import "../models/file_ref.dart";
import "../repositories/clock.dart";
import "../repositories/file_repository.dart";
import "../repositories/storage_backend.dart";
import "../value_objects/storage_path.dart";
import "../value_objects/write_mode.dart";

/// What "Test read/write" found.
final class StorageTestResult {
  const StorageTestResult({required this.ok, required this.message, this.elapsed});

  final bool ok;

  /// A sentence for the person: what worked, or what didn't.
  final String message;
  final Duration? elapsed;
}

/// Checks that a storage location really works: it can be listed and, if it
/// is writable, a small file can be written, read back and removed again. The
/// test file is named clearly and is always cleaned up.
final class TestStorageAccess {
  const TestStorageAccess(this._files, this._clock);

  final FileRepository _files;
  final Clock _clock;

  static const String testFileName = ".vaultbox-write-test.tmp";
  static const List<int> _payload = <int>[0x56, 0x61, 0x75, 0x6C, 0x74, 0x42, 0x6F, 0x78]; // "VaultBox"

  Future<StorageTestResult> call(StorageRoot root) async {
    if (!root.isEnabled) {
      return const StorageTestResult(ok: false, message: "This location is turned off.");
    }
    if (!root.isAvailable) {
      return const StorageTestResult(
        ok: false,
        message: "This location can't be reached right now. If it is a card or drive, plug it back in.",
      );
    }

    final DateTime started = _clock.now();
    try {
      await _files.list(FileRef(root: root, path: StoragePath.root(root.id)), pageSize: 1).take(1).toList();

      if (!root.capabilities.canWrite) {
        return StorageTestResult(
          ok: true,
          message: "Reading works. This location is read-only, so nothing can be added to it.",
          elapsed: _clock.now().difference(started),
        );
      }

      final FileRef target = FileRef(root: root, path: StoragePath.root(root.id).child(testFileName));
      final StorageWriteHandle handle = await _files.openWrite(target, mode: WriteMode.replace);
      try {
        await handle.sink.addStream(Stream<List<int>>.value(_payload));
        await handle.commit();
      } on Object {
        await handle.abort();
        rethrow;
      }

      final List<int> back = <int>[
        for (final List<int> chunk in await _files.openRead(target).toList()) ...chunk,
      ];
      await _files.deletePermanently(target);

      final Duration elapsed = _clock.now().difference(started);
      if (back.length != _payload.length) {
        return StorageTestResult(
          ok: false,
          message: "A test file was written, but what came back didn't match. The storage may be unreliable.",
          elapsed: elapsed,
        );
      }
      return StorageTestResult(ok: true, message: "Reading and writing both work.", elapsed: elapsed);
    } on AppFailure catch (failure) {
      return StorageTestResult(ok: false, message: failure.message);
    } on Object {
      return const StorageTestResult(ok: false, message: "The test couldn't be completed.");
    }
  }
}
