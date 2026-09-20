import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/data/repositories/file_repository_impl.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/data/repositories/in_memory_share_repository.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/diagnostic.dart";
import "package:vaultbox/domain/entities/server_config.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/domain/entities/share.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/repositories/server_host.dart";
import "package:vaultbox/domain/usecases/run_diagnostics.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";

import "../helpers/fake_clock.dart";

/// A host whose answers the test chooses, including failing ones.
final class _StubHost implements ServerHost {
  _StubHost({
    this.state = const ServerState.stopped(),
    this.serverConfig = const ServerConfig(),
    this.fingerprint = "AB:CD:EF",
    this.configFails = false,
  });

  final ServerState state;
  final ServerConfig serverConfig;
  final String fingerprint;
  final bool configFails;

  @override
  Stream<ServerState> watch() => Stream<ServerState>.value(state);

  @override
  Future<ServerConfig> config() async {
    if (configFails) throw StateError("native side is gone");
    return serverConfig;
  }

  @override
  Future<String> tlsFingerprint() async => fingerprint;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> saveConfig(ServerConfig config) async {}
}

void main() {
  StorageRoot root({
    String id = "mem",
    String name = "Phone storage",
    bool enabled = true,
    bool available = true,
    StorageCapabilities capabilities = const StorageCapabilities.fullLocal(),
  }) => StorageRoot(
    id: id,
    displayName: name,
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://$id",
    capabilities: capabilities,
    isEnabled: enabled,
    isAvailable: available,
  );

  final Account admin = Account(id: "a1", username: "admin", passwordHash: "x", createdAt: DateTime.utc(2026));
  Account member(String id, {bool enabled = true}) => Account(
    id: id,
    username: id,
    passwordHash: "x",
    createdAt: DateTime.utc(2026),
    role: AccountRole.member,
    isEnabled: enabled,
  );

  final FakeClock clock = FakeClock(DateTime.utc(2026, 9, 20, 12));

  Future<List<DiagnosticCheck>> run({
    List<StorageRoot>? roots,
    List<Account>? accounts,
    List<Share> shares = const <Share>[],
    ServerHost? host,
  }) {
    final BackendRegistry registry = BackendRegistry();
    for (final StorageRoot r in roots ?? <StorageRoot>[root()]) {
      registry.register(MemoryStorageBackend(id: r.id));
    }
    return RunDiagnostics(
      roots: InMemoryStorageRootRepository(initial: roots ?? <StorageRoot>[root()]),
      files: FileRepositoryImpl(resolveBackend: registry.forRoot),
      accounts: InMemoryAccountRepository(accounts ?? <Account>[admin]),
      shares: InMemoryShareRepository(shares),
      server: host ?? _StubHost(),
      clock: clock,
    )();
  }

  DiagnosticCheck only(List<DiagnosticCheck> checks, String title, {String? subject}) => checks.singleWhere(
    (DiagnosticCheck c) => c.title == title && (subject == null || c.subject == subject),
  );

  test("a healthy phone has nothing but OKs", () async {
    final List<DiagnosticCheck> checks = await run();

    expect(checks.map((DiagnosticCheck c) => c.status).toSet(), <DiagnosticStatus>{DiagnosticStatus.ok});
    expect(checks.map((DiagnosticCheck c) => c.title), <String>[
      "Storage location",
      "Accounts",
      "Server",
      "Connections",
      "Encryption certificate",
      "Links",
    ]);
  });

  group("storage", () {
    test("a location that works says whether it can be written", () async {
      final List<DiagnosticCheck> checks = await run(
        roots: <StorageRoot>[
          root(),
          root(id: "sd", name: "SD card", capabilities: const StorageCapabilities.readOnly()),
        ],
      );

      expect(only(checks, "Storage location", subject: "Phone storage").detail, "Readable and writable.");
      expect(only(checks, "Storage location", subject: "SD card").detail, "Readable, but read-only.");
    });

    test("no location at all is a warning that says where to fix it", () async {
      final DiagnosticCheck check = only(await run(roots: <StorageRoot>[]), "Storage location");

      expect(check.status, DiagnosticStatus.warning);
      expect(check.hint, contains("Files"));
    });

    test("a location that can't be reached is a problem, named, with advice", () async {
      final DiagnosticCheck check = only(
        await run(roots: <StorageRoot>[root(available: false, name: "USB drive")]),
        "Storage location",
      );

      expect(check.status, DiagnosticStatus.problem);
      expect(check.subject, "USB drive");
      expect(check.hint, contains("plug"));
    });

    test("a turned-off location is left out", () async {
      final List<DiagnosticCheck> checks = await run(
        roots: <StorageRoot>[root(), root(id: "off", name: "Old card", enabled: false)],
      );

      expect(checks.where((DiagnosticCheck c) => c.subject == "Old card"), isEmpty);
    });
  });

  group("accounts", () {
    test("counts who can sign in", () async {
      final DiagnosticCheck check = only(
        await run(accounts: <Account>[admin, member("bob"), member("ann"), member("off", enabled: false)]),
        "Accounts",
      );

      expect(check.status, DiagnosticStatus.ok);
      expect(check.detail, "1 admin and 2 members can sign in.");
    });

    test("no admin is a problem", () async {
      final DiagnosticCheck check = only(await run(accounts: <Account>[member("bob")]), "Accounts");

      expect(check.status, DiagnosticStatus.problem);
      expect(check.hint, contains("Home"));
    });
  });

  group("server", () {
    test("off is fine: it says nothing is reachable", () async {
      final DiagnosticCheck check = only(await run(), "Server");

      expect(check.status, DiagnosticStatus.ok);
      expect(check.detail, contains("Nothing is reachable"));
    });

    test("running counts its addresses", () async {
      final DiagnosticCheck check = only(
        await run(
          host: _StubHost(
            state: const ServerState(
              run: ServerRunState.running,
              endpoint: "https://192.168.1.5:8443/",
              endpoints: <String>["https://192.168.1.5:8443/", "http://192.168.1.5:8080/"],
            ),
          ),
        ),
        "Server",
      );

      expect(check.status, DiagnosticStatus.ok);
      expect(check.detail, "Running on 2 addresses.");
    });

    test("a server that failed to start is a problem carrying the reason", () async {
      final DiagnosticCheck check = only(
        await run(host: _StubHost(state: const ServerState(run: ServerRunState.failed, detail: "Address already in use"))),
        "Server",
      );

      expect(check.status, DiagnosticStatus.problem);
      expect(check.detail, contains("Address already in use"));
      expect(check.hint, contains("port"));
    });

    test("still starting is only a warning", () async {
      final DiagnosticCheck check = only(
        await run(host: _StubHost(state: const ServerState(run: ServerRunState.starting))),
        "Server",
      );

      expect(check.status, DiagnosticStatus.warning);
    });
  });

  group("connections", () {
    Future<DiagnosticCheck> connections(ServerConfig config) async =>
        only(await run(host: _StubHost(serverConfig: config)), "Connections");

    test("nothing switched on is a problem", () async {
      final DiagnosticCheck check = await connections(const ServerConfig(httpsEnabled: false));

      expect(check.status, DiagnosticStatus.problem);
    });

    test("plain HTTP open to the network is a warning, even next to HTTPS", () async {
      final DiagnosticCheck both = await connections(const ServerConfig(allowNetworkAccess: true, httpEnabled: true));
      final DiagnosticCheck onlyHttp = await connections(
        const ServerConfig(allowNetworkAccess: true, httpEnabled: true, httpsEnabled: false),
      );

      expect(both.status, DiagnosticStatus.warning);
      expect(onlyHttp.status, DiagnosticStatus.warning);
      expect(onlyHttp.detail, contains("Only plain HTTP"));
    });

    test("HTTPS on the network, or anything on this phone alone, is fine", () async {
      expect((await connections(const ServerConfig(allowNetworkAccess: true))).status, DiagnosticStatus.ok);
      expect((await connections(const ServerConfig(httpEnabled: true))).detail, "Only this phone can connect.");
    });
  });

  group("certificate", () {
    test("present is fine", () async {
      expect(only(await run(), "Encryption certificate").status, DiagnosticStatus.ok);
    });

    test("missing is a problem", () async {
      final DiagnosticCheck check = only(await run(host: _StubHost(fingerprint: "  ")), "Encryption certificate");

      expect(check.status, DiagnosticStatus.problem);
    });

    test("not needed when HTTPS is off", () async {
      final DiagnosticCheck check = only(
        await run(host: _StubHost(serverConfig: const ServerConfig(httpsEnabled: false, httpEnabled: true), fingerprint: "")),
        "Encryption certificate",
      );

      expect(check.status, DiagnosticStatus.ok);
      expect(check.detail, "HTTPS is off.");
    });
  });

  group("links", () {
    Share share(String id, {DateTime? expires}) => Share(
      id: id,
      kind: ShareKind.download,
      rootId: "mem",
      path: "/x",
      isDirectory: false,
      createdBy: "a1",
      createdAt: clock.now(),
      tokenHash: "hash-$id",
      expiresAt: expires,
    );

    test("none, and active versus finished", () async {
      expect(only(await run(), "Links").detail, "No links have been made.");

      final DiagnosticCheck check = only(
        await run(
          shares: <Share>[
            share("live"),
            share("old", expires: clock.now().subtract(const Duration(days: 1))),
            share("also-old", expires: clock.now().subtract(const Duration(hours: 1))),
          ],
        ),
        "Links",
      );
      expect(check.detail, "1 active link and 2 expired or used up.");
    });
  });

  test("a check that can't run is reported, and the others still run", () async {
    final List<DiagnosticCheck> checks = await run(host: _StubHost(configFails: true));

    expect(only(checks, "Connections").status, DiagnosticStatus.problem);
    expect(only(checks, "Connections").detail, contains("couldn't be carried out"));
    expect(only(checks, "Encryption certificate").status, DiagnosticStatus.problem);
    expect(only(checks, "Accounts").status, DiagnosticStatus.ok);
    expect(only(checks, "Server").status, DiagnosticStatus.ok);
  });
}
