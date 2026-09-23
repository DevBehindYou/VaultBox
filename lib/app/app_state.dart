import "dart:async";

import "package:flutter/widgets.dart";
import "package:flutter_bloc/flutter_bloc.dart";

import "../core/state/resource.dart";
import "../core/state/resource_cubit.dart";
import "../domain/entities/account.dart";
import "../domain/entities/activity.dart";
import "../domain/entities/app_preferences.dart";
import "../domain/entities/ftp_settings.dart";
import "../domain/entities/server_config.dart";
import "../domain/entities/server_state.dart";
import "../domain/entities/share.dart";
import "../domain/entities/storage_root.dart";
import "../domain/repositories/account_repository.dart";
import "../domain/repositories/activity_repository.dart";
import "../domain/repositories/clock.dart";
import "../domain/repositories/server_host.dart";
import "../domain/repositories/settings_repository.dart";
import "../domain/repositories/share_repository.dart";
import "../domain/repositories/storage_root_repository.dart";
import "../platform/adapters/volume_stats_source.dart";

/// App-scoped Cubits: one instance each, created once at the app root and
/// alive for the app's lifetime.
///
/// Every one of these was a non-`autoDispose` provider before this rewrite
/// EXCEPT the activity feeds, root stats and FTP settings, which WERE
/// `autoDispose` — but `home_screen.dart` watches all five of those too, and
/// Home is one of the five permanent `StatefulShellRoute.indexedStack`
/// branches (`lib/app/router.dart`), which go_router keeps mounted forever
/// to preserve each tab's own navigation state. An `autoDispose` provider is
/// only disposed once its LAST watcher unmounts — since Home never unmounts,
/// these were already effectively app-level in the running app, shared
/// between Home and whichever dedicated screen (Activity, Storage,
/// Protocols) also watches them. Making them screen-scoped Cubits instead
/// would silently give Home and that screen two independent instances (two
/// polling timers, inconsistent state) instead of the one they actually
/// shared — so they belong here, not in the screen that seems to "own" them.
///
/// The one genuine screen-scoped Cubit is `RecycleItemsCubit`
/// (`recycle_bin_screen.dart`): Home never watches recycle-bin items, so it
/// really is created and disposed per visit, family-keyed by root id, same
/// as `recycleItemsProvider` was.

/// Reactive root list — was `storageRootsProvider`.
class StorageRootsCubit extends ResourceStreamCubit<List<StorageRoot>> {
  StorageRootsCubit(StorageRootRepository repository)
    : super(repository.watchRoots());
}

/// The server's live state (native owns it; this mirrors it) — was
/// `serverStateProvider`.
class ServerStateCubit extends ResourceStreamCubit<ServerState> {
  ServerStateCubit(ServerHost host) : super(host.watch());
}

/// Saved server settings (network access on/off, port) — was
/// `serverConfigProvider`. `refresh()` replaces `ref.invalidate(...)`.
class ServerConfigCubit extends ResourceFutureCubit<ServerConfig> {
  ServerConfigCubit(ServerHost host) : super(host.config);
}

/// SHA-256 fingerprint of the server's TLS certificate — was
/// `tlsFingerprintProvider`.
class TlsFingerprintCubit extends ResourceFutureCubit<String> {
  TlsFingerprintCubit(ServerHost host) : super(host.tlsFingerprint);
}

/// Whether an admin account exists yet — was `adminExistsProvider`.
/// `refresh()` replaces `ref.invalidate(...)`; `current()` (from
/// [ResourceAwaiter]) replaces `ref.read(adminExistsProvider.future)`.
class AdminExistsCubit extends ResourceFutureCubit<bool> {
  AdminExistsCubit(AccountRepository accounts)
    : super(() async => (await accounts.count()) > 0);
}

/// Every account, oldest first — was `accountsProvider`. `refresh()`
/// replaces `ref.invalidate(...)`.
class AccountsCubit extends ResourceFutureCubit<List<Account>> {
  AccountsCubit(AccountRepository accounts) : super(accounts.listAll);
}

/// Every share / upload link, newest first — was `sharesProvider`.
/// `refresh()` replaces `ref.invalidate(...)`.
class SharesCubit extends ResourceFutureCubit<List<Share>> {
  SharesCubit(ShareRepository shares) : super(shares.list);
}

/// The person who owns the phone: the first enabled admin — was
/// `ownerAccountProvider`, which watched `accountsProvider.future` so it
/// recomputed automatically whenever accounts refreshed. This Cubit does the
/// same by subscribing to an [AccountsCubit] directly rather than loading
/// independently — do not give it its own repository read, or an
/// `AccountsCubit.refresh()` elsewhere stops keeping this in sync exactly
/// like it silently would have before this rewrite.
class OwnerAccountCubit extends Cubit<Resource<Account?>>
    with ResourceAwaiter<Account?> {
  OwnerAccountCubit(AccountsCubit accounts)
    : super(_derive(accounts.state)) {
    _subscription = accounts.stream.listen(
      (Resource<List<Account>> state) {
        if (!isClosed) emit(_derive(state));
      },
    );
  }

  late final StreamSubscription<Resource<List<Account>>> _subscription;

  static Resource<Account?> _derive(Resource<List<Account>> accounts) {
    return accounts.when(
      loading: () => const ResourceLoading<Account?>(),
      error: (Object error, StackTrace stackTrace) =>
          ResourceError<Account?>(error, stackTrace),
      data: (List<Account> all) {
        for (final Account account in all) {
          if (account.isAdmin && account.isEnabled) {
            return ResourceData<Account?>(account);
          }
        }
        return const ResourceData<Account?>(null);
      },
    );
  }

  @override
  Future<void> close() {
    unawaited(_subscription.cancel());
    return super.close();
  }
}

/// The person's Appearance choices, loaded once and saved on every change —
/// was `preferencesProvider` (an `AsyncNotifierProvider`). Unlike the
/// `Resource`-wrapped Cubits above, every call site here only ever did
/// `.value ?? const AppPreferences()`, so this Cubit's state is a plain
/// [AppPreferences] starting at the default, not a `Resource<AppPreferences>`
/// — `context.watch<PreferencesCubit>().state` needs no fallback.
class PreferencesCubit extends Cubit<AppPreferences> {
  PreferencesCubit(this._settings) : super(const AppPreferences()) {
    unawaited(_load());
  }

  final SettingsRepository _settings;

  Future<void> _load() async {
    final AppPreferences loaded = AppPreferences.fromMap(
      await _settings.readAll(),
    );
    if (!isClosed) emit(loaded);
  }

  /// Applies [update] to what is current, shows it at once, then saves it.
  Future<void> change(
    AppPreferences Function(AppPreferences current) update,
  ) async {
    final AppPreferences next = update(state);
    emit(next);
    await _settings.writeAll(next.toMap());
  }
}

/// Recent activity events (sign-ins, refusals, link use) — was
/// `activityEventsProvider`. `refreshNow()` replaces `ref.invalidate(...)`.
class ActivityEventsCubit extends PolledCubit<List<ActivityEvent>> {
  ActivityEventsCubit(ActivityRepository repository) : super(repository.recentEvents);
}

/// Recent file transfers — was `activityTransfersProvider`. `refreshNow()`
/// replaces `ref.invalidate(...)`.
class ActivityTransfersCubit extends PolledCubit<List<TransferRecord>> {
  ActivityTransfersCubit(ActivityRepository repository) : super(repository.recentTransfers);
}

/// Clients seen in the last day — was `activityClientsProvider`.
/// `refreshNow()` replaces `ref.invalidate(...)`. Recomputes "since" fresh on
/// every poll via [clock], exactly like the original did.
class ActivityClientsCubit extends PolledCubit<List<ClientRecord>> {
  ActivityClientsCubit(ActivityRepository repository, Clock clock)
    : super(
        () => repository.recentClients(
          since: clock.now().subtract(const Duration(days: 1)),
        ),
      );
}

/// How full the volume behind each enabled, available storage location is,
/// by root id — was `rootStatsProvider`. That provider watched
/// `storageRootsProvider.future`, so it recomputed whenever the root list
/// changed, on top of `ref.invalidate(rootStatsProvider)` after a read/write
/// test or a backend cache eviction; this Cubit does both: it re-measures
/// whenever [roots] emits, and `refresh()` re-measures on demand.
class RootStatsCubit extends Cubit<Resource<Map<String, VolumeStats>>>
    with ResourceAwaiter<Map<String, VolumeStats>> {
  RootStatsCubit(this._roots, this._source) : super(const ResourceLoading()) {
    _subscription = _roots.stream.listen((Resource<List<StorageRoot>> _) => unawaited(refresh()));
    unawaited(refresh());
  }

  final StorageRootsCubit _roots;
  final VolumeStatsSource _source;
  late final StreamSubscription<Resource<List<StorageRoot>>> _subscription;

  Future<void> refresh() async {
    final List<StorageRoot>? roots = _roots.state.value;
    if (roots == null) return; // upstream still loading/errored; nothing to measure yet
    try {
      final Map<String, VolumeStats> stats = <String, VolumeStats>{};
      for (final StorageRoot root in roots) {
        if (!root.isEnabled || !root.isAvailable) continue;
        final VolumeStats? measured = await _source.statsFor(root);
        if (measured != null) stats[root.id] = measured;
      }
      if (!isClosed) emit(ResourceData<Map<String, VolumeStats>>(stats));
    } on Object catch (error, stackTrace) {
      if (!isClosed) emit(ResourceError<Map<String, VolumeStats>>(error, stackTrace));
    }
  }

  @override
  Future<void> close() {
    unawaited(_subscription.cancel());
    return super.close();
  }
}

/// What the person chose for the FTP server (off unless they switched it
/// on) — was `ftpSettingsProvider`. `refresh()` replaces
/// `ref.invalidate(...)`.
class FtpSettingsCubit extends ResourceFutureCubit<FtpSettings> {
  FtpSettingsCubit(SettingsRepository settings)
    : super(() async => FtpSettings.fromMap(await settings.readAll()));
}

/// The app-scoped Cubits above, wired in dependency order (`OwnerAccountCubit`
/// must come after `AccountsCubit`, `RootStatsCubit` after `StorageRootsCubit`
/// — see their own doc comments). Placed once at the app root, below the
/// `RepositoryProvider`s from `app_providers.dart`.
List<BlocProvider<dynamic>> buildAppBlocProviders() {
  return <BlocProvider<dynamic>>[
    BlocProvider<PreferencesCubit>(
      create: (BuildContext context) => PreferencesCubit(context.read<SettingsRepository>()),
    ),
    BlocProvider<StorageRootsCubit>(
      create: (BuildContext context) => StorageRootsCubit(context.read<StorageRootRepository>()),
    ),
    BlocProvider<ServerStateCubit>(
      create: (BuildContext context) => ServerStateCubit(context.read<ServerHost>()),
    ),
    BlocProvider<ServerConfigCubit>(
      create: (BuildContext context) => ServerConfigCubit(context.read<ServerHost>()),
    ),
    BlocProvider<TlsFingerprintCubit>(
      create: (BuildContext context) => TlsFingerprintCubit(context.read<ServerHost>()),
    ),
    BlocProvider<AdminExistsCubit>(
      create: (BuildContext context) => AdminExistsCubit(context.read<AccountRepository>()),
    ),
    BlocProvider<AccountsCubit>(
      create: (BuildContext context) => AccountsCubit(context.read<AccountRepository>()),
    ),
    BlocProvider<SharesCubit>(
      create: (BuildContext context) => SharesCubit(context.read<ShareRepository>()),
    ),
    BlocProvider<OwnerAccountCubit>(
      create: (BuildContext context) => OwnerAccountCubit(context.read<AccountsCubit>()),
    ),
    BlocProvider<ActivityEventsCubit>(
      create: (BuildContext context) => ActivityEventsCubit(context.read<ActivityRepository>()),
    ),
    BlocProvider<ActivityTransfersCubit>(
      create: (BuildContext context) => ActivityTransfersCubit(context.read<ActivityRepository>()),
    ),
    BlocProvider<ActivityClientsCubit>(
      create: (BuildContext context) =>
          ActivityClientsCubit(context.read<ActivityRepository>(), context.read<Clock>()),
    ),
    BlocProvider<RootStatsCubit>(
      create: (BuildContext context) =>
          RootStatsCubit(context.read<StorageRootsCubit>(), context.read<VolumeStatsSource>()),
    ),
    BlocProvider<FtpSettingsCubit>(
      create: (BuildContext context) => FtpSettingsCubit(context.read<SettingsRepository>()),
    ),
  ];
}
