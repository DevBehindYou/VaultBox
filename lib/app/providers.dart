import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../data/db/app_database.dart";
import "../data/repositories/drift_account_repository.dart";
import "../data/repositories/drift_activity_repository.dart";
import "../data/repositories/drift_recycle_bin_repository.dart";
import "../data/repositories/drift_share_repository.dart";
import "../data/repositories/drift_storage_root_repository.dart";
import "../data/repositories/file_repository_impl.dart";
import "../data/security/argon2id_password_hasher.dart";
import "../data/services/direct_path_storage_backend.dart";
import "../data/services/memory_storage_backend.dart";
import "../data/services/saf_storage_backend.dart";
import "../data/services/system_clock.dart";
import "../domain/entities/account.dart";
import "../domain/entities/activity.dart";
import "../domain/entities/recycle_item.dart";
import "../domain/entities/server_config.dart";
import "../domain/entities/server_state.dart";
import "../domain/entities/share.dart";
import "../domain/entities/storage_root.dart";
import "../domain/repositories/account_repository.dart";
import "../domain/repositories/activity_repository.dart";
import "../domain/repositories/clock.dart";
import "../domain/repositories/file_repository.dart";
import "../domain/repositories/id_generator.dart";
import "../domain/repositories/recycle_bin_repository.dart";
import "../domain/repositories/server_host.dart";
import "../domain/repositories/share_repository.dart";
import "../domain/repositories/storage_backend.dart";
import "../domain/repositories/storage_root_repository.dart";
import "../domain/security/authorizer.dart";
import "../domain/security/password_hasher.dart";
import "../domain/usecases/copy_items.dart";
import "../domain/usecases/create_admin_account.dart";
import "../domain/usecases/create_share.dart";
import "../domain/usecases/delete_items_to_recycle_bin.dart";
import "../domain/usecases/import_files.dart";
import "../domain/usecases/manage_accounts.dart";
import "../domain/usecases/move_items.dart";
import "../domain/usecases/permanently_delete_recycled.dart";
import "../domain/usecases/restore_items.dart";
import "../domain/usecases/run_diagnostics.dart";
import "../platform/adapters/android_storage_host.dart";
import "../platform/adapters/pigeon_android_storage_host.dart";
import "../platform/adapters/pigeon_server_host.dart";

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
  BackendRegistry({AndroidStorageHost? host}) : _host = host;

  /// Native SAF bridge; null in tests / contexts that never open a SAF root.
  final AndroidStorageHost? _host;

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

  StorageBackend _createSaf(StorageRoot root) {
    final AndroidStorageHost? host = _host;
    final String? rootDocumentId = root.rootDocumentId;
    if (host == null) {
      throw StateError("No AndroidStorageHost available to open SAF root ${root.id}");
    }
    if (rootDocumentId == null) {
      throw StateError("SAF root ${root.id} has no rootDocumentId");
    }
    return SafStorageBackend(
      id: root.id,
      host: host,
      treeUri: root.uriOrPath,
      rootDocumentId: rootDocumentId,
    );
  }

  StorageBackend _create(StorageRoot root) {
    return switch (root.backendType) {
      StorageBackendType.direct => DirectPathStorageBackend(
        id: root.id,
        rootDirectory: root.uriOrPath,
      ),
      StorageBackendType.memory => MemoryStorageBackend(id: root.id),
      StorageBackendType.saf => _createSaf(root),
      StorageBackendType.vault => throw UnimplementedError(
        "VaultStorageBackend is Phase 8",
      ),
    };
  }
}

/// The native SAF bridge (Pigeon). Overridable in tests with a fake.
final Provider<AndroidStorageHost> androidStorageHostProvider =
    Provider<AndroidStorageHost>((Ref ref) => PigeonAndroidStorageHost());

final Provider<BackendRegistry> backendRegistryProvider = Provider<BackendRegistry>((Ref ref) {
  return BackendRegistry(host: ref.watch(androidStorageHostProvider));
});

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

final Provider<ImportFiles> importFilesProvider =
    Provider<ImportFiles>((Ref ref) => ImportFiles(ref.watch(fileRepositoryProvider)));

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

// --- Server host (Phase 2) ---

/// Controls the Foreground Service that hosts the server. Overridable in tests.
final Provider<ServerHost> serverHostProvider =
    Provider<ServerHost>((Ref ref) => PigeonServerHost());

/// The server's live state (native owns it; this mirrors it).
final StreamProvider<ServerState> serverStateProvider =
    StreamProvider<ServerState>((Ref ref) => ref.watch(serverHostProvider).watch());

/// Saved server settings (network access on/off, port).
final FutureProvider<ServerConfig> serverConfigProvider =
    FutureProvider<ServerConfig>((Ref ref) => ref.watch(serverHostProvider).config());

/// SHA-256 fingerprint of the server's TLS certificate.
final FutureProvider<String> tlsFingerprintProvider =
    FutureProvider<String>((Ref ref) => ref.watch(serverHostProvider).tlsFingerprint());

// --- Accounts (Phase 3) ---

final Provider<AccountRepository> accountRepositoryProvider =
    Provider<AccountRepository>((Ref ref) => DriftAccountRepository(ref.watch(appDatabaseProvider)));

/// Argon2id at the OWASP minimum. Overridden with a fast fake in widget tests.
final Provider<PasswordHasher> passwordHasherProvider =
    Provider<PasswordHasher>((Ref ref) => Argon2idPasswordHasher());

final Provider<CreateAdminAccount> createAdminAccountProvider = Provider<CreateAdminAccount>((Ref ref) {
  return CreateAdminAccount(
    ref.watch(accountRepositoryProvider),
    ref.watch(passwordHasherProvider),
    ref.watch(idGeneratorProvider),
    ref.watch(clockProvider),
  );
});

/// Whether an admin account exists yet (drives onboarding and the network switch).
final FutureProvider<bool> adminExistsProvider = FutureProvider<bool>(
  (Ref ref) async => (await ref.watch(accountRepositoryProvider).count()) > 0,
);

// --- People and sharing (Phase 5) ---

/// Role + folder-grant access, used by every protocol the server speaks.
final Provider<Authorizer> authorizerProvider = Provider<Authorizer>((Ref ref) => const AclAuthorizer());

final Provider<ShareRepository> shareRepositoryProvider =
    Provider<ShareRepository>((Ref ref) => DriftShareRepository(ref.watch(appDatabaseProvider)));

final Provider<CreateUserAccount> createUserAccountProvider = Provider<CreateUserAccount>((Ref ref) {
  return CreateUserAccount(
    ref.watch(accountRepositoryProvider),
    ref.watch(passwordHasherProvider),
    ref.watch(idGeneratorProvider),
    ref.watch(clockProvider),
  );
});

final Provider<ChangePassword> changePasswordProvider = Provider<ChangePassword>(
  (Ref ref) => ChangePassword(ref.watch(accountRepositoryProvider), ref.watch(passwordHasherProvider)),
);

final Provider<SetAccountEnabled> setAccountEnabledProvider =
    Provider<SetAccountEnabled>((Ref ref) => SetAccountEnabled(ref.watch(accountRepositoryProvider)));

final Provider<DeleteAccount> deleteAccountProvider = Provider<DeleteAccount>(
  (Ref ref) => DeleteAccount(ref.watch(accountRepositoryProvider), ref.watch(shareRepositoryProvider)),
);

final Provider<SetAccessRules> setAccessRulesProvider = Provider<SetAccessRules>(
  (Ref ref) => SetAccessRules(ref.watch(accountRepositoryProvider), ref.watch(idGeneratorProvider)),
);

final Provider<CreateShare> createShareProvider = Provider<CreateShare>((Ref ref) {
  return CreateShare(
    roots: ref.watch(storageRootRepositoryProvider),
    files: ref.watch(fileRepositoryProvider),
    shares: ref.watch(shareRepositoryProvider),
    hasher: ref.watch(passwordHasherProvider),
    ids: ref.watch(idGeneratorProvider),
    clock: ref.watch(clockProvider),
    authorizer: ref.watch(authorizerProvider),
  );
});

/// Every account, oldest first. Invalidate after a change.
final FutureProvider<List<Account>> accountsProvider =
    FutureProvider<List<Account>>((Ref ref) => ref.watch(accountRepositoryProvider).listAll());

/// Every share / upload link, newest first. Invalidate after a change.
final FutureProvider<List<Share>> sharesProvider =
    FutureProvider<List<Share>>((Ref ref) => ref.watch(shareRepositoryProvider).list());

/// The person who owns the phone: the first enabled admin. Links made in the app
/// are made as them.
final FutureProvider<Account?> ownerAccountProvider = FutureProvider<Account?>((Ref ref) async {
  final List<Account> all = await ref.watch(accountsProvider.future);
  for (final Account account in all) {
    if (account.isAdmin && account.isEnabled) return account;
  }
  return null;
});

// --- Activity and diagnostics (Phase 6) ---

final Provider<ActivityRepository> activityRepositoryProvider =
    Provider<ActivityRepository>((Ref ref) => DriftActivityRepository(ref.watch(appDatabaseProvider)));

final Provider<RunDiagnostics> runDiagnosticsProvider = Provider<RunDiagnostics>((Ref ref) {
  return RunDiagnostics(
    roots: ref.watch(storageRootRepositoryProvider),
    files: ref.watch(fileRepositoryProvider),
    accounts: ref.watch(accountRepositoryProvider),
    shares: ref.watch(shareRepositoryProvider),
    server: ref.watch(serverHostProvider),
    clock: ref.watch(clockProvider),
  );
});

/// How often the Activity lists re-read. The server writes them from another
/// engine, so there is nothing to subscribe to; polling stops with the screen.
const Duration activityPollInterval = Duration(seconds: 3);

/// Emits [read] now and then every [every], until the provider is dropped.
Stream<T> _polled<T>(Ref ref, Future<T> Function() read, {Duration every = activityPollInterval}) {
  final StreamController<T> controller = StreamController<T>();
  Future<void> tick() async {
    try {
      final T value = await read();
      if (!controller.isClosed) controller.add(value);
    } on Object catch (error, trace) {
      if (!controller.isClosed) controller.addError(error, trace);
    }
  }

  unawaited(tick());
  final Timer timer = Timer.periodic(every, (Timer _) => unawaited(tick()));
  ref.onDispose(() {
    timer.cancel();
    unawaited(controller.close());
  });
  return controller.stream;
}

final StreamProvider<List<ActivityEvent>> activityEventsProvider = StreamProvider.autoDispose<List<ActivityEvent>>(
  (Ref ref) => _polled(ref, () => ref.read(activityRepositoryProvider).recentEvents()),
);

final StreamProvider<List<TransferRecord>> activityTransfersProvider =
    StreamProvider.autoDispose<List<TransferRecord>>(
      (Ref ref) => _polled(ref, () => ref.read(activityRepositoryProvider).recentTransfers()),
    );

/// Clients seen in the last day.
final StreamProvider<List<ClientRecord>> activityClientsProvider = StreamProvider.autoDispose<List<ClientRecord>>(
  (Ref ref) => _polled(
    ref,
    () => ref.read(activityRepositoryProvider).recentClients(
      since: ref.read(clockProvider).now().subtract(const Duration(days: 1)),
    ),
  ),
);
