import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/server/api/api_json.dart";
import "package:vaultbox/server/api/vault_api.dart";
import "package:vaultbox/server/request_router.dart";

import "../helpers/api_harness.dart";

/// The API through the real HTTP stack (plain loopback sockets; TLS is the
/// listener's job): headers, bodies, status codes as a client sees them.
void main() {
  const String password = ApiHarness.password;

  late HttpServer server;
  late Uri base;

  VaultApi buildApi() {
    final MemoryStorageBackend backend = MemoryStorageBackend(id: "r1")
      ..seedFile("/hello.txt", utf8.encode("hi"));
    return ApiHarness(backend: backend).api;
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
      expect(jsonDecode(text), <String, Object?>{"id": "a1", "username": "admin", "role": "admin"});
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
        rawBody: List<int>.filled(maxJsonBodyBytes + 1, 0x20),
      );

      expect(status, 413);
      expect(jsonDecode(text), <String, Object?>{"error": "payload_too_large"});
    });

    test("garbage JSON is a 400, not a crash", () async {
      final (int status, _, _) = await send("POST", "/api/v1/auth/login", rawBody: utf8.encode("{nope"));
      expect(status, 400);
    });

    test("upload, download, byte range and HEAD over real HTTP", () async {
      final String token = await loginToken();
      final Map<String, String> auth = <String, String>{"Authorization": "Bearer $token"};
      final String payload = String.fromCharCodes(List<int>.generate(50000, (int i) => 97 + i % 26));

      final (int putStatus, _, String putText) = await send(
        "PUT",
        "/api/v1/roots/r1/content?path=%2Fbig.txt",
        rawBody: utf8.encode(payload),
        headers: auth,
      );
      expect(putStatus, 201);
      expect(jsonDecode(putText), <String, Object?>{"path": "/big.txt", "size": 50000});

      final (int getStatus, HttpHeaders getHeaders, String getText) = await send(
        "GET",
        "/api/v1/roots/r1/content?path=%2Fbig.txt",
        headers: auth,
      );
      expect(getStatus, 200);
      expect(getText, payload);
      expect(getHeaders.value("content-length"), "50000");
      expect(getHeaders.value("accept-ranges"), "bytes");
      expect(getHeaders.value("content-disposition"), startsWith("attachment;"));

      final (int rangeStatus, HttpHeaders rangeHeaders, String rangeText) = await send(
        "GET",
        "/api/v1/roots/r1/content?path=%2Fbig.txt",
        headers: <String, String>{...auth, "Range": "bytes=10-19"},
      );
      expect(rangeStatus, 206);
      expect(rangeText, payload.substring(10, 20));
      expect(rangeHeaders.value("content-range"), "bytes 10-19/50000");

      final (int headStatus, HttpHeaders headHeaders, String headText) = await send(
        "HEAD",
        "/api/v1/roots/r1/content?path=%2Fbig.txt",
        headers: auth,
      );
      expect(headStatus, 200);
      expect(headHeaders.value("content-length"), "50000");
      expect(headText, isEmpty);

      final (int badRange, _, _) = await send(
        "GET",
        "/api/v1/roots/r1/content?path=%2Fbig.txt",
        headers: <String, String>{...auth, "Range": "bytes=60000-"},
      );
      expect(badRange, 416);
    });

    test("an upload without a token is refused and stores nothing", () async {
      final (int status, _, _) = await send(
        "PUT",
        "/api/v1/roots/r1/content?path=%2Fsneaky.txt",
        rawBody: utf8.encode("x"),
      );
      expect(status, 401);

      final String token = await loginToken();
      final (int listStatus, _, String listing) = await send(
        "GET",
        "/api/v1/roots/r1/entries",
        headers: <String, String>{"Authorization": "Bearer $token"},
      );
      expect(listStatus, 200);
      expect(listing, isNot(contains("sneaky")));
    });

    test("path traversal in a query string is refused", () async {
      final String token = await loginToken();
      final (int status, _, _) = await send(
        "GET",
        "/api/v1/roots/r1/content?path=%2E%2E%2F%2E%2E%2Fetc%2Fpasswd",
        headers: <String, String>{"Authorization": "Bearer $token"},
      );
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
