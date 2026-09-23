import "dart:io";

import "../../domain/usecases/import_files.dart";
import "../../platform/adapters/android_storage_host.dart";

/// Turns a file the system picker copied into the app cache into an
/// [ImportSource]: streams the cached copy and deletes it when done.
ImportSource importSourceFromPicked(PickedFile picked) {
  return ImportSource(
    name: picked.name,
    sizeBytes: picked.sizeBytes,
    open: () => File(picked.cachePath).openRead(),
    dispose: () => deletePickedCacheFile(picked.cachePath),
  );
}

/// Deletes a picker cache copy (and its per-pick directory once that is empty).
/// Idempotent and never throws: it is called from cleanup paths.
Future<void> deletePickedCacheFile(String cachePath) async {
  final File file = File(cachePath);
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // Best effort.
  }
  try {
    // Non-recursive: only succeeds when the directory is empty.
    await file.parent.delete();
  } on FileSystemException {
    // Other files from the same pick are still there, or it's already gone.
  }
}
