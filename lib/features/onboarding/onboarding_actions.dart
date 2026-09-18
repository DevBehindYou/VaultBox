import "dart:io";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

import "../../app/providers.dart";
import "../../core/errors/app_failure.dart";
import "../../data/services/direct_path_storage_backend.dart";
import "../../domain/entities/storage_root.dart";
import "../../domain/value_objects/storage_capabilities.dart";
import "../../domain/value_objects/storage_path.dart";

/// Phase 1's one real "choose storage" option.
///
/// A full folder picker needs the SAF native bridge (Phase 2 — see
/// docs/IMPLEMENTATION_PLAN.md §F/§G). Until then, the only location VaultBox
/// can honestly offer is its own app-private directory, which Android grants
/// without any special permission — `path_provider` reads it straight from
/// the platform embedder, no plugin-side native code of ours required. This
/// is a real, writable, working root; it just isn't the SD-card-wide access
/// the finished onboarding flow (kickoff §67) describes.
///
/// Returns the created root's id, or throws an [AppFailure] the caller
/// should show via [AuroraInlineBanner] rather than a raw exception (kickoff
/// §71).
Future<String> addAppStorageRoot(WidgetRef ref) async {
  // A dedicated subdirectory, NOT the documents directory itself: that
  // directory also holds vaultbox.sqlite (+ -wal/-shm), and using it as the
  // file root would show the database in the file manager, where a rename or
  // delete could corrupt it (IMPLEMENTATION_PLAN R-18).
  final String path;
  try {
    final Directory documents = await getApplicationDocumentsDirectory();
    final Directory storage = Directory(p.join(documents.path, "storage"));
    await storage.create(recursive: true);
    path = storage.path;
  } on Object catch (error) {
    throw UnexpectedFailure(debugDetail: error.toString());
  }

  const String rootId = "app-storage";
  final DirectPathStorageBackend backend = DirectPathStorageBackend(
    id: rootId,
    rootDirectory: path,
  );

  // Real I/O probe, not just a capability flag — `capabilities()` on this
  // backend is a static const and would "succeed" even against a directory
  // that turns out unwritable. Creating (or confirming) a marker directory
  // actually touches the filesystem, so a permission problem surfaces here
  // rather than on the first real file operation.
  try {
    await backend.createDirectory(StoragePath.parse(rootId, ".vaultbox"));
  } on PathConflictFailure {
    // Already set up from a previous run — fine.
  }

  ref.read(backendRegistryProvider).register(backend);
  await ref.read(storageRootRepositoryProvider).addRoot(
    StorageRoot(
      id: rootId,
      displayName: "This phone",
      backendType: StorageBackendType.direct,
      uriOrPath: path,
      capabilities: const StorageCapabilities.fullLocal(),
      isDefault: true,
    ),
  );

  return rootId;
}
