import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/access_rule.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/share.dart";
import "package:vaultbox/domain/repositories/storage_backend.dart";
import "package:vaultbox/domain/security/authorizer.dart";
import "package:vaultbox/domain/security/share_tokens.dart";
import "package:vaultbox/domain/usecases/create_share.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/server/api/api_types.dart";

import "../helpers/api_harness.dart";

/// Share links: what a person with only a link can and can't do.
void main() {
  late ApiHarness h;
  late MemoryStorageBackend backend;

  final Account bob = Account(
    id: "m1",
    username: "bob",
    passwordHash: "fake:x",
    createdAt: DateTime.utc(2026),
    role: AccountRole.member,
    rules: const <AccessRule>[
      AccessRule(id: "r", accountId: "m1", rootId: "r1", pathPrefix: "/Photos", permissions: AccessRule.readOnly),
      AccessRule(id: "w", accountId: "m1", rootId: "r1", pathPrefix: "/Inbox", permissions: AccessRule.readWrite),
    ],
  );

  setUp(() async {
    backend = MemoryStorageBackend(id: "r1")
      ..seedFile("/readme.txt", utf8.encode("hello world"))
      ..seedFile("/Photos/a.jpg", utf8.encode("jpg-a"))
      ..seedFile("/Docs/a.txt", utf8.encode("A"))
      ..seedFile("/Docs/sub/b.txt", utf8.encode("B"))
      ..seedFile("/Secret/x.txt", utf8.encode("x"))
      ..seedDirectory("/Inbox")
      ..seedFile("/.vaultbox/recycle/x", utf8.encode("bin"));
    // (seedFile decodes %-sequences; a name that literally contains one is written the way the server does.)
    final StorageWriteHandle handle = await backend.openWrite(StoragePath.parseDecoded("r1", "/Docs/secret%20name.txt"));
    await handle.sink.addStream(Stream<List<int>>.value(utf8.encode("literal")));
    await handle.commit();

    h = ApiHarness(backend: backend, authorizer: const AclAuthorizer(), extraAccounts: <Account>[bob]);
  });

  StoragePath sp(String value) => StoragePath.parseDecoded("r1", value);
  Map<String, Object?> body(ApiResponse r) => ApiHarness.json(r);

  Future<ApiResponse> pub(String token, {String action = "", String method = "GET", Map<String, String> query = const <String, String>{}, Map<String, String> headers = const <String, String>{}, Object? json, List<int>? bytes, Stream<List<int>>? stream, String address = "203.0.113.9"}) =>
      h.send(method, "/api/v1/public/$token${action.isEmpty ? "" : "/$action"}", query: query, headers: headers, json: json, bytes: bytes, stream: stream, address: address);

  Future<String> textOf(ApiResponse r) async => utf8.decode(await ApiHarness.bodyBytes(r));

  Future<int> uses(CreatedShare made) async => (await h.shareRepository.get(made.share.id))!.useCount;

  group("looking at a link", () {
    test("a file link says what it is, without secrets", () async {
      final CreatedShare made = await h.makeShare(path: "/readme.txt");
      final ApiResponse info = await pub(made.token);

      expect(info.status, 200);
      expect(body(info), <String, Object?>{
        "kind": "download",
        "isDirectory": false,
        "requiresPassword": false,
        "unlocked": true,
        "name": "readme.txt",
        "size": 11,
        "expiresAt": null,
        "maxFileBytes": null,
        "remainingUses": null,
      });
      final String text = jsonEncode(info.json);
      for (final String secret in <String>[made.share.tokenHash, made.share.id, "a1", "/readme.txt", "r1"]) {
        expect(text, isNot(contains(secret)));
      }
    });

    test("unknown, malformed and empty tokens are all a plain 404", () async {
      for (final String token in <String>["x" * 43, "short", "${"a" * 42}!", ShareTokens.generate()]) {
        final ApiResponse response = await pub(token);
        expect(response.status, 404, reason: token);
        expect(body(response), <String, Object?>{"error": "not_found"});
      }
    });

    test("guessing tokens gets an address throttled", () async {
      for (int i = 0; i < 30; i++) {
        await pub(ShareTokens.generate());
      }
      final ApiResponse response = await pub(ShareTokens.generate());
      expect(response.status, 429);
      expect(response.headers["Retry-After"], isNotNull);

      final CreatedShare real = await h.makeShare(path: "/readme.txt");
      expect((await pub(real.token, address: "198.51.100.7")).status, 200, reason: "another address is unaffected");
    });

    test("an expired link is 410, and so is one that is used up", () async {
      final CreatedShare timed = await h.makeShare(path: "/readme.txt", lifetime: const Duration(hours: 1));
      expect((await pub(timed.token)).status, 200);
      h.clock.advance(const Duration(hours: 2));
      final ApiResponse gone = await pub(timed.token);
      expect(gone.status, 410);
      expect(body(gone), <String, Object?>{"error": "link_expired"});

      final CreatedShare once = await h.makeShare(path: "/readme.txt", maxUses: 1);
      expect((await pub(once.token, action: "content")).status, 200);
      final ApiResponse spent = await pub(once.token);
      expect(spent.status, 410);
      expect(body(spent), <String, Object?>{"error": "link_used_up"});
    });

    test("remaining uses are shown", () async {
      final CreatedShare made = await h.makeShare(path: "/readme.txt", maxUses: 3);
      await pub(made.token, action: "content");
      expect(body(await pub(made.token))["remainingUses"], 2);
    });

    test("wrong methods are 405", () async {
      final CreatedShare made = await h.makeShare(path: "/readme.txt");
      expect((await pub(made.token, method: "POST")).status, 405);
      expect((await pub(made.token, action: "unlock")).status, 405);
      expect((await pub(made.token, action: "entries", method: "DELETE")).status, 405);
      expect((await pub(made.token, action: "content", method: "DELETE")).status, 405);
      expect((await pub(made.token, action: "nope")).status, 404);
      expect((await h.send("GET", "/api/v1/public/${made.token}/content/extra")).status, 404);
      expect((await h.send("GET", "/api/v1/public")).status, 404);
    });
  });

  group("downloading a file link", () {
    test("streams the file as an attachment with safe headers, and counts one use", () async {
      final CreatedShare made = await h.makeShare(path: "/readme.txt");
      final ApiResponse response = await pub(made.token, action: "content");

      expect(response.status, 200);
      expect(await textOf(response), "hello world");
      expect(response.headers["Content-Disposition"], startsWith("attachment; filename=\"readme.txt\""));
      expect(response.headers["Content-Security-Policy"], contains("sandbox"));
      expect(response.contentLength, 11);
      expect(await uses(made), 1);
    });

    test("no login is needed and none is accepted as a substitute for the link", () async {
      final CreatedShare made = await h.makeShare(path: "/readme.txt");
      final ApiResponse response = await h.send("GET", "/api/v1/public/${made.token}/content", token: await h.login());
      expect(response.status, 200);
    });

    test("only a from-the-start GET counts: HEAD and resumed ranges don't", () async {
      final CreatedShare made = await h.makeShare(path: "/readme.txt", maxUses: 5);

      expect((await pub(made.token, action: "content", method: "HEAD")).status, 200);
      final ApiResponse tail = await pub(made.token, action: "content", headers: <String, String>{"range": "bytes=6-"});
      expect(tail.status, 206);
      expect(await textOf(tail), "world");
      expect(await uses(made), 0);

      await pub(made.token, action: "content", headers: <String, String>{"range": "bytes=0-4"});
      expect(await uses(made), 1);
    });

    test("the last use can only be taken once, even by racing requests", () async {
      final CreatedShare made = await h.makeShare(path: "/readme.txt", maxUses: 1);
      final List<ApiResponse> responses = await Future.wait(<Future<ApiResponse>>[
        pub(made.token, action: "content"),
        pub(made.token, action: "content"),
        pub(made.token, action: "content"),
      ]);

      expect(responses.where((ApiResponse r) => r.status == 200), hasLength(1));
      expect(responses.where((ApiResponse r) => r.status == 410), hasLength(2));
    });

    test("a link to a file has no folder to list", () async {
      final CreatedShare made = await h.makeShare(path: "/readme.txt");
      final ApiResponse response = await pub(made.token, action: "entries");
      expect(response.status, 400);
      expect(body(response), <String, Object?>{"error": "not_a_folder_link"});
    });

    test("PUT is not for download links", () async {
      final CreatedShare made = await h.makeShare(path: "/readme.txt");
      expect((await pub(made.token, action: "content", method: "PUT", query: <String, String>{"name": "x"}, bytes: <int>[1])).status, 405);
      expect(await backend.stat(sp("/x")).then((s) => s.exists), isFalse);
    });
  });

  group("a folder link", () {
    test("lists the folder and only what is below it", () async {
      final CreatedShare made = await h.makeShare(path: "/Docs");

      final ApiResponse top = await pub(made.token, action: "entries");
      expect(body(top)["path"], "/");
      expect((body(top)["entries"]! as List<Object?>).map((Object? e) => (e! as Map<String, Object?>)["name"]).toSet(), <String>{"a.txt", "sub", "secret%20name.txt"});

      final ApiResponse sub = await pub(made.token, action: "entries", query: <String, String>{"path": "/sub"});
      expect(body(sub)["path"], "/sub");
      expect(((body(sub)["entries"]! as List<Object?>).single! as Map<String, Object?>)["name"], "b.txt");
    });

    test("it can't be walked out of, by any spelling", () async {
      final CreatedShare made = await h.makeShare(path: "/Docs");

      for (final String path in <String>["..", "/../Secret", "/sub/../../Secret", "/%2e%2e/Secret", "/%252e%252e/Secret", r"\..\Secret", "C:\\"]) {
        final ApiResponse listing = await pub(made.token, action: "entries", query: <String, String>{"path": path});
        expect(listing.status, 400, reason: path);
        final ApiResponse file = await pub(made.token, action: "content", query: <String, String>{"path": "$path/x.txt"});
        expect(file.status, 400, reason: path);
      }
      final ApiResponse absolute = await pub(made.token, action: "content", query: <String, String>{"path": "/Secret/x.txt"});
      expect(absolute.status, 404, reason: "that is /Docs/Secret/x.txt, which doesn't exist");
    });

    test("downloads a file inside it, including a name with a literal %20", () async {
      final CreatedShare made = await h.makeShare(path: "/Docs");

      final ApiResponse nested = await pub(made.token, action: "content", query: <String, String>{"path": "/sub/b.txt"});
      expect(await textOf(nested), "B");

      final ApiResponse literal = await pub(made.token, action: "content", query: <String, String>{"path": "/secret%20name.txt"});
      expect(await textOf(literal), "literal");
    });

    test("no path, a folder, or a missing file is not a download", () async {
      final CreatedShare made = await h.makeShare(path: "/Docs");

      expect((await pub(made.token, action: "content")).status, 400);
      expect((await pub(made.token, action: "content", query: <String, String>{"path": "/sub"})).status, 400);
      expect((await pub(made.token, action: "content", query: <String, String>{"path": "/nope.txt"})).status, 404);
      expect((await pub(made.token, action: "entries", query: <String, String>{"path": "/nope"})).status, 404);
      expect((await pub(made.token, action: "entries", query: <String, String>{"path": "/a.txt"})).status, 400);
    });

    test("a link to the whole storage still hides VaultBox's own folder", () async {
      final CreatedShare made = await h.makeShare(path: "/");

      final ApiResponse top = await pub(made.token, action: "entries");
      final Set<Object?> names = (body(top)["entries"]! as List<Object?>).map((Object? e) => (e! as Map<String, Object?>)["name"]).toSet();
      expect(names, isNot(contains(".vaultbox")));
      expect(names, containsAll(<String>["readme.txt", "Docs"]));
      expect((await pub(made.token, action: "entries", query: <String, String>{"path": "/.vaultbox"})).status, 404);
      expect((await pub(made.token, action: "content", query: <String, String>{"path": "/.vaultbox/recycle/x"})).status, 404);
    });

    test("paging works", () async {
      final CreatedShare made = await h.makeShare(path: "/Docs");
      final ApiResponse first = await pub(made.token, action: "entries", query: <String, String>{"limit": "2"});
      expect((body(first)["entries"]! as List<Object?>).length, 2);
      expect(body(first)["nextCursor"], isNotNull);
      expect((await pub(made.token, action: "entries", query: <String, String>{"limit": "0"})).status, 400);
    });
  });

  group("a password", () {
    Future<CreatedShare> locked() => h.makeShare(path: "/readme.txt", password: "hunter22");

    test("the link says a password is needed and hides the name until it is given", () async {
      final CreatedShare made = await locked();
      final Map<String, Object?> info = body(await pub(made.token));

      expect(info["requiresPassword"], isTrue);
      expect(info["unlocked"], isFalse);
      expect(info["name"], isNull);
      expect(info["size"], isNull);
    });

    test("nothing is served without proof", () async {
      final CreatedShare made = await locked();

      final ApiResponse response = await pub(made.token, action: "content");
      expect(response.status, 401);
      expect(body(response), <String, Object?>{"error": "password_required"});
      expect(await uses(made), 0);
      expect((await pub(made.token, action: "content", query: <String, String>{"unlock": "made-up"})).status, 401);
    });

    test("the right password gives a proof that works as a query value or a header", () async {
      final CreatedShare made = await locked();
      final ApiResponse unlock = await pub(made.token, action: "unlock", method: "POST", json: <String, Object?>{"password": "hunter22"});

      expect(unlock.status, 200);
      final String proof = body(unlock)["unlock"]! as String;
      expect(body(unlock)["expiresInSeconds"], 1800);

      final ApiResponse viaQuery = await pub(made.token, action: "content", query: <String, String>{"unlock": proof});
      expect(await textOf(viaQuery), "hello world");
      final ApiResponse viaHeader = await pub(made.token, action: "content", headers: <String, String>{"x-share-unlock": proof});
      expect(viaHeader.status, 200);

      final Map<String, Object?> info = body(await pub(made.token, query: <String, String>{"unlock": proof}));
      expect(info["unlocked"], isTrue);
      expect(info["name"], "readme.txt");
    });

    test("a wrong password is 401 and repeated ones are throttled", () async {
      final CreatedShare made = await locked();
      Future<ApiResponse> attempt(String password) => pub(made.token, action: "unlock", method: "POST", json: <String, Object?>{"password": password});

      for (int i = 0; i < 5; i++) {
        final ApiResponse wrong = await attempt("wrong $i");
        expect(wrong.status, 401);
        expect(body(wrong), <String, Object?>{"error": "invalid_password"});
      }
      final ApiResponse blocked = await attempt("hunter22");
      expect(blocked.status, 429, reason: "even the right password while throttled");
      expect(blocked.headers["Retry-After"], "30");

      h.clock.advance(const Duration(seconds: 31));
      expect((await attempt("hunter22")).status, 200);
    });

    test("bad unlock bodies", () async {
      final CreatedShare made = await locked();
      expect((await pub(made.token, action: "unlock", method: "POST", json: <String, Object?>{})).status, 400);
      expect((await pub(made.token, action: "unlock", method: "POST", json: <String, Object?>{"password": 5})).status, 400);
      expect((await pub(made.token, action: "unlock", method: "POST", json: <String, Object?>{"password": ""})).status, 401);
      expect((await pub(made.token, action: "unlock", method: "POST", json: <String, Object?>{"password": "x" * 500})).status, 401);
      expect(h.hasher.verifyCalls, 0, reason: "absurd input never reaches the password check");
    });

    test("a proof belongs to one link and expires", () async {
      final CreatedShare first = await locked();
      final CreatedShare second = await locked();
      final String proof = body(await pub(first.token, action: "unlock", method: "POST", json: <String, Object?>{"password": "hunter22"}))["unlock"]! as String;

      expect((await pub(second.token, action: "content", query: <String, String>{"unlock": proof})).status, 401, reason: "another link");
      h.clock.advance(const Duration(minutes: 31));
      expect((await pub(first.token, action: "content", query: <String, String>{"unlock": proof})).status, 401, reason: "expired");
    });

    test("a link without a password has nothing to unlock", () async {
      final CreatedShare open = await h.makeShare(path: "/readme.txt");
      final ApiResponse response = await pub(open.token, action: "unlock", method: "POST", json: <String, Object?>{"password": "anything"});
      expect(response.status, 200);
      expect(body(response)["unlock"], isNull);
    });
  });

  group("an upload link", () {
    Future<CreatedShare> inbox({int? maxFileBytes, int? maxUses, String? password}) =>
        h.makeShare(path: "/Inbox", kind: ShareKind.upload, maxFileBytes: maxFileBytes, maxUses: maxUses, password: password);

    Future<ApiResponse> send(CreatedShare made, String name, List<int> data, {String? unlock}) => pub(
      made.token,
      action: "content",
      method: "PUT",
      query: <String, String>{"name": name, if (unlock != null) "unlock": unlock},
      bytes: data,
    );

    test("receives a file into the folder — and shows nothing that is in it", () async {
      final CreatedShare made = await inbox();
      final ApiResponse response = await send(made, "report.pdf", utf8.encode("pdf-bytes"));

      expect(response.status, 201);
      expect(body(response), <String, Object?>{"name": "report.pdf", "size": 9});
      expect(utf8.decode(await backend.openRead(sp("/Inbox/report.pdf")).expand((List<int> c) => c).toList()), "pdf-bytes");

      expect((await pub(made.token, action: "entries")).status, 400, reason: "no listing");
      expect((await pub(made.token, action: "content")).status, 405, reason: "no download");
      final Map<String, Object?> info = body(await pub(made.token));
      expect(info["kind"], "upload");
      expect(jsonEncode(info), isNot(contains("report.pdf")));
    });

    test("never overwrites: a second file with the same name is renamed", () async {
      final CreatedShare made = await inbox();
      await send(made, "notes.txt", utf8.encode("first"));
      final ApiResponse second = await send(made, "notes.txt", utf8.encode("second"));

      expect(body(second)["name"], "notes (1).txt");
      expect(utf8.decode(await backend.openRead(sp("/Inbox/notes.txt")).expand((List<int> c) => c).toList()), "first");
    });

    test("only a plain file name is accepted; where it lands is not the sender's choice", () async {
      final CreatedShare made = await inbox();

      for (final String name in <String>["", "  ", "../escape.txt", "a/b.txt", r"a\b.txt", "..", ".", ".hidden", ".vaultbox", "x" * 300, "nul\u0000.txt"]) {
        expect((await send(made, name, <int>[1])).status, 400, reason: name);
      }
      expect((await pub(made.token, action: "content", method: "PUT", bytes: <int>[1])).status, 400, reason: "no name at all");
      expect(await backend.stat(sp("/escape.txt")).then((s) => s.exists), isFalse);
      expect(await uses(made), 0, reason: "refused uploads cost nothing");
    });

    test("a file bigger than the limit is refused, whether or not it announced its size", () async {
      final CreatedShare made = await inbox(maxFileBytes: 10);

      final ApiResponse declared = await send(made, "big.bin", List<int>.filled(11, 1));
      expect(declared.status, 413);
      expect(declared.closeConnection, isTrue);

      Stream<List<int>> secretlyBig() async* {
        yield List<int>.filled(6, 1);
        yield List<int>.filled(6, 1);
        yield List<int>.filled(6, 1);
      }

      final ApiResponse streamed = await pub(
        made.token,
        action: "content",
        method: "PUT",
        query: <String, String>{"name": "sneaky.bin"},
        stream: secretlyBig(),
      );
      expect(streamed.status, 413);
      expect(await backend.stat(sp("/Inbox/sneaky.bin")).then((s) => s.exists), isFalse, reason: "nothing half-written");

      expect((await send(made, "ok.bin", List<int>.filled(10, 1))).status, 201, reason: "exactly the limit is fine");
    });

    test("the number of files is limited", () async {
      final CreatedShare made = await inbox(maxUses: 2);

      expect((await send(made, "1.txt", <int>[1])).status, 201);
      expect((await send(made, "2.txt", <int>[1])).status, 201);
      final ApiResponse third = await send(made, "3.txt", <int>[1]);
      expect(third.status, 410);
      expect(await backend.stat(sp("/Inbox/3.txt")).then((s) => s.exists), isFalse);
    });

    test("a broken upload keeps nothing", () async {
      final CreatedShare made = await inbox();
      Stream<List<int>> broken() async* {
        yield utf8.encode("part");
        throw const FormatException("connection reset");
      }

      final ApiResponse response = await pub(made.token, action: "content", method: "PUT", query: <String, String>{"name": "cut.txt"}, stream: broken());
      expect(response.status, 400);
      expect(await backend.stat(sp("/Inbox/cut.txt")).then((s) => s.exists), isFalse);
    });

    test("a password protects an upload link too", () async {
      final CreatedShare made = await inbox(password: "hunter22");
      expect((await send(made, "a.txt", <int>[1])).status, 401);

      final String proof = body(await pub(made.token, action: "unlock", method: "POST", json: <String, Object?>{"password": "hunter22"}))["unlock"]! as String;
      expect((await send(made, "a.txt", <int>[1], unlock: proof)).status, 201);
    });
  });

  group("the person who made the link", () {
    test("if they lose access, the link stops working", () async {
      final CreatedShare made = await h.makeShare(creator: bob, path: "/Photos/a.jpg");
      expect((await pub(made.token, action: "content")).status, 200);

      await h.accounts.replaceRules("m1", const <AccessRule>[]);

      expect((await pub(made.token)).status, 404);
      expect((await pub(made.token, action: "content")).status, 404);
    });

    test("if their account is disabled or deleted, the link stops working", () async {
      final CreatedShare made = await h.makeShare(creator: bob, path: "/Photos/a.jpg");

      await h.accounts.setEnabled("m1", enabled: false);
      expect((await pub(made.token)).status, 404);

      await h.accounts.setEnabled("m1", enabled: true);
      expect((await pub(made.token)).status, 200);

      await h.accounts.delete("m1");
      expect((await pub(made.token)).status, 404);
    });

    test("an upload link needs the maker to still be able to write", () async {
      final CreatedShare made = await h.makeShare(creator: bob, path: "/Inbox", kind: ShareKind.upload);
      expect((await pub(made.token, action: "content", method: "PUT", query: <String, String>{"name": "a.txt"}, bytes: <int>[1])).status, 201);

      await h.accounts.replaceRules("m1", <AccessRule>[
        const AccessRule(id: "r", accountId: "m1", rootId: "r1", pathPrefix: "/Inbox", permissions: AccessRule.readOnly),
      ]);
      expect((await pub(made.token, action: "content", method: "PUT", query: <String, String>{"name": "b.txt"}, bytes: <int>[1])).status, 404);
    });

    test("the shared item being deleted is a 404, not a crash", () async {
      final CreatedShare made = await h.makeShare(path: "/readme.txt");
      await backend.delete(sp("/readme.txt"));

      expect((await pub(made.token, action: "content")).status, 404);
      expect((await pub(made.token)).status, 404);
    });
  });

  test("revoking removes the link for good", () async {
    final CreatedShare made = await h.makeShare(path: "/readme.txt");
    await h.shareRepository.delete(made.share.id);
    expect((await pub(made.token)).status, 404);
  });
}
