import "dart:io";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

import "../../app/providers.dart";
import "../../core/errors/app_failure.dart";
import "../../data/services/direct_path_storage_backend.dart";
import "../../data/services/saf_storage_backend.dart";
import "../../domain/entities/storage_root.dart";
import "../../domain/repositories/id_generator.dart";
import "../../domain/repositories/storage_root_repository.dart";
import "../../domain/value_objects/storage_capabilities.dart";
import "../../domain/value_objects/storage_path.dart";
import "../../platform/adapters/android_storage_host.dart";

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

/// "SD card or custom folder": opens the system folder picker (SAF), takes a
/// persistable grant, proves the folder is writable, and registers it as a
/// storage root. Returns the new (or already-registered) root's id, or `null`
/// if the person cancelled the picker.
///
/// Thin wrapper so widgets stay simple; the logic lives in [registerSafRoot],
/// which takes its dependencies explicitly and is unit-tested with fakes.
Future<String?> addSafStorageRoot(WidgetRef ref) {
  return registerSafRoot(
    host: ref.read(androidStorageHostProvider),
    registry: ref.read(backendRegistryProvider),
    roots: ref.read(storageRootRepositoryProvider),
    ids: ref.read(idGeneratorProvider),
  );
}

Future<String?> registerSafRoot({
  required AndroidStorageHost host,
  required BackendRegistry registry,
  required StorageRootRepository roots,
  required IdGenerator ids,
}) async {
  final SafTreeInfo? tree = await host.openDocumentTree();
  if (tree == null) return null; // cancelled

  final List<StorageRoot> existing = await roots.listRoots();
  for (final StorageRoot root in existing) {
    // Picking the same folder twice must not create a duplicate root.
    if (root.backendType == StorageBackendType.saf && root.uriOrPath == tree.treeUri) {
      return root.id;
    }
  }

  final String rootId = "saf-${ids.newId()}";
  final SafStorageBackend backend = SafStorageBackend(
    id: rootId,
    host: host,
    treeUri: tree.treeUri,
    rootDocumentId: tree.rootDocumentId,
  );

  // Real write probe (same idea as the app-storage root): creating VaultBox's
  // hidden bookkeeping directory (the Recycle Bin lives in it) proves the grant
  // is usable NOW, rather than failing on the first real file operation.
  try {
    await backend.createDirectory(StoragePath.parse(rootId, ".vaultbox"));
  } on PathConflictFailure {
    // Already set up in this folder — fine.
  } on AppFailure {
    // The grant was persisted by the picker; don't leave a useless one behind.
    await host.releasePersistedUri(tree.treeUri);
    rethrow;
  }

  registry.register(backend);
  await roots.addRoot(
    StorageRoot(
      id: rootId,
      displayName: tree.displayName,
      backendType: StorageBackendType.saf,
      uriOrPath: tree.treeUri,
      rootDocumentId: tree.rootDocumentId,
      capabilities: const StorageCapabilities.saf(),
      // Only the first root becomes the default; adding a second must not
      // silently change where the Files tab opens.
      isDefault: !existing.any((StorageRoot r) => r.isDefault),
    ),
  );
  return rootId;
}
