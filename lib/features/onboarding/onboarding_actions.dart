import "dart:io";

import "package:flutter/widgets.dart";
import "package:flutter_bloc/flutter_bloc.dart";

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

/// "This phone" storage: a folder under the public Downloads directory
/// (`/storage/emulated/0/Download/Atomic-Carton`), so it shows up in any file
/// manager — not the app-private directory scoped storage otherwise confines
/// raw `dart:io` File access to, which several phones hide from their own
/// file manager without root.
///
/// Reaching a public directory with plain File I/O needs "All files access"
/// on Android 11+ (`MANAGE_EXTERNAL_STORAGE`) — Android only grants that
/// through a system settings screen, never an in-app dialog. When it's
/// missing this opens that screen and throws [StoragePermissionRequiredFailure]
/// rather than silently falling back to the old hidden location; the person
/// re-taps "This phone" once they've granted it.
///
/// Returns the created root's id, or throws an [AppFailure] the caller
/// should show via [AuroraInlineBanner] rather than a raw exception (kickoff
/// §71).
Future<String> addAppStorageRoot(BuildContext context) async {
  final AndroidStorageHost host = context.read<AndroidStorageHost>();

  final bool hasAccess;
  try {
    hasAccess = await host.hasManageExternalStoragePermission();
  } on AppFailure {
    rethrow;
  } on Object catch (error) {
    throw UnexpectedFailure(debugDetail: error.toString());
  }

  if (!hasAccess) {
    await host.requestManageExternalStoragePermission();
    throw const StoragePermissionRequiredFailure();
  }

  const String path = "/storage/emulated/0/Download/Atomic-Carton";
  try {
    await Directory(path).create(recursive: true);
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

  context.read<BackendRegistry>().register(backend);
  await context.read<StorageRootRepository>().addRoot(
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
Future<String?> addSafStorageRoot(BuildContext context) {
  return registerSafRoot(
    host: context.read<AndroidStorageHost>(),
    registry: context.read<BackendRegistry>(),
    roots: context.read<StorageRootRepository>(),
    ids: context.read<IdGenerator>(),
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
