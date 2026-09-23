import "../data/db/app_database.dart";
import "../data/repositories/drift_account_repository.dart";
import "../data/repositories/drift_activity_repository.dart";
import "../data/repositories/drift_recycle_bin_repository.dart";
import "../data/repositories/drift_settings_repository.dart";
import "../data/repositories/drift_share_repository.dart";
import "../data/repositories/drift_storage_root_repository.dart";
import "../data/repositories/file_repository_impl.dart";
import "../data/security/argon2id_password_hasher.dart";
import "../data/services/direct_path_storage_backend.dart";
import "../data/services/memory_storage_backend.dart";
import "../data/services/saf_storage_backend.dart";
import "../data/services/system_clock.dart";
import "../domain/entities/storage_root.dart";
import "../domain/repositories/account_repository.dart";
import "../domain/repositories/activity_repository.dart";
import "../domain/repositories/clock.dart";
import "../domain/repositories/file_repository.dart";
import "../domain/repositories/id_generator.dart";
import "../domain/repositories/recycle_bin_repository.dart";
import "../domain/repositories/server_host.dart";
import "../domain/repositories/settings_repository.dart";
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
import "../domain/usecases/test_storage_access.dart";
import "../platform/adapters/android_storage_host.dart";
import "../platform/adapters/pigeon_android_storage_host.dart";
import "../platform/adapters/pigeon_server_host.dart";
import "../platform/adapters/url_opener.dart";
import "../platform/adapters/volume_stats_source.dart";

/// Composition root for the storage/file layer and every other plain
/// service, repository and use case the app wires once.
///
/// Deliberately plain Dart — no `flutter_bloc`/`package:provider` import
/// here, and no `BuildContext` anywhere in this file. `lib/server/
/// server_services.dart` builds one of these directly inside the server's
/// headless engine, which never has a widget tree to read a
/// `RepositoryProvider` from; the UI side is the only side that needs one,
/// via `AppDependencies.build()` wrapped by `RepositoryProvider.value` for
/// each field in `lib/app/app_providers.dart`. Every field here replaces a
/// former Riverpod `Provider<T>`; the reactive ones (former `StreamProvider`/
/// `FutureProvider`, watched by a screen) are NOT here — they're Cubits, in
/// `lib/app/app_state.dart` (app-scoped) or the screen that owns them
/// (screen-scoped autoDispose equivalents), each built from the repositories
/// below.
final class AppDependencies {
  AppDependencies._({
    required this.clock,
    required this.idGenerator,
    required this.androidStorageHost,
    required this.backendRegistry,
    required this.database,
    required this.storageRootRepository,
    required this.recycleBinRepository,
    required this.fileRepository,
    required this.copyItems,
    required this.importFiles,
    required this.moveItems,
    required this.deleteItems,
    required this.restoreItems,
    required this.permanentlyDeleteRecycled,
    required this.serverHost,
    required this.accountRepository,
    required this.passwordHasher,
    required this.createAdminAccount,
    required this.authorizer,
    required this.shareRepository,
    required this.createUserAccount,
    required this.changePassword,
    required this.setAccountEnabled,
    required this.deleteAccount,
    required this.setAccessRules,
    required this.createShare,
    required this.activityRepository,
    required this.runDiagnostics,
    required this.settingsRepository,
    required this.volumeStatsSource,
    required this.urlOpener,
    required this.testStorageAccess,
  });

  /// Builds the whole graph with its real, production implementations. Every
  /// field is still a plain constructor-injected value below it in this
  /// list, so a test that only needs a few fakes constructs its own
  /// `AppDependencies._(...)` — or, on the UI side, overrides just the one
  /// `RepositoryProvider<X>.value` it needs (see `app_providers.dart`)
  /// rather than rebuilding this whole factory.
  factory AppDependencies.build() {
    final Clock clock = const SystemClock();
    final IdGenerator idGenerator = UuidIdGenerator();
    final AndroidStorageHost androidStorageHost = PigeonAndroidStorageHost();
    final BackendRegistry backendRegistry = BackendRegistry(host: androidStorageHost);
    final AppDatabase database = AppDatabase();
    final StorageRootRepository storageRootRepository = DriftStorageRootRepository(database);
    final RecycleBinRepository recycleBinRepository = DriftRecycleBinRepository(database);
    final FileRepository fileRepository = FileRepositoryImpl(resolveBackend: backendRegistry.forRoot);
    final AccountRepository accountRepository = DriftAccountRepository(database);
    final PasswordHasher passwordHasher = Argon2idPasswordHasher();
    final Authorizer authorizer = const AclAuthorizer();
    final ShareRepository shareRepository = DriftShareRepository(database);
    final ActivityRepository activityRepository = DriftActivityRepository(database);
    final SettingsRepository settingsRepository = DriftSettingsRepository(database);
    final ServerHost serverHost = PigeonServerHost();

    return AppDependencies._(
      clock: clock,
      idGenerator: idGenerator,
      androidStorageHost: androidStorageHost,
      backendRegistry: backendRegistry,
      database: database,
      storageRootRepository: storageRootRepository,
      recycleBinRepository: recycleBinRepository,
      fileRepository: fileRepository,
      copyItems: CopyItems(fileRepository),
      importFiles: ImportFiles(fileRepository),
      moveItems: MoveItems(fileRepository),
      deleteItems: DeleteItemsToRecycleBin(fileRepository, recycleBinRepository, clock, idGenerator),
      restoreItems: RestoreItems(fileRepository, recycleBinRepository, storageRootRepository),
      permanentlyDeleteRecycled: PermanentlyDeleteRecycled(fileRepository, recycleBinRepository, storageRootRepository),
      serverHost: serverHost,
      accountRepository: accountRepository,
      passwordHasher: passwordHasher,
      createAdminAccount: CreateAdminAccount(accountRepository, passwordHasher, idGenerator, clock),
      authorizer: authorizer,
      shareRepository: shareRepository,
      createUserAccount: CreateUserAccount(accountRepository, passwordHasher, idGenerator, clock),
      changePassword: ChangePassword(accountRepository, passwordHasher),
      setAccountEnabled: SetAccountEnabled(accountRepository),
      deleteAccount: DeleteAccount(accountRepository, shareRepository),
      setAccessRules: SetAccessRules(accountRepository, idGenerator),
      createShare: CreateShare(
        roots: storageRootRepository,
        files: fileRepository,
        shares: shareRepository,
        hasher: passwordHasher,
        ids: idGenerator,
        clock: clock,
        authorizer: authorizer,
      ),
      activityRepository: activityRepository,
      runDiagnostics: RunDiagnostics(
        roots: storageRootRepository,
        files: fileRepository,
        accounts: accountRepository,
        shares: shareRepository,
        server: serverHost,
        clock: clock,
      ),
      settingsRepository: settingsRepository,
      volumeStatsSource: const ChannelVolumeStatsSource(),
      urlOpener: const LauncherUrlOpener(),
      testStorageAccess: TestStorageAccess(fileRepository, clock),
    );
  }

  final Clock clock;
  final IdGenerator idGenerator;
  final AndroidStorageHost androidStorageHost;
  final BackendRegistry backendRegistry;
  final AppDatabase database;
  final StorageRootRepository storageRootRepository;
  final RecycleBinRepository recycleBinRepository;
  final FileRepository fileRepository;
  final CopyItems copyItems;
  final ImportFiles importFiles;
  final MoveItems moveItems;
  final DeleteItemsToRecycleBin deleteItems;
  final RestoreItems restoreItems;
  final PermanentlyDeleteRecycled permanentlyDeleteRecycled;
  final ServerHost serverHost;
  final AccountRepository accountRepository;
  final PasswordHasher passwordHasher;
  final CreateAdminAccount createAdminAccount;
  final Authorizer authorizer;
  final ShareRepository shareRepository;
  final CreateUserAccount createUserAccount;
  final ChangePassword changePassword;
  final SetAccountEnabled setAccountEnabled;
  final DeleteAccount deleteAccount;
  final SetAccessRules setAccessRules;
  final CreateShare createShare;
  final ActivityRepository activityRepository;
  final RunDiagnostics runDiagnostics;
  final SettingsRepository settingsRepository;
  final VolumeStatsSource volumeStatsSource;
  final UrlOpener urlOpener;
  final TestStorageAccess testStorageAccess;

  Future<void> dispose() => database.close();
}

/// How often the Activity lists re-read. The server writes them from another
/// engine, so there is nothing to subscribe to; polling stops with the
/// screen that owns the `PolledCubit` using this.
const Duration activityPollInterval = Duration(seconds: 3);

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
