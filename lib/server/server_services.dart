import "dart:async";
import "dart:io";

import "../app/providers.dart";
import "../data/security/in_memory_session_store.dart";
import "../domain/entities/ftp_settings.dart";
import "../domain/entities/protocol_storage_access.dart";
import "../domain/repositories/clock.dart";
import "../domain/security/download_tickets.dart";
import "../domain/security/login_service.dart";
import "../domain/security/login_throttle.dart";
import "../domain/security/session_manager.dart";
import "activity/activity_log.dart";
import "api/file_endpoints.dart";
import "api/public_endpoints.dart";
import "api/vault_api.dart";
import "files/storage_gate.dart";
import "ftp/ftp_deps.dart";
import "ftp/ftp_server.dart";
import "webdav/dav_auth.dart";
import "webdav/dav_locks.dart";
import "webdav/webdav_handler.dart";

/// Everything the server's isolate needs, wired once. It reuses the app's own
/// composition root ([AppDependencies] — same repositories, hasher and
/// storage backends the UI would build) but its own instance of it: the
/// service's engine is a separate isolate with no widget tree to read a
/// `RepositoryProvider` from, so it opens its own database connection and SAF
/// bridge rather than sharing the UI's.
///
/// Sessions and login throttles live here, in memory, for the life of the
/// server: stopping it (or an OS kill) logs everyone out, and no token
/// material is written to disk.
final class ServerServices {
  ServerServices._(this.api, this.dav, this._ftpDeps, this._clock, this._deps, this._purgeTimer);

  static Future<ServerServices> create() async {
    final AppDependencies deps = AppDependencies.build();
    final Clock clock = deps.clock;

    final SessionManager sessions = SessionManager(store: InMemorySessionStore(), clock: clock);
    final LoginService login = LoginService(
      accounts: deps.accountRepository,
      hasher: deps.passwordHasher,
      sessions: sessions,
      perAccountThrottle: LoginThrottle(clock: clock),
      // Looser than per-account: several people can share one address, but an
      // address that keeps failing across usernames is guessing.
      perAddressThrottle: LoginThrottle(clock: clock, freeAttempts: 20),
    );
    unawaited(login.warmUp().catchError((Object _) {}));

    final DownloadTicketService tickets = DownloadTicketService(clock: clock);
    final ProtocolStorageAccess access = ProtocolStorageAccess.fromMap(await deps.settingsRepository.readAll());
    final StorageGate gate = StorageGate(
      roots: deps.storageRootRepository,
      authorizer: deps.authorizer,
      access: access,
    );
    final ShareUnlocks unlocks = ShareUnlocks(clock: clock);
    // History for the Activity tab: written here, read by the app from the shared database.
    final ActivityLog activity = ActivityLog(
      repository: deps.activityRepository,
      clock: clock,
      ids: deps.idGenerator,
    )..serverStarted();
    final VaultApi api = VaultApi(
      login: login,
      sessions: sessions,
      accounts: deps.accountRepository,
      gate: gate,
      activity: activity,
      public: PublicEndpoints(
        shares: deps.shareRepository,
        accounts: deps.accountRepository,
        gate: gate,
        files: deps.fileRepository,
        hasher: deps.passwordHasher,
        clock: clock,
        unlocks: unlocks,
        activity: activity,
      ),
      files: FileEndpoints(
        gate: gate,
        files: deps.fileRepository,
        accounts: deps.accountRepository,
        tickets: tickets,
        copy: deps.copyItems,
        move: deps.moveItems,
        delete: deps.deleteItems,
        activity: activity,
      ),
    );

    // One password check for WebDAV and FTP: a right answer is remembered briefly
    // (FTP clients open several connections, each of which signs in).
    final DavAuthenticator passwordAuth = DavAuthenticator(
      login: login,
      accounts: deps.accountRepository,
      clock: clock,
    );

    final WebDavHandler dav = WebDavHandler(
      gate: gate,
      files: deps.fileRepository,
      delete: deps.deleteItems,
      auth: passwordAuth,
      locks: DavLockManager(clock: clock),
      activity: activity,
    );

    final FtpDeps ftpDeps = FtpDeps(
      gate: gate,
      files: deps.fileRepository,
      delete: deps.deleteItems,
      move: deps.moveItems,
      auth: passwordAuth,
      activity: activity,
    );

    final Timer purge = Timer.periodic(
      const Duration(minutes: 5),
      (Timer _) {
        unawaited(sessions.purgeExpired());
        tickets.purgeExpired();
        unlocks.purgeExpired();
      },
    );
    return ServerServices._(api, dav, ftpDeps, clock, deps, purge);
  }

  final VaultApi api;
  final WebDavHandler dav;
  final FtpDeps _ftpDeps;
  final Clock _clock;
  final AppDependencies _deps;
  final Timer _purgeTimer;

  /// The FTP settings the person chose in the app (off unless they switched it on).
  Future<FtpSettings> loadFtpSettings() async {
    return FtpSettings.fromMap(await _deps.settingsRepository.readAll());
  }

  /// An FTP server for [settings]. [tls] is required for the two secure modes.
  FtpServer buildFtpServer(FtpSettings settings, {SecurityContext? tls}) {
    return FtpServer(deps: _ftpDeps, settings: settings, tlsContext: tls, now: _clock.now);
  }

  void dispose() {
    _purgeTimer.cancel();
    unawaited(_deps.dispose());
  }
}
