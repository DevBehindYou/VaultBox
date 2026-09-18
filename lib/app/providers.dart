import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../data/db/app_database.dart";
import "../data/repositories/drift_recycle_bin_repository.dart";
import "../data/repositories/drift_storage_root_repository.dart";
import "../data/repositories/file_repository_impl.dart";
import "../data/services/direct_path_storage_backend.dart";
import "../data/services/memory_storage_backend.dart";
import "../data/services/system_clock.dart";
import "../domain/entities/recycle_item.dart";
import "../domain/entities/storage_root.dart";
import "../domain/repositories/clock.dart";
import "../domain/repositories/file_repository.dart";
import "../domain/repositories/id_generator.dart";
import "../domain/repositories/recycle_bin_repository.dart";
import "../domain/repositories/storage_backend.dart";
import "../domain/repositories/storage_root_repository.dart";
import "../domain/usecases/copy_items.dart";
import "../domain/usecases/delete_items_to_recycle_bin.dart";
import "../domain/usecases/move_items.dart";
import "../domain/usecases/permanently_delete_recycled.dart";
import "../domain/usecases/restore_items.dart";

/// Composition root for the storage/file layer.
///
/// Manual (non-codegen) providers on purpose — see
/// docs/IMPLEMENTATION_PLAN.md §E. Every one of these is overridable in tests
/// via `ProviderScope(overrides: [...])` / `ProviderContainer(overrides:)`,
/// which is how the Files UI gets a [MemoryStorageBackend] without touching
/// device storage (doc §59).

// --- Services ---

final Provider<Clock> clockProvider = Provider<Clock>((Ref ref) => const SystemClock());

final Provider<IdGenerator> idGeneratorProvider =
    Provider<IdGenerator>((Ref ref) => UuidIdGenerator());

// --- Backend registry ---

/// Live [StorageBackend] instances, keyed by root id.
///
/// Backends are cached per root rather than rebuilt per call: a backend can
/// hold open handles and caches, and rebuilding one mid-operation would be a
/// correctness bug, not just a performance one.
final class BackendRegistry {
  BackendRegistry();

  final Map<String, StorageBackend> _backends = <String, StorageBackend>{};

  StorageBackend forRoot(StorageRoot root) {
    return _backends.putIfAbsent(root.id, () => _create(root));
  }

  /// Registers a pre-built backend — used by tests and by onboarding, which
  /// constructs a backend as part of validating a chosen location before the
  /// root is committed.
  void register(StorageBackend backend) {
    _backends[backend.id] = backend;
  }

  void evict(String rootId) => _backends.remove(rootId);

  StorageBackend _create(StorageRoot root) {
    return switch (root.backendType) {
      StorageBackendType.direct => DirectPathStorageBackend(
        id: root.id,
        rootDirectory: root.uriOrPath,
      ),
      StorageBackendType.memory => MemoryStorageBackend(id: root.id),
      // SafStorageBackend itself is fully implemented
      // (lib/data/services/saf_storage_backend.dart) and unit-tested against
      // a fake host — what's still missing is the concrete
      // AndroidStorageHost wired to real Pigeon-generated code
      // (pigeons/storage_api.dart has the spec; the Kotlin implementation
      // draft is at android/.../storage/SafStorageHostApi.kt). Both need
      // `dart run pigeon` to have actually run, which needs `flutter
      // create .` to have run first — see README.md. Throwing loudly here
      // beats returning a silently-wrong backend that appears to work and
      // loses data.
      StorageBackendType.saf => throw UnimplementedError(
        "SafStorageBackend needs its native AndroidStorageHost wired up — "
        "see README.md",
      ),
      StorageBackendType.vault => throw UnimplementedError(
        "VaultStorageBackend is Phase 8",
      ),
    };
  }
}

final Provider<BackendRegistry> backendRegistryProvider =
    Provider<BackendRegistry>((Ref ref) => BackendRegistry());

// --- Persistence ---

/// One [AppDatabase] instance for the whole app — both repositories below
/// share it rather than each opening their own connection.
final Provider<AppDatabase> appDatabaseProvider = Provider<AppDatabase>((Ref ref) {
  final AppDatabase database = AppDatabase();
  ref.onDispose(() => unawaited(database.close()));
  return database;
});

// --- Repositories ---

final Provider<StorageRootRepository> storageRootRepositoryProvider =
    Provider<StorageRootRepository>((Ref ref) {
      return DriftStorageRootRepository(ref.watch(appDatabaseProvider));
    });

final Provider<RecycleBinRepository> recycleBinRepositoryProvider =
    Provider<RecycleBinRepository>((Ref ref) {
      return DriftRecycleBinRepository(ref.watch(appDatabaseProvider));
    });

final Provider<FileRepository> fileRepositoryProvider = Provider<FileRepository>((Ref ref) {
  final BackendRegistry registry = ref.watch(backendRegistryProvider);
  return FileRepositoryImpl(resolveBackend: registry.forRoot);
});

/// Reactive root list. ViewModels watch this rather than polling, so a
/// removable root going offline propagates automatically (doc §11).
final StreamProvider<List<StorageRoot>> storageRootsProvider =
    StreamProvider<List<StorageRoot>>((Ref ref) {
      return ref.watch(storageRootRepositoryProvider).watchRoots();
    });

// --- Use cases ---

final Provider<CopyItems> copyItemsProvider =
    Provider<CopyItems>((Ref ref) => CopyItems(ref.watch(fileRepositoryProvider)));

final Provider<MoveItems> moveItemsProvider =
    Provider<MoveItems>((Ref ref) => MoveItems(ref.watch(fileRepositoryProvider)));

final Provider<DeleteItemsToRecycleBin> deleteItemsProvider =
    Provider<DeleteItemsToRecycleBin>((Ref ref) {
      return DeleteItemsToRecycleBin(
        ref.watch(fileRepositoryProvider),
        ref.watch(recycleBinRepositoryProvider),
        ref.watch(clockProvider),
        ref.watch(idGeneratorProvider),
      );
    });

final Provider<RestoreItems> restoreItemsProvider = Provider<RestoreItems>((Ref ref) {
  return RestoreItems(
    ref.watch(fileRepositoryProvider),
    ref.watch(recycleBinRepositoryProvider),
    ref.watch(storageRootRepositoryProvider),
  );
});

final Provider<PermanentlyDeleteRecycled> permanentlyDeleteRecycledProvider =
    Provider<PermanentlyDeleteRecycled>((Ref ref) {
      return PermanentlyDeleteRecycled(
        ref.watch(fileRepositoryProvider),
        ref.watch(recycleBinRepositoryProvider),
        ref.watch(storageRootRepositoryProvider),
      );
    });

/// Reactive Recycle Bin contents for one root — deliberately a plain
/// `StreamProvider.family` rather than a full ViewModel: the Recycle Bin
/// screen only needs "list + restore", no paging/sort/multi-select state of
/// its own, so a Notifier would be ceremony without payoff (kickoff §49: "do
/// we actually need this?"). Call as `recycleItemsProvider(root.id)`.
final recycleItemsProvider =
    StreamProvider.autoDispose.family<List<RecycleItem>, String>((Ref ref, String rootId) {
      return ref.watch(recycleBinRepositoryProvider).watchItems(rootId);
    });
