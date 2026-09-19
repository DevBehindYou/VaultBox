import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/app/providers.dart";
import "package:vaultbox/data/repositories/file_repository_impl.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/data/repositories/in_memory_storage_root_repository.dart";
import "package:vaultbox/data/security/in_memory_session_store.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/security/login_service.dart";
import "package:vaultbox/domain/security/login_throttle.dart";
import "package:vaultbox/domain/security/session_manager.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/server/api/vault_api.dart";
import "package:vaultbox/server/request_router.dart";

import "../helpers/fake_clock.dart";
import "../helpers/fake_password_hasher.dart";

/// The API through the real HTTP stack (plain loopback sockets; TLS is the
/// listener's job): headers, bodies, status codes as a client sees them.
void main() {
  const String password = "correct horse battery";

  late HttpServer server;
  late Uri base;

  VaultApi buildApi() {
    final FakeClock clock = FakeClock();
    final InMemoryAccountRepository accounts = InMemoryAccountRepository(<Account>[
      Account(id: "a1", username: "admin", passwordHash: "fake:$password", createdAt: clock.now()),
    ]);
    final SessionManager sessions = SessionManager(store: InMemorySessionStore(), clock: clock);
    final MemoryStorageBackend backend = MemoryStorageBackend(id: "r1")
      ..seedFile("/hello.txt", utf8.encode("hi"));
    final BackendRegistry registry = BackendRegistry()..register(backend);
    return VaultApi(
      login: LoginService(
        accounts: accounts,
        hasher: FakePasswordHasher(),
        sessions: sessions,
        perAccountThrottle: LoginThrottle(clock: clock),
        perAddressThrottle: LoginThrottle(clock: clock, freeAttempts: 20),
      ),
      sessions: sessions,
      accounts: accounts,
      roots: InMemoryStorageRootRepository(
        initial: const <StorageRoot>[
          StorageRoot(
            id: "r1",
            displayName: "Phone",
            backendType: StorageBackendType.memory,
            uriOrPath: "memory://r1",
            capabilities: StorageCapabilities.fullLocal(),
          ),
        ],
      ),
      files: FileRepositoryImpl(resolveBackend: registry.forRoot),
    );
  }

  Future<void> serveWith(RequestRouter router) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(router.serve(server));
    base = Uri(scheme: "http", host: "127.0.0.1", port: server.port);
  }

  tearDown(() => server.close(force: true));

  Future<(int, HttpHeaders, String)> send(
    String method,
    String path, {
    Object? json,
    List<int>? rawBody,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.openUrl(method, base.resolve(path));
      headers.forEach(request.headers.set);
      final List<int>? bytes = rawBody ?? (json == null ? null : utf8.encode(jsonEncode(json)));
      if (bytes != null) {
        request.headers.contentType = ContentType.json;
        request.add(bytes);
      }
      final HttpClientResponse response = await request.close();
      final String text = await utf8.decoder.bind(response).join();
      return (response.statusCode, response.headers, text);
    } finally {
      client.close();
    }
  }

  Future<String> loginToken() async {
    final (int status, _, String text) = await send(
      "POST",
      "/api/v1/auth/login",
      json: <String, Object?>{"username": "admin", "password": password},
    );
    expect(status, 200);
    return (jsonDecode(text) as Map<String, Object?>)["token"]! as String;
  }

  group("with the API mounted", () {
    setUp(() => serveWith(RequestRouter(api: buildApi())));

    test("login, then use the token", () async {
      final String token = await loginToken();

      final (int status, HttpHeaders headers, String text) = await send(
        "GET",
        "/api/v1/me",
        headers: <String, String>{"Authorization": "Bearer $token"},
      );

      expect(status, 200);
      expect(jsonDecode(text), <String, Object?>{"id": "a1", "username": "admin"});
      expect(headers.contentType?.mimeType, "application/json");
      expect(headers.value("cache-control"), "no-store");
      expect(headers.value("x-content-type-options"), "nosniff");
    });

    test("the Bearer scheme is case-insensitive", () async {
      final String token = await loginToken();
      final (int status, _, _) = await send(
        "GET",
        "/api/v1/roots",
        headers: <String, String>{"Authorization": "bearer $token"},
      );
      expect(status, 200);
    });

    test("query parameters reach the API (a folder listing)", () async {
      final String token = await loginToken();
      final (int status, _, String text) = await send(
        "GET",
        "/api/v1/roots/r1/entries?path=%2F&limit=10",
        headers: <String, String>{"Authorization": "Bearer $token"},
      );

      expect(status, 200);
      final Map<String, Object?> json = jsonDecode(text) as Map<String, Object?>;
      expect(((json["entries"]! as List<Object?>).single! as Map<String, Object?>)["name"], "hello.txt");
    });

    test("no token: 401 with a Bearer challenge", () async {
      final (int status, HttpHeaders headers, String text) = await send("GET", "/api/v1/me");

      expect(status, 401);
      expect(headers.value("www-authenticate"), "Bearer");
      expect(jsonDecode(text), <String, Object?>{"error": "unauthorized"});
    });

    test("other Authorization schemes and empty tokens don't authenticate", () async {
      for (final String header in <String>["Basic YWRtaW46eA==", "Bearer", "Bearer ", "token abc"]) {
        final (int status, _, _) = await send("GET", "/api/v1/me", headers: <String, String>{"Authorization": header});
        expect(status, 401, reason: header);
      }
    });

    test("a body over the limit is refused with 413", () async {
      final (int status, _, String text) = await send(
        "POST",
        "/api/v1/auth/login",
        rawBody: List<int>.filled(RequestRouter.maxBodyBytes + 1, 0x20),
      );

      expect(status, 413);
      expect(jsonDecode(text), <String, Object?>{"error": "payload_too_large"});
    });

    test("garbage JSON is a 400, not a crash", () async {
      final (int status, _, _) = await send("POST", "/api/v1/auth/login", rawBody: utf8.encode("{nope"));
      expect(status, 400);
    });

    test("/health/ still answers, and the API prefix doesn't swallow other paths", () async {
      expect((await send("GET", "/health/")).$1, 200);
      expect((await send("GET", "/apiary")).$1, 404);
      expect((await send("GET", "/")).$1, 404);
    });
  });

  group("without the API", () {
    setUp(() => serveWith(const RequestRouter()));

    test("/api/v1 is simply not there", () async {
      final (int status, _, String text) = await send("GET", "/api/v1/me");

      expect(status, 404);
      expect(jsonDecode(text), <String, Object?>{"error": "not_found"});
    });
  });
}
