import "dart:async";
import "dart:convert";
import "dart:io";

import "package:vaultbox/data/repositories/file_repository_impl.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/data/repositories/in_memory_recycle_bin_repository.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/data/security/in_memory_session_store.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/data/services/system_clock.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/ftp_settings.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/repositories/recycle_bin_repository.dart";
import "package:vaultbox/domain/security/authorizer.dart";
import "package:vaultbox/domain/security/login_service.dart";
import "package:vaultbox/domain/security/login_throttle.dart";
import "package:vaultbox/domain/security/session_manager.dart";
import "package:vaultbox/domain/usecases/delete_items_to_recycle_bin.dart";
import "package:vaultbox/domain/usecases/move_items.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/server/activity/activity_log.dart";
import "package:vaultbox/server/files/storage_gate.dart";
import "package:vaultbox/server/ftp/ftp_deps.dart";
import "package:vaultbox/server/ftp/ftp_server.dart";
import "package:vaultbox/server/webdav/dav_auth.dart";

import "fake_clock.dart";
import "fake_password_hasher.dart";

/// An [FtpServer] on in-memory parts, mirroring `DavHarness`: an admin
/// account, a controllable clock, a writable memory root "Phone" (`r1`), and
/// (unless `withCard: false`) a read-only one "Card" (`r2`) — for testing
/// that a read-only root refuses writes over FTP just like it does over the
/// web API and WebDAV.
final class FtpHarness {
  FtpHarness._({
    required this.clock,
    required this.hasher,
    required this.phone,
    required this.card,
    required this.accounts,
    required this.recycleBin,
    required this.server,
  });

  factory FtpHarness({
    Authorizer authorizer = const SingleAdminAuthorizer(),
    FtpSettings settings = const FtpSettings(enabled: true),
    FtpLimits limits = const FtpLimits(failedLoginDelay: Duration.zero),
    SecurityContext? tls,
    bool privateClientsOnly = true,
    List<Account> extraAccounts = const <Account>[],
    bool withCard = true,
  }) {
    final FakeClock clock = FakeClock();
    final FakePasswordHasher hasher = FakePasswordHasher();
    final InMemoryAccountRepository accounts = InMemoryAccountRepository(<Account>[
      Account(id: "a1", username: "admin", passwordHash: "fake:$adminPassword", createdAt: clock.now()),
      ...extraAccounts,
    ]);

    final MemoryStorageBackend phone = MemoryStorageBackend(id: "r1")
      ..seedFile("/readme.txt", utf8.encode("hello world"))
      ..seedDirectory("/docs")
      ..seedFile("/docs/a.txt", utf8.encode("A"));
    final MemoryStorageBackend card = MemoryStorageBackend(id: "r2")..seedFile("/photo.jpg", utf8.encode("jpg"));

    final Map<String, MemoryStorageBackend> backends = <String, MemoryStorageBackend>{"r1": phone, "r2": card};
    final InMemoryStorageRootRepository roots = InMemoryStorageRootRepository(
      initial: <StorageRoot>[
        _root("r1", "Phone"),
        if (withCard) _root("r2", "Card", capabilities: const StorageCapabilities.readOnly()),
      ],
    );
    final FileRepositoryImpl files = FileRepositoryImpl(resolveBackend: (StorageRoot root) => backends[root.id]!);
    final StorageGate gate = StorageGate(roots: roots, authorizer: authorizer);

    final SessionManager sessions = SessionManager(store: InMemorySessionStore(), clock: clock);
    final LoginService login = LoginService(
      accounts: accounts,
      hasher: hasher,
      sessions: sessions,
      perAccountThrottle: LoginThrottle(clock: clock),
      perAddressThrottle: LoginThrottle(clock: clock, freeAttempts: 20),
    );
    final DavAuthenticator auth = DavAuthenticator(login: login, accounts: accounts, clock: clock);
    final InMemoryRecycleBinRepository recycleBin = InMemoryRecycleBinRepository();

    final FtpDeps deps = FtpDeps(
      gate: gate,
      files: files,
      delete: DeleteItemsToRecycleBin(files, recycleBin, clock, UuidIdGenerator()),
      move: MoveItems(files),
      auth: auth,
      activity: ActivityLog.none(),
    );

    final FtpServer server = FtpServer(
      deps: deps,
      settings: settings,
      now: clock.now,
      tlsContext: tls,
      limits: limits,
      privateClientsOnly: privateClientsOnly,
    );

    return FtpHarness._(
      clock: clock,
      hasher: hasher,
      phone: phone,
      card: card,
      accounts: accounts,
      recycleBin: recycleBin,
      server: server,
    );
  }

  static const String adminPassword = "correct horse battery";

  static StorageRoot _root(
    String id,
    String name, {
    StorageCapabilities capabilities = const StorageCapabilities.fullLocal(),
  }) => StorageRoot(
    id: id,
    displayName: name,
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://$id",
    capabilities: capabilities,
    freeBytes: 100000,
    totalBytes: 200000,
  );

  final FakeClock clock;
  final FakePasswordHasher hasher;
  final MemoryStorageBackend phone;
  final MemoryStorageBackend card;
  final InMemoryAccountRepository accounts;
  final RecycleBinRepository recycleBin;
  final FtpServer server;

  /// Starts listening on loopback and returns the bound port.
  Future<int> start() async {
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    return server.port!;
  }

  Future<void> stop() => server.stop();
}

/// A minimal raw FTP client for tests: one control connection, line-based
/// replies. Data connections (PASV) are opened separately by the test itself
/// since each transfer's needs differ too much for one helper method.
///
/// Uses [StreamIterator] (`dart:async`, no extra package) rather than
/// `package:async`'s `StreamQueue`, since this repo doesn't declare that
/// package as a dependency.
final class FtpTestClient {
  FtpTestClient._(this._socket, this._lines);

  final Socket _socket;
  final StreamIterator<String> _lines;

  static Future<FtpTestClient> connect(int port, {InternetAddress? sourceAddress}) async {
    final Socket socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      sourceAddress: sourceAddress,
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    final StreamIterator<String> lines = StreamIterator<String>(
      socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()),
    );
    return FtpTestClient._(socket, lines);
  }

  Socket get socket => _socket;

  /// Reads one reply "block": for a single-line reply, just that line; for a
  /// multi-line reply (`211-...` ... `211 ...`), every line up to and
  /// including the one that repeats the code followed by a space.
  Future<List<String>> readReply() async {
    final List<String> out = <String>[];
    while (true) {
      final bool has = await _lines.moveNext().timeout(const Duration(seconds: 5));
      if (!has) break;
      final String line = _lines.current;
      out.add(line);
      final RegExpMatch? m = RegExp(r"^(\d{3})(.)").firstMatch(line);
      if (m != null && m.group(2) == " ") break;
    }
    return out;
  }

  /// Sends a command and returns its (single- or multi-line) reply.
  Future<List<String>> send(String command) async {
    _socket.add(utf8.encode("$command\r\n"));
    await _socket.flush();
    return readReply();
  }

  /// The reply code of a (possibly multi-line) reply block.
  static int codeOf(List<String> reply) => int.parse(reply.first.substring(0, 3));

  Future<void> close() async {
    await _lines.cancel();
    _socket.destroy();
  }
}
