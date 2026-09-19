import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../app/providers.dart";
import "../data/security/in_memory_session_store.dart";
import "../domain/repositories/clock.dart";
import "../domain/security/authorizer.dart";
import "../domain/security/download_tickets.dart";
import "../domain/security/login_service.dart";
import "../domain/security/login_throttle.dart";
import "../domain/security/session_manager.dart";
import "api/file_endpoints.dart";
import "api/vault_api.dart";

/// Everything the server's isolate needs, wired once. It reuses the app's own
/// providers (same repositories, hasher and storage backends as the UI) in a
/// private container: the service's engine is a separate isolate, so it opens
/// its own database connection and SAF bridge rather than sharing the UI's.
///
/// Sessions and login throttles live here, in memory, for the life of the
/// server: stopping it (or an OS kill) logs everyone out, and no token
/// material is written to disk.
final class ServerServices {
  ServerServices._(this.api, this._container, this._purgeTimer);

  factory ServerServices.create() {
    final ProviderContainer container = ProviderContainer();
    final Clock clock = container.read(clockProvider);

    final SessionManager sessions = SessionManager(store: InMemorySessionStore(), clock: clock);
    final LoginService login = LoginService(
      accounts: container.read(accountRepositoryProvider),
      hasher: container.read(passwordHasherProvider),
      sessions: sessions,
      perAccountThrottle: LoginThrottle(clock: clock),
      // Looser than per-account: several people can share one address, but an
      // address that keeps failing across usernames is guessing.
      perAddressThrottle: LoginThrottle(clock: clock, freeAttempts: 20),
    );
    unawaited(login.warmUp().catchError((Object _) {}));

    final DownloadTicketService tickets = DownloadTicketService(clock: clock);
    final VaultApi api = VaultApi(
      login: login,
      sessions: sessions,
      accounts: container.read(accountRepositoryProvider),
      roots: container.read(storageRootRepositoryProvider),
      files: FileEndpoints(
        roots: container.read(storageRootRepositoryProvider),
        files: container.read(fileRepositoryProvider),
        accounts: container.read(accountRepositoryProvider),
        authorizer: const SingleAdminAuthorizer(),
        tickets: tickets,
        copy: container.read(copyItemsProvider),
        move: container.read(moveItemsProvider),
        delete: container.read(deleteItemsProvider),
      ),
    );

    final Timer purge = Timer.periodic(
      const Duration(minutes: 5),
      (Timer _) {
        unawaited(sessions.purgeExpired());
        tickets.purgeExpired();
      },
    );
    return ServerServices._(api, container, purge);
  }

  final VaultApi api;
  final ProviderContainer _container;
  final Timer _purgeTimer;

  void dispose() {
    _purgeTimer.cancel();
    _container.dispose();
  }
}
