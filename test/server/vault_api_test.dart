import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/server/api/api_types.dart";

import "../helpers/api_harness.dart";

/// The API's own behaviour, called directly (no sockets): login, sessions,
/// throttling, and what is and isn't exposed about storage.
void main() {
  late ApiHarness h;

  setUp(() {
    final MemoryStorageBackend backend = MemoryStorageBackend(id: "r1")
      ..seedFile("/readme.txt", utf8.encode("hello"))
      ..seedDirectory("/docs")
      ..seedFile("/docs/a.txt", utf8.encode("a"))
      ..seedFile("/.vaultbox/recycle/x__old.txt", utf8.encode("bin"));
    h = ApiHarness(
      backend: backend,
      roots: <StorageRoot>[
        ApiHarness.root(),
        ApiHarness.root(id: "off", name: "Disabled", enabled: false),
        ApiHarness.root(id: "gone", name: "Unplugged", available: false),
      ],
    );
  });

  Map<String, Object?> body(ApiResponse response) => ApiHarness.json(response);

  Future<ApiResponse> login(String user, String password) =>
      h.send("POST", "/api/v1/auth/login", json: <String, Object?>{"username": user, "password": password});

  group("login", () {
    test("returns a bearer token and who you are — and nothing about the password", () async {
      final ApiResponse response = await login("Admin", ApiHarness.password);

      expect(response.status, 200);
      final Map<String, Object?> json = body(response);
      expect(json["tokenType"], "Bearer");
      expect((json["token"]! as String).length, greaterThanOrEqualTo(40));
      expect(json["user"], <String, Object?>{"id": "a1", "username": "admin"});
      expect(json["idleTimeoutSeconds"], 30 * 60);
      expect(jsonEncode(json), isNot(contains("fake:")), reason: "no hash may leave the phone");
    });

    test("wrong credentials are a plain 401", () async {
      final ApiResponse response = await login("admin", "nope nope nope");

      expect(response.status, 401);
      expect(body(response), <String, Object?>{"error": "invalid_credentials"});
    });

    test("malformed bodies are 400", () async {
      for (final Object? bad in <Object?>[
        null,
        "not an object",
        <String, Object?>{},
        <String, Object?>{"username": "admin"},
        <String, Object?>{"username": 5, "password": ApiHarness.password},
      ]) {
        final ApiResponse response = await h.send("POST", "/api/v1/auth/login", json: bad);
        expect(response.status, 400, reason: "$bad");
      }
    });

    test("garbage bytes are 400 too", () async {
      final ApiResponse response = await h.send(
        "POST",
        "/api/v1/auth/login",
        bytes: const <int>[0xff, 0xfe, 0x7b],
      );
      expect(response.status, 400);
    });

    test("an oversized body is 413 and asks to close the connection", () async {
      final ApiResponse response = await h.send(
        "POST",
        "/api/v1/auth/login",
        bytes: List<int>.filled(20 * 1024, 0x20),
      );

      expect(response.status, 413);
      expect(response.closeConnection, isTrue);
    });

    test("repeated failures answer 429 with Retry-After", () async {
      for (int i = 0; i < 5; i++) {
        await login("admin", "wrong $i");
      }

      final ApiResponse response = await login("admin", ApiHarness.password);

      expect(response.status, 429);
      expect(response.headers["Retry-After"], "30");
      expect(body(response), <String, Object?>{"error": "too_many_attempts"});
    });

    test("only POST is allowed", () async {
      final ApiResponse response = await h.send("GET", "/api/v1/auth/login");
      expect(response.status, 405);
      expect(response.headers["allow"], "POST");
    });
  });

  group("authentication", () {
    test("no token: 401 with a Bearer challenge", () async {
      final ApiResponse response = await h.send("GET", "/api/v1/me");

      expect(response.status, 401);
      expect(response.headers["www-authenticate"], "Bearer");
      expect(body(response), <String, Object?>{"error": "unauthorized"});
    });

    test("a made-up token is 401", () async {
      expect((await h.send("GET", "/api/v1/me", token: "x" * 43)).status, 401);
    });

    test("strangers can't probe which routes exist: unknown paths are 401 too", () async {
      expect((await h.send("GET", "/api/v1/secrets")).status, 401);
      expect((await h.send("GET", "/api/v1")).status, 401);
      expect((await h.send("GET", "/api/v1/roots/r1/nothing")).status, 401);
    });

    test("a logged-in caller gets 404 for an unknown route", () async {
      final String token = await h.login();
      expect((await h.send("GET", "/api/v1/secrets", token: token)).status, 404);
      expect((await h.send("GET", "/api/v1/roots/r1/nothing", token: token)).status, 404);
    });

    test("/me returns the account", () async {
      final String token = await h.login();
      final ApiResponse response = await h.send("GET", "/api/v1/me", token: token);

      expect(response.status, 200);
      expect(body(response), <String, Object?>{"id": "a1", "username": "admin"});
    });

    test("logout revokes the token", () async {
      final String token = await h.login();

      expect((await h.send("POST", "/api/v1/auth/logout", token: token)).status, 204);
      expect((await h.send("GET", "/api/v1/me", token: token)).status, 401);
    });

    test("an idle session expires", () async {
      final String token = await h.login();
      h.clock.advance(const Duration(minutes: 31));

      expect((await h.send("GET", "/api/v1/me", token: token)).status, 401);
    });

    test("a session whose account no longer exists is refused and dropped", () async {
      final String ghost = (await h.sessions.issue(accountId: "deleted")).token;

      expect((await h.send("GET", "/api/v1/me", token: ghost)).status, 401);
      expect(await h.sessions.validate(ghost), isNull);
    });

    test("wrong methods on authenticated routes are 405", () async {
      final String token = await h.login();

      final ApiResponse me = await h.send("POST", "/api/v1/me", token: token);
      expect(me.status, 405);
      expect(me.headers["allow"], "GET");
      expect((await h.send("GET", "/api/v1/auth/logout", token: token)).status, 405);
      expect((await h.send("DELETE", "/api/v1/roots", token: token)).status, 405);
    });
  });

  group("roots", () {
    test("lists enabled roots and never the raw path or URI", () async {
      final String token = await h.login();
      final ApiResponse response = await h.send("GET", "/api/v1/roots", token: token);

      expect(response.status, 200);
      final List<Object?> roots = body(response)["roots"]! as List<Object?>;
      expect(roots.map((Object? r) => (r! as Map<String, Object?>)["id"]), <String>["r1", "gone"]);
      expect(roots.first, <String, Object?>{
        "id": "r1",
        "name": "Phone",
        "available": true,
        "writable": true,
        "isDefault": false,
        "freeBytes": 1000,
        "totalBytes": 5000,
      });
      expect(jsonEncode(response.json), isNot(contains("content://")));
      expect(jsonEncode(response.json), isNot(contains("Secret")));
    });
  });

  group("entries", () {
    Future<ApiResponse> list(String token, {String id = "r1", Map<String, String> query = const <String, String>{}}) =>
        h.send("GET", "/api/v1/roots/$id/entries", token: token, query: query);

    test("lists a folder with type, size and time — and hides .vaultbox at the top", () async {
      final String token = await h.login();
      final ApiResponse response = await list(token);

      expect(response.status, 200);
      final Map<String, Object?> json = body(response);
      expect(json["path"], "/");
      final List<Map<String, Object?>> entries =
          (json["entries"]! as List<Object?>).cast<Map<String, Object?>>();
      expect(entries.map((Map<String, Object?> e) => e["name"]).toSet(), <String>{"readme.txt", "docs"});
      final Map<String, Object?> file = entries.firstWhere((Map<String, Object?> e) => e["name"] == "readme.txt");
      expect(file["type"], "file");
      expect(file["size"], 5);
      expect(entries.firstWhere((Map<String, Object?> e) => e["name"] == "docs")["type"], "directory");
      expect(json["nextCursor"], isNull);
    });

    test("lists a subfolder", () async {
      final String token = await h.login();
      final ApiResponse response = await list(token, query: <String, String>{"path": "/docs"});

      expect(response.status, 200);
      expect(body(response)["path"], "/docs");
      final List<Object?> entries = body(response)["entries"]! as List<Object?>;
      expect((entries.single! as Map<String, Object?>)["name"], "a.txt");
    });

    test("pages with a cursor until the end", () async {
      final MemoryStorageBackend many = MemoryStorageBackend(id: "r1");
      for (final String name in <String>["a", "b", "c", "d", "e"]) {
        many.seedFile("/$name.txt", utf8.encode(name));
      }
      h = ApiHarness(backend: many);

      final String token = await h.login();
      final List<String> seen = <String>[];
      String? cursor;
      int pages = 0;
      do {
        final ApiResponse response = await list(
          token,
          query: <String, String>{"limit": "2", if (cursor != null) "cursor": cursor},
        );
        expect(response.status, 200);
        final Map<String, Object?> json = body(response);
        seen.addAll(
          (json["entries"]! as List<Object?>).map((Object? e) => (e! as Map<String, Object?>)["name"]! as String),
        );
        cursor = json["nextCursor"] as String?;
        pages++;
      } while (cursor != null && pages < 10);

      expect(seen, <String>["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]);
      expect(pages, 3);
    });

    test("bad limits are 400", () async {
      final String token = await h.login();
      for (final String limit in <String>["0", "501", "-1", "abc", ""]) {
        expect((await list(token, query: <String, String>{"limit": limit})).status, 400, reason: limit);
      }
    });

    test("unknown, disabled and unplugged roots", () async {
      final String token = await h.login();

      expect((await list(token, id: "nope")).status, 404);
      expect((await list(token, id: "off")).status, 404, reason: "a disabled root doesn't exist to clients");
      final ApiResponse gone = await list(token, id: "gone");
      expect(gone.status, 503);
      expect(body(gone), <String, Object?>{"error": "storage_unavailable"});
    });

    test("path traversal is rejected", () async {
      final String token = await h.login();
      for (final String path in <String>["/../etc", "/docs/../../x", "..", "/a/%2e%2e/b", "/x/%252e%252e/y", "C:\\Windows"]) {
        final ApiResponse response = await list(token, query: <String, String>{"path": path});
        expect(response.status, 400, reason: path);
        expect(body(response), <String, Object?>{"error": "invalid_path"});
      }
    });

    test("the recycle bin folder can't be listed or reached", () async {
      final String token = await h.login();
      for (final String path in <String>["/.vaultbox", "/.vaultbox/recycle", ".vaultbox/recycle/", "/.VaultBox"]) {
        expect((await list(token, query: <String, String>{"path": path})).status, 404, reason: path);
      }
    });

    test("a missing folder is 404 and a file is not a folder", () async {
      final String token = await h.login();

      expect((await list(token, query: <String, String>{"path": "/nope"})).status, 404);
      final ApiResponse file = await list(token, query: <String, String>{"path": "/readme.txt"});
      expect(file.status, 400);
      expect(body(file), <String, Object?>{"error": "not_a_directory"});
    });

    test("needs a token", () async {
      expect((await list("")).status, 401);
    });
  });
}
