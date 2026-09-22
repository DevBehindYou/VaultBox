import "dart:async";

import "package:flutter/widgets.dart";
import "package:flutter_bloc/flutter_bloc.dart";

import "../core/state/resource.dart";
import "../core/state/resource_cubit.dart";
import "../domain/entities/account.dart";
import "../domain/entities/app_preferences.dart";
import "../domain/entities/server_config.dart";
import "../domain/entities/server_state.dart";
import "../domain/entities/share.dart";
import "../domain/entities/storage_root.dart";
import "../domain/repositories/account_repository.dart";
import "../domain/repositories/server_host.dart";
import "../domain/repositories/settings_repository.dart";
import "../domain/repositories/share_repository.dart";
import "../domain/repositories/storage_root_repository.dart";

/// App-scoped Cubits: one instance each, created once at the app root and
/// alive for the app's lifetime — the Cubit equivalent of every
/// non-`autoDispose` provider that used to live in `providers.dart`. A
/// screen-local, `autoDispose`-equivalent Cubit (recycle-bin items, activity
/// feeds, root stats, FTP settings) is created by the screen that needs it
/// instead; see that screen's own file.

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

/// The app-scoped Cubits above, wired in dependency order (`OwnerAccountCubit`
/// must come after `AccountsCubit` — see its own doc comment). Placed once at
/// the app root, below the `RepositoryProvider`s from `app_providers.dart`.
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
  ];
}
