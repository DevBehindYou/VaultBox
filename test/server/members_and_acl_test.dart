import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/access_rule.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/security/authorizer.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/server/api/api_types.dart";

import "../helpers/api_harness.dart";

/// Members through the real API stack: the Authorizer, the gate and the
/// endpoints together, with accounts changing underneath live sessions.
void main() {
  const String bobPassword = "bobs long password";

  late ApiHarness h;
  late MemoryStorageBackend backend;

  Account bob({List<AccessRule> rules = const <AccessRule>[], bool enabled = true}) => Account(
    id: "m1",
    username: "bob",
    passwordHash: "fake:$bobPassword",
    createdAt: DateTime.utc(2026),
    role: AccountRole.member,
    isEnabled: enabled,
    rules: rules,
  );

  AccessRule grant(String path, Set<Permission> permissions) =>
      AccessRule(id: "rule$path", accountId: "m1", rootId: "r1", pathPrefix: path, permissions: permissions);

  Future<void> start({List<AccessRule>? rules}) async {
    backend = MemoryStorageBackend(id: "r1")
      ..seedFile("/readme.txt", utf8.encode("root file"))
      ..seedDirectory("/Photos")
      ..seedFile("/Photos/a.jpg", utf8.encode("jpg-a"))
      ..seedFile("/Photos/sub/b.jpg", utf8.encode("jpg-b"))
      ..seedFile("/Documents/secret.txt", utf8.encode("secret"));
    h = ApiHarness(
      backend: backend,
      authorizer: const AclAuthorizer(),
      roots: <StorageRoot>[ApiHarness.root(), ApiHarness.root(id: "r2", name: "Card")],
      extraAccounts: <Account>[bob(rules: rules ?? <AccessRule>[grant("/Photos", AccessRule.readWrite)])],
    );
  }

  setUp(start);

  StoragePath sp(String value) => StoragePath.parseDecoded("r1", value);

  Future<String> bobToken() => h.login(username: "bob", pass: bobPassword);

  Future<ApiResponse> get(String token, String path, [Map<String, String> query = const <String, String>{}]) =>
      h.send("GET", path, token: token, query: query);

  Map<String, Object?> body(ApiResponse r) => ApiHarness.json(r);

  List<String> names(ApiResponse r) =>
      (body(r)["entries"]! as List<Object?>).map((Object? e) => (e! as Map<String, Object?>)["name"]! as String).toList();

  test("who am I says member", () async {
    final ApiResponse me = await get(await bobToken(), "/api/v1/me");
    expect(body(me)["role"], "member");
    expect(body(me)["username"], "bob");
  });

  test("a member sees only the storage locations they were given something in", () async {
    final ApiResponse roots = await get(await bobToken(), "/api/v1/roots");
    expect(((body(roots)["roots"]! as List<Object?>).single! as Map<String, Object?>)["id"], "r1");

    final ApiResponse adminRoots = await get(await h.login(), "/api/v1/roots");
    expect((body(adminRoots)["roots"]! as List<Object?>).length, 2);
  });

  test("the top folder shows only the way down to what was granted", () async {
    final String token = await bobToken();

    expect(names(await get(token, "/api/v1/roots/r1/entries")), <String>["Photos"]);
    expect(names(await get(token, "/api/v1/roots/r1/entries", <String, String>{"path": "/Photos"})).toSet(), <String>{"a.jpg", "sub"});

    final ApiResponse admin = await get(await h.login(), "/api/v1/roots/r1/entries");
    expect(names(admin).toSet(), <String>{"readme.txt", "Photos", "Documents"});
  });

  test("outside the grant: listing, download, stat and links are all 403", () async {
    final String token = await bobToken();
    final Map<String, String> secret = <String, String>{"path": "/Documents/secret.txt"};

    expect((await get(token, "/api/v1/roots/r1/entries", <String, String>{"path": "/Documents"})).status, 403);
    expect((await get(token, "/api/v1/roots/r1/content", secret)).status, 403);
    expect((await get(token, "/api/v1/roots/r1/stat", secret)).status, 403);
    expect((await h.send("POST", "/api/v1/roots/r1/ticket", token: token, json: <String, Object?>{"path": "/Documents/secret.txt"})).status, 403);
    expect((await get(token, "/api/v1/roots/r1/content", <String, String>{"path": "/readme.txt"})).status, 403);
  });

  test("inside the grant: read and write work, delete does not", () async {
    final String token = await bobToken();

    final ApiResponse download = await get(token, "/api/v1/roots/r1/content", <String, String>{"path": "/Photos/a.jpg"});
    expect(download.status, 200);
    expect(utf8.decode(await ApiHarness.bodyBytes(download)), "jpg-a");

    final ApiResponse upload = await h.send(
      "PUT",
      "/api/v1/roots/r1/content",
      token: token,
      query: <String, String>{"path": "/Photos/new.jpg"},
      bytes: utf8.encode("new"),
    );
    expect(upload.status, 201);

    final ApiResponse folder = await h.send("POST", "/api/v1/roots/r1/mkdir", token: token, json: <String, Object?>{"path": "/Photos/album"});
    expect(folder.status, 201);

    final ApiResponse delete = await h.send("POST", "/api/v1/roots/r1/delete", token: token, json: <String, Object?>{
      "paths": <String>["/Photos/a.jpg"],
    });
    expect(delete.status, 403, reason: "delete wasn't granted");
    expect((await backend.stat(sp("/Photos/a.jpg"))).exists, isTrue);
  });

  test("writing outside the grant, or above it, is refused", () async {
    final String token = await bobToken();

    for (final String path in <String>["/new.txt", "/Documents/new.txt", "/Photos2/new.txt"]) {
      final ApiResponse response = await h.send(
        "PUT",
        "/api/v1/roots/r1/content",
        token: token,
        query: <String, String>{"path": path},
        bytes: utf8.encode("x"),
      );
      expect(response.status, 403, reason: path);
    }
  });

  test("moving in from outside needs read there; moving out needs delete", () async {
    final String token = await bobToken();

    final ApiResponse pullIn = await h.send("POST", "/api/v1/roots/r1/copy", token: token, json: <String, Object?>{
      "sources": <String>["/Documents/secret.txt"],
      "destination": "/Photos",
    });
    expect(pullIn.status, 403, reason: "can't copy what can't be read");

    final ApiResponse moveOut = await h.send("POST", "/api/v1/roots/r1/move", token: token, json: <String, Object?>{
      "sources": <String>["/Photos/a.jpg"],
      "destination": "/Photos/sub",
    });
    expect(moveOut.status, 403, reason: "moving deletes the source, which wasn't granted");
  });

  test("a folder-wide grant with delete lets a member delete inside it", () async {
    await start(rules: <AccessRule>[grant("/Photos", AccessRule.everything)]);
    final String token = await bobToken();

    final ApiResponse delete = await h.send("POST", "/api/v1/roots/r1/delete", token: token, json: <String, Object?>{
      "paths": <String>["/Photos/a.jpg"],
    });
    expect(delete.status, 200);
    expect((await backend.stat(sp("/Photos/a.jpg"))).exists, isFalse);
  });

  test("changing the rules takes effect on the very next request", () async {
    final String token = await bobToken();
    expect((await get(token, "/api/v1/roots/r1/entries", <String, String>{"path": "/Documents"})).status, 403);

    await h.accounts.replaceRules("m1", <AccessRule>[grant("/Documents", AccessRule.readOnly)]);

    expect((await get(token, "/api/v1/roots/r1/entries", <String, String>{"path": "/Documents"})).status, 200);
    expect((await get(token, "/api/v1/roots/r1/entries", <String, String>{"path": "/Photos"})).status, 403);
  });

  group("sessions end when the account changes", () {
    test("disabling logs the member out at once, and login is refused", () async {
      final String token = await bobToken();
      expect((await get(token, "/api/v1/me")).status, 200);

      await h.accounts.setEnabled("m1", enabled: false);

      expect((await get(token, "/api/v1/me")).status, 401);
      await expectLater(h.login(username: "bob", pass: bobPassword), throwsStateError);
    });

    test("a new password ends every old session", () async {
      final String token = await bobToken();
      await h.accounts.updatePasswordHash("m1", "fake:a brand new password");

      expect((await get(token, "/api/v1/me")).status, 401);
      expect((await get(await h.login(username: "bob", pass: "a brand new password"), "/api/v1/me")).status, 200);
    });

    test("removing the account ends its sessions", () async {
      final String token = await bobToken();
      await h.accounts.delete("m1");
      expect((await get(token, "/api/v1/me")).status, 401);
    });

    test("re-enabling doesn't revive old sessions' access to a NEW password", () async {
      final String token = await bobToken();
      await h.accounts.setEnabled("m1", enabled: false);
      await h.accounts.setEnabled("m1", enabled: true);

      expect((await get(token, "/api/v1/me")).status, 401, reason: "disabling bumped the version");
      expect((await get(await bobToken(), "/api/v1/me")).status, 200);
    });
  });

  test("a download link made by a member stops working when their access is taken away", () async {
    final String token = await bobToken();
    final ApiResponse made = await h.send("POST", "/api/v1/roots/r1/ticket", token: token, json: <String, Object?>{"path": "/Photos/a.jpg"});
    final String url = body(made)["url"]! as String;
    expect((await h.send("GET", url)).status, 200);

    await h.accounts.replaceRules("m1", const <AccessRule>[]);

    expect((await h.send("GET", url)).status, 403);
  });
}

