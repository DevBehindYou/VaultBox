import "package:flutter_bloc/flutter_bloc.dart";

import "../domain/repositories/account_repository.dart";
import "../domain/repositories/activity_repository.dart";
import "../domain/repositories/clock.dart";
import "../domain/repositories/file_repository.dart";
import "../domain/repositories/id_generator.dart";
import "../domain/repositories/recycle_bin_repository.dart";
import "../domain/repositories/server_host.dart";
import "../domain/repositories/settings_repository.dart";
import "../domain/repositories/share_repository.dart";
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
import "../platform/adapters/url_opener.dart";
import "../platform/adapters/volume_stats_source.dart";
import "providers.dart";

/// Exposes every [AppDependencies] field as its own `RepositoryProvider`, so
/// screens keep doing `context.read<FileRepository>()` /
/// `context.watch<...>()` for one concrete type each — the same shape as
/// `ref.read(fileRepositoryProvider)` before this rewrite — instead of
/// threading `AppDependencies` itself through every screen. Only the app
/// root (`main.dart`) and tests that need production wiring call this;
/// other tests provide just the one or two fakes they need directly.
///
/// `AppDatabase` isn't exposed: nothing outside `providers.dart` ever reads
/// it directly, only the repositories built from it.
List<RepositoryProvider<dynamic>> buildRepositoryProviders(AppDependencies deps) {
  return <RepositoryProvider<dynamic>>[
    RepositoryProvider<AppDependencies>.value(value: deps),
    RepositoryProvider<Clock>.value(value: deps.clock),
    RepositoryProvider<IdGenerator>.value(value: deps.idGenerator),
    RepositoryProvider<AndroidStorageHost>.value(value: deps.androidStorageHost),
    RepositoryProvider<BackendRegistry>.value(value: deps.backendRegistry),
    RepositoryProvider<StorageRootRepository>.value(value: deps.storageRootRepository),
    RepositoryProvider<RecycleBinRepository>.value(value: deps.recycleBinRepository),
    RepositoryProvider<FileRepository>.value(value: deps.fileRepository),
    RepositoryProvider<CopyItems>.value(value: deps.copyItems),
    RepositoryProvider<ImportFiles>.value(value: deps.importFiles),
    RepositoryProvider<MoveItems>.value(value: deps.moveItems),
    RepositoryProvider<DeleteItemsToRecycleBin>.value(value: deps.deleteItems),
    RepositoryProvider<RestoreItems>.value(value: deps.restoreItems),
    RepositoryProvider<PermanentlyDeleteRecycled>.value(value: deps.permanentlyDeleteRecycled),
    RepositoryProvider<ServerHost>.value(value: deps.serverHost),
    RepositoryProvider<AccountRepository>.value(value: deps.accountRepository),
    RepositoryProvider<PasswordHasher>.value(value: deps.passwordHasher),
    RepositoryProvider<CreateAdminAccount>.value(value: deps.createAdminAccount),
    RepositoryProvider<Authorizer>.value(value: deps.authorizer),
    RepositoryProvider<ShareRepository>.value(value: deps.shareRepository),
    RepositoryProvider<CreateUserAccount>.value(value: deps.createUserAccount),
    RepositoryProvider<ChangePassword>.value(value: deps.changePassword),
    RepositoryProvider<SetAccountEnabled>.value(value: deps.setAccountEnabled),
    RepositoryProvider<DeleteAccount>.value(value: deps.deleteAccount),
    RepositoryProvider<SetAccessRules>.value(value: deps.setAccessRules),
    RepositoryProvider<CreateShare>.value(value: deps.createShare),
    RepositoryProvider<ActivityRepository>.value(value: deps.activityRepository),
    RepositoryProvider<RunDiagnostics>.value(value: deps.runDiagnostics),
    RepositoryProvider<SettingsRepository>.value(value: deps.settingsRepository),
    RepositoryProvider<VolumeStatsSource>.value(value: deps.volumeStatsSource),
    RepositoryProvider<UrlOpener>.value(value: deps.urlOpener),
    RepositoryProvider<TestStorageAccess>.value(value: deps.testStorageAccess),
  ];
}
