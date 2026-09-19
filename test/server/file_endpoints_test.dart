import "dart:async";
import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/security/authorizer.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/server/api/api_types.dart";

import "../helpers/api_harness.dart";

/// Allows everything except what [deny] says, and remembers every question.
final class _RecordingAuthorizer implements Authorizer {
  _RecordingAuthorizer({this.deny});

  final bool Function(Permission permission, StoragePath path)? deny;
  final List<(Permission, String)> asked = <(Permission, String)>[];

  @override
  bool allows(Account account, Permission permission, StorageRoot root, StoragePath path) {
    asked.add((permission, "/${path.segments.join("/")}"));
    return !(deny?.call(permission, path) ?? false);
  }
}

void main() {
  late ApiHarness h;
  late MemoryStorageBackend backend;
  late String token;

  Future<void> start({_RecordingAuthorizer? authorizer, List<StorageRoot>? roots}) async {
    backend = MemoryStorageBackend(id: "r1")
      ..seedFile("/readme.txt", utf8.encode("hello world"))
      ..seedFile("/page.html", utf8.encode("<script>alert(1)</script>"))
      ..seedFile("/résumé 100%.txt", utf8.encode("cv"))
      ..seedDirectory("/docs")
      ..seedFile("/docs/a.txt", utf8.encode("A"))
      ..seedDirectory("/empty")
      ..seedFile("/.vaultbox/recycle/keep.txt", utf8.encode("bin"));
    h = ApiHarness(backend: backend, authorizer: authorizer ?? const SingleAdminAuthorizer(), roots: roots);
    token = await h.login();
  }

  setUp(start);

  StoragePath sp(String value) => StoragePath.parseDecoded("r1", value);

  Future<String> contentOf(String value) async =>
      utf8.decode(await backend.openRead(sp(value)).expand((List<int> c) => c).toList());

  Future<bool> exists(String value) async => (await backend.stat(sp(value))).exists;

  Map<String, Object?> body(ApiResponse r) => ApiHarness.json(r);

  Future<ApiResponse> get(String p, {Map<String, String> extra = const <String, String>{}, Map<String, String> headers = const <String, String>{}, String method = "GET"}) =>
      h.send(method, "/api/v1/roots/r1/content", token: token, query: <String, String>{"path": p, ...extra}, headers: headers);

  Future<ApiResponse> put(String p, List<int> data, {bool overwrite = false}) =>
      h.send("PUT", "/api/v1/roots/r1/content", token: token, query: <String, String>{"path": p, if (overwrite) "overwrite": "1"}, bytes: data);

  Future<ApiResponse> post(String action, Object json, {String root = "r1"}) =>
      h.send("POST", "/api/v1/roots/$root/$action", token: token, json: json);

  group("download", () {
    test("streams the file with safe headers", () async {
      final ApiResponse response = await get("/readme.txt");

      expect(response.status, 200);
      expect(utf8.decode(await ApiHarness.bodyBytes(response)), "hello world");
      expect(response.contentType, "text/plain");
      expect(response.contentLength, 11);
      expect(response.headers["Content-Disposition"], startsWith("attachment; filename=\"readme.txt\""));
      expect(response.headers["Accept-Ranges"], "bytes");
      expect(response.headers["Content-Security-Policy"], contains("sandbox"));
    });

    test("byte ranges: from-to, open-ended and suffix", () async {
      final ApiResponse first = await get("/readme.txt", headers: <String, String>{"range": "bytes=0-4"});
      expect(first.status, 206);
      expect(utf8.decode(await ApiHarness.bodyBytes(first)), "hello");
      expect(first.headers["Content-Range"], "bytes 0-4/11");
      expect(first.contentLength, 5);

      final ApiResponse open = await get("/readme.txt", headers: <String, String>{"range": "bytes=6-"});
      expect(utf8.decode(await ApiHarness.bodyBytes(open)), "world");
      expect(open.headers["Content-Range"], "bytes 6-10/11");

      final ApiResponse suffix = await get("/readme.txt", headers: <String, String>{"range": "bytes=-5"});
      expect(utf8.decode(await ApiHarness.bodyBytes(suffix)), "world");

      final ApiResponse clamped = await get("/readme.txt", headers: <String, String>{"range": "bytes=6-999"});
      expect(clamped.headers["Content-Range"], "bytes 6-10/11");

      final ApiResponse bigSuffix = await get("/readme.txt", headers: <String, String>{"range": "bytes=-999"});
      expect(utf8.decode(await ApiHarness.bodyBytes(bigSuffix)), "hello world");
    });

    test("a range outside the file is 416 with the size", () async {
      final ApiResponse response = await get("/readme.txt", headers: <String, String>{"range": "bytes=20-30"});

      expect(response.status, 416);
      expect(response.headers["Content-Range"], "bytes */11");
      expect((await get("/readme.txt", headers: <String, String>{"range": "bytes=-0"})).status, 416);
      expect((await get("/readme.txt", headers: <String, String>{"range": "bytes=11-"})).status, 416);
      expect((await get("/readme.txt", headers: <String, String>{"range": "bytes=20-"})).status, 416);
    });

    test("ranges the server doesn't split are ignored, not errors", () async {
      for (final String range in <String>["bytes=0-1,3-4", "items=0-1", "bytes=abc", "bytes=-", "bytes=5-2", ""]) {
        final ApiResponse response = await get("/readme.txt", headers: <String, String>{"range": range});
        expect(response.status, 200, reason: range);
        expect(utf8.decode(await ApiHarness.bodyBytes(response)), "hello world", reason: range);
      }
    });

    test("a root without random access ignores Range and says so", () async {
      await start(roots: <StorageRoot>[ApiHarness.root(capabilities: const StorageCapabilities.saf())]);
      final ApiResponse response = await get("/readme.txt", headers: <String, String>{"range": "bytes=0-4"});

      expect(response.status, 200);
      expect(response.headers["Accept-Ranges"], "none");
      expect(utf8.decode(await ApiHarness.bodyBytes(response)), "hello world");
    });

    test("inline only for types that can't run script", () async {
      final ApiResponse text = await get("/readme.txt", extra: <String, String>{"inline": "1"});
      expect(text.headers["Content-Disposition"], startsWith("inline;"));

      final ApiResponse html = await get("/page.html", extra: <String, String>{"inline": "1"});
      expect(html.headers["Content-Disposition"], startsWith("attachment;"), reason: "an uploaded page must not run as the site");
    });

    test("unusual names get an ASCII fallback and a UTF-8 filename*", () async {
      final ApiResponse response = await get("/résumé 100%.txt");

      expect(response.headers["Content-Disposition"], contains("filename=\"r_sum_ 100_.txt\""));
      expect(response.headers["Content-Disposition"], contains("filename*=UTF-8''r%C3%A9sum%C3%A9%20100%25.txt"));
    });

    test("HEAD answers headers and no bytes", () async {
      final ApiResponse response = await get("/readme.txt", method: "HEAD");

      expect(response.status, 200);
      expect(response.contentLength, 11);
      expect(await ApiHarness.bodyBytes(response), isEmpty);
    });

    test("folders, missing files, traversal and the recycle bin", () async {
      expect((await get("/docs")).status, 400);
      expect((await get("/nope.txt")).status, 404);
      expect((await get("/../etc/passwd")).status, 400);
      expect((await get("/")).status, 400);
      expect((await get("/.vaultbox/recycle/keep.txt")).status, 404);
    });

    test("other methods are 405 and list what is allowed", () async {
      final ApiResponse response = await get("/readme.txt", method: "DELETE");
      expect(response.status, 405);
      expect(response.headers["allow"], "GET, HEAD, PUT");
    });
  });

  group("upload", () {
    test("creates a file", () async {
      final ApiResponse response = await put("/docs/new.txt", utf8.encode("fresh"));

      expect(response.status, 201);
      expect(body(response), <String, Object?>{"path": "/docs/new.txt", "size": 5});
      expect(await contentOf("/docs/new.txt"), "fresh");
    });

    test("an existing file needs overwrite=1", () async {
      final ApiResponse refused = await put("/readme.txt", utf8.encode("new"));
      expect(refused.status, 409);
      expect(body(refused), <String, Object?>{"error": "already_exists"});
      expect(await contentOf("/readme.txt"), "hello world");

      final ApiResponse replaced = await put("/readme.txt", utf8.encode("new"), overwrite: true);
      expect(replaced.status, 200);
      expect(await contentOf("/readme.txt"), "new");
    });

    test("a folder is never overwritten by a file", () async {
      final ApiResponse response = await put("/docs", utf8.encode("x"), overwrite: true);
      expect(response.status, 409);
      expect(body(response), <String, Object?>{"error": "is_a_directory"});
    });

    test("the parent folder must exist", () async {
      final ApiResponse response = await put("/missing/new.txt", utf8.encode("x"));
      expect(response.status, 409);
      expect(body(response), <String, Object?>{"error": "parent_not_found"});
      expect(await exists("/missing"), isFalse, reason: "no folders are invented");
    });

    test("a name with %-sequences is that exact name, never a decoded neighbour", () async {
      expect((await put("/Report%20final.pdf", utf8.encode("literal"))).status, 201);

      expect(await contentOf("/Report%20final.pdf"), "literal");
      expect((await get("/Report%20final.pdf")).status, 200);
      expect((await get("/Report final.pdf")).status, 404, reason: "a different name");

      final ApiResponse listing = await h.send("GET", "/api/v1/roots/r1/entries", token: token);
      final List<Object?> names = (body(listing)["entries"]! as List<Object?>)
          .map((Object? e) => (e! as Map<String, Object?>)["name"])
          .toList();
      expect(names, contains("Report%20final.pdf"));
      expect(names, isNot(contains("Report final.pdf")));
    });

    test("bad and reserved paths", () async {
      expect((await put("/", utf8.encode("x"))).status, 400);
      expect((await put("/../x.txt", utf8.encode("x"))).status, 400);
      expect((await put("/.vaultbox/x.txt", utf8.encode("x"))).status, 404);
      expect(await exists("/.vaultbox/x.txt"), isFalse);
    });

    test("a read-only root refuses uploads", () async {
      await start(roots: <StorageRoot>[ApiHarness.root(capabilities: const StorageCapabilities.readOnly())]);
      final ApiResponse response = await put("/new.txt", utf8.encode("x"));

      expect(response.status, 403);
      expect(body(response), <String, Object?>{"error": "read_only_storage"});
    });

    test("a connection that breaks mid-upload leaves nothing half-written", () async {
      Stream<List<int>> broken() async* {
        yield utf8.encode("part");
        throw const FormatException("connection reset");
      }

      final ApiResponse created = await h.api.handle(
        ApiRequest(
          method: "PUT",
          segments: const <String>["api", "v1", "roots", "r1", "content"],
          query: const <String, String>{"path": "/broken.txt"},
          remoteAddress: "192.168.1.10",
          bearerToken: token,
          bodyStream: broken(),
        ),
      );
      expect(created.status, 400);
      expect(body(created), <String, Object?>{"error": "upload_interrupted"});
      expect(await exists("/broken.txt"), isFalse);

      final ApiResponse replaced = await h.api.handle(
        ApiRequest(
          method: "PUT",
          segments: const <String>["api", "v1", "roots", "r1", "content"],
          query: const <String, String>{"path": "/readme.txt", "overwrite": "1"},
          remoteAddress: "192.168.1.10",
          bearerToken: token,
          bodyStream: broken(),
        ),
      );
      expect(replaced.status, 400);
      expect(await contentOf("/readme.txt"), "hello world", reason: "the old version survives");
    });
  });

  group("folders and renames", () {
    test("mkdir creates a folder", () async {
      final ApiResponse response = await post("mkdir", <String, Object?>{"path": "/docs/sub"});

      expect(response.status, 201);
      expect(body(response), <String, Object?>{"path": "/docs/sub"});
      expect((await backend.stat(sp("/docs/sub"))).exists, isTrue);
    });

    test("mkdir refuses duplicates, missing parents and bad input", () async {
      expect((await post("mkdir", <String, Object?>{"path": "/docs"})).status, 409);
      expect((await post("mkdir", <String, Object?>{"path": "/nope/sub"})).status, 409);
      expect((await post("mkdir", <String, Object?>{"path": "/"})).status, 400);
      expect((await post("mkdir", <String, Object?>{"path": "/../x"})).status, 400);
      expect((await post("mkdir", <String, Object?>{"path": "/.vaultbox/x"})).status, 404);
      expect((await post("mkdir", <String, Object?>{})).status, 400);
    });

    test("rename changes only the last segment", () async {
      final ApiResponse response = await post("rename", <String, Object?>{"path": "/docs/a.txt", "newName": "b.txt"});

      expect(response.status, 200);
      expect(body(response), <String, Object?>{"path": "/docs/b.txt"});
      expect(await exists("/docs/a.txt"), isFalse);
      expect(await contentOf("/docs/b.txt"), "A");
    });

    test("rename refuses clashes, unknown items and unusable names", () async {
      expect((await post("rename", <String, Object?>{"path": "/readme.txt", "newName": "page.html"})).status, 409);
      expect((await post("rename", <String, Object?>{"path": "/nope.txt", "newName": "x.txt"})).status, 404);
      for (final String name in <String>["", "a/b", r"a\b", "..", ".", "x" * 300]) {
        final ApiResponse response = await post("rename", <String, Object?>{"path": "/readme.txt", "newName": name});
        expect(response.status, 400, reason: name);
        expect(body(response), <String, Object?>{"error": "invalid_name"}, reason: name);
      }
      expect((await post("rename", <String, Object?>{"path": "/readme.txt", "newName": ".vaultbox"})).status, 400);
      expect(await exists("/readme.txt"), isTrue);
    });
  });

  group("move, copy and delete", () {
    test("copy puts the file in the destination and keeps the original", () async {
      final ApiResponse response = await post("copy", <String, Object?>{
        "sources": <String>["/readme.txt"],
        "destination": "/docs",
      });

      expect(response.status, 200);
      expect(body(response)["completed"], 1);
      expect(await contentOf("/docs/readme.txt"), "hello world");
      expect(await exists("/readme.txt"), isTrue);
    });

    test("move takes the file out of its old place", () async {
      final ApiResponse response = await post("move", <String, Object?>{
        "sources": <String>["/readme.txt"],
        "destination": "/empty",
      });

      expect(response.status, 200);
      expect(body(response)["completed"], 1);
      expect(await exists("/readme.txt"), isFalse);
      expect(await contentOf("/empty/readme.txt"), "hello world");
    });

    test("a clash is skipped by default and reported per item", () async {
      backend.seedFile("/docs/readme.txt", utf8.encode("old"));
      final ApiResponse response = await post("copy", <String, Object?>{
        "sources": <String>["/readme.txt", "/page.html"],
        "destination": "/docs",
      });

      final Map<String, Object?> json = body(response);
      expect(json["completed"], 1);
      expect((json["skipped"]! as int) + (json["failed"]! as int), 1, reason: "the clash is not silently overwritten");
      expect(await contentOf("/docs/readme.txt"), "old");
      final List<Object?> results = json["results"]! as List<Object?>;
      expect(results, hasLength(2));
      expect((results.first! as Map<String, Object?>)["source"], "/readme.txt");
    });

    test("conflict=replace overwrites and keepBoth renames", () async {
      backend.seedFile("/docs/readme.txt", utf8.encode("old"));
      await post("copy", <String, Object?>{
        "sources": <String>["/readme.txt"],
        "destination": "/docs",
        "conflict": "replace",
      });
      expect(await contentOf("/docs/readme.txt"), "hello world");

      backend.seedFile("/docs/page.html", utf8.encode("old"));
      await post("copy", <String, Object?>{
        "sources": <String>["/page.html"],
        "destination": "/docs",
        "conflict": "keepBoth",
      });
      expect(await contentOf("/docs/page.html"), "old");
      expect(await exists("/docs/page (1).html"), isTrue);
    });

    test("the destination must be an existing folder", () async {
      expect(
        (await post("move", <String, Object?>{"sources": <String>["/readme.txt"], "destination": "/nope"})).status,
        409,
      );
      expect(
        (await post("move", <String, Object?>{"sources": <String>["/readme.txt"], "destination": "/page.html"})).status,
        409,
      );
      expect(await exists("/readme.txt"), isTrue);
    });

    test("bad requests are 400 and change nothing", () async {
      for (final Map<String, Object?> bad in <Map<String, Object?>>[
        <String, Object?>{"sources": <String>[], "destination": "/docs"},
        <String, Object?>{"destination": "/docs"},
        <String, Object?>{"sources": "/readme.txt", "destination": "/docs"},
        <String, Object?>{"sources": <Object?>[5], "destination": "/docs"},
        <String, Object?>{"sources": <String>["/readme.txt"]},
        <String, Object?>{"sources": <String>["/readme.txt"], "destination": "/docs", "conflict": "explode"},
        <String, Object?>{"sources": <String>["/"], "destination": "/docs"},
        <String, Object?>{"sources": <String>["/../x"], "destination": "/docs"},
        <String, Object?>{"sources": List<String>.filled(501, "/readme.txt"), "destination": "/docs"},
      ]) {
        expect((await post("copy", bad)).status, 400, reason: "$bad");
      }
      expect((await post("copy", <String, Object?>{"sources": <String>["/.vaultbox"], "destination": "/docs"})).status, 404);
      expect(await exists("/docs/readme.txt"), isFalse);
    });

    test("delete sends items to the Recycle Bin, not into thin air", () async {
      final ApiResponse response = await post("delete", <String, Object?>{
        "paths": <String>["/readme.txt", "/nope.txt"],
      });

      expect(response.status, 200);
      final Map<String, Object?> json = body(response);
      expect(json["completed"], 1);
      expect(json["failed"], 1);
      expect(await exists("/readme.txt"), isFalse);
      final List<String> recycled = await backend
          .list(sp("/.vaultbox/recycle"))
          .map((e) => e.name)
          .toList();
      expect(recycled.any((String n) => n.endsWith("__readme.txt")), isTrue);
    });

    test("delete refuses the root, the recycle bin and empty lists", () async {
      expect((await post("delete", <String, Object?>{"paths": <String>["/"]})).status, 400);
      expect((await post("delete", <String, Object?>{"paths": <String>["/.vaultbox/recycle/keep.txt"]})).status, 404);
      expect((await post("delete", <String, Object?>{"paths": <String>[]})).status, 400);
    });

    test("a read-only root refuses every change", () async {
      await start(roots: <StorageRoot>[ApiHarness.root(capabilities: const StorageCapabilities.readOnly())]);

      for (final (String, Object) call in <(String, Object)>[
        ("mkdir", <String, Object?>{"path": "/x"}),
        ("rename", <String, Object?>{"path": "/readme.txt", "newName": "y"}),
        ("move", <String, Object?>{"sources": <String>["/readme.txt"], "destination": "/docs"}),
        ("copy", <String, Object?>{"sources": <String>["/readme.txt"], "destination": "/docs"}),
        ("delete", <String, Object?>{"paths": <String>["/readme.txt"]}),
      ]) {
        final ApiResponse response = await post(call.$1, call.$2);
        expect(response.status, 403, reason: call.$1);
        expect(body(response), <String, Object?>{"error": "read_only_storage"}, reason: call.$1);
      }
      expect(await exists("/readme.txt"), isTrue);
    });

    test("only POST works on the change endpoints", () async {
      final ApiResponse response = await h.send("GET", "/api/v1/roots/r1/mkdir", token: token);
      expect(response.status, 405);
      expect(response.headers["allow"], "POST");
    });
  });

  group("every path goes through the Authorizer", () {
    test("reads ask for read", () async {
      final _RecordingAuthorizer authorizer = _RecordingAuthorizer();
      await start(authorizer: authorizer);

      await h.send("GET", "/api/v1/roots/r1/entries", token: token, query: <String, String>{"path": "/docs"});
      await get("/readme.txt");

      expect(authorizer.asked, <(Permission, String)>[
        (Permission.read, "/docs"),
        (Permission.read, "/readme.txt"),
      ]);
    });

    test("a denied read is 403 and reveals nothing", () async {
      await start(authorizer: _RecordingAuthorizer(deny: (Permission p, StoragePath path) => path.segments.contains("docs")));

      final ApiResponse listing = await h.send("GET", "/api/v1/roots/r1/entries", token: token, query: <String, String>{"path": "/docs"});
      expect(listing.status, 403);
      expect(body(listing), <String, Object?>{"error": "forbidden"});
      expect((await get("/docs/a.txt")).status, 403);
    });

    test("upload, mkdir and rename ask for write", () async {
      final _RecordingAuthorizer authorizer = _RecordingAuthorizer(deny: (Permission p, StoragePath path) => p == Permission.write);
      await start(authorizer: authorizer);

      expect((await put("/new.txt", utf8.encode("x"))).status, 403);
      expect((await post("mkdir", <String, Object?>{"path": "/newdir"})).status, 403);
      expect((await post("rename", <String, Object?>{"path": "/readme.txt", "newName": "z.txt"})).status, 403);
      expect(await exists("/new.txt"), isFalse);
      expect(await exists("/newdir"), isFalse);
      expect(await exists("/readme.txt"), isTrue);
    });

    test("move needs read + delete on sources and write on the destination", () async {
      final _RecordingAuthorizer authorizer = _RecordingAuthorizer();
      await start(authorizer: authorizer);

      await post("move", <String, Object?>{"sources": <String>["/readme.txt"], "destination": "/docs"});

      expect(
        authorizer.asked,
        containsAll(<(Permission, String)>[
          (Permission.read, "/readme.txt"),
          (Permission.delete, "/readme.txt"),
          (Permission.write, "/docs"),
        ]),
      );
    });

    test("move is refused when delete is denied on the source, and nothing moves", () async {
      await start(authorizer: _RecordingAuthorizer(deny: (Permission p, StoragePath path) => p == Permission.delete));

      final ApiResponse response = await post("move", <String, Object?>{"sources": <String>["/readme.txt"], "destination": "/docs"});

      expect(response.status, 403);
      expect(await exists("/readme.txt"), isTrue);
      expect(await exists("/docs/readme.txt"), isFalse);
    });

    test("copy only needs read on sources, and one denied source stops the whole batch", () async {
      await start(authorizer: _RecordingAuthorizer(deny: (Permission p, StoragePath path) => path.name == "page.html"));

      final ApiResponse response = await post("copy", <String, Object?>{
        "sources": <String>["/readme.txt", "/page.html"],
        "destination": "/docs",
      });

      expect(response.status, 403);
      expect(await exists("/docs/readme.txt"), isFalse, reason: "nothing is copied when any item is off limits");
    });

    test("delete asks for delete", () async {
      await start(authorizer: _RecordingAuthorizer(deny: (Permission p, StoragePath path) => p == Permission.delete));

      expect((await post("delete", <String, Object?>{"paths": <String>["/readme.txt"]})).status, 403);
      expect(await exists("/readme.txt"), isTrue);
    });
  });

  group("download tickets", () {
    Future<String> ticketFor(String p) async {
      final ApiResponse response = await post("ticket", <String, Object?>{"path": p});
      expect(response.status, 200, reason: p);
      final String url = body(response)["url"]! as String;
      expect(url, startsWith("/d/"));
      return url;
    }

    test("a logged-in caller gets a link that downloads without any header", () async {
      final String url = await ticketFor("/readme.txt");

      final ApiResponse response = await h.send("GET", url);
      expect(response.status, 200);
      expect(utf8.decode(await ApiHarness.bodyBytes(response)), "hello world");
      expect(response.headers["Content-Disposition"], startsWith("attachment;"));
    });

    test("the link tells how long it lives", () async {
      final ApiResponse response = await post("ticket", <String, Object?>{"path": "/readme.txt"});
      expect(body(response)["expiresInSeconds"], 900);
    });

    test("ranges, HEAD and inline work through a ticket", () async {
      final String url = await ticketFor("/readme.txt");

      final ApiResponse range = await h.send("GET", url, headers: <String, String>{"range": "bytes=0-4"});
      expect(range.status, 206);
      expect(utf8.decode(await ApiHarness.bodyBytes(range)), "hello");

      expect((await h.send("HEAD", url)).contentLength, 11);

      final ApiResponse inline = await h.send("GET", url, query: <String, String>{"inline": "1"});
      expect(inline.headers["Content-Disposition"], startsWith("inline;"));
    });

    test("an unknown ticket is a plain 404", () async {
      expect((await h.send("GET", "/d/not-a-real-ticket")).status, 404);
      expect((await h.send("GET", "/d")).status, 404);
      expect((await h.send("GET", "/d/a/b")).status, 404);
    });

    test("a ticket expires", () async {
      final String url = await ticketFor("/readme.txt");
      h.clock.advance(const Duration(minutes: 16));

      expect((await h.send("GET", url)).status, 404);
    });

    test("logging out kills the links that session made", () async {
      final String url = await ticketFor("/readme.txt");
      expect((await h.send("POST", "/api/v1/auth/logout", token: token)).status, 204);

      expect((await h.send("GET", url)).status, 404);
    });

    test("a ticket opens one file and only reads", () async {
      final String url = await ticketFor("/readme.txt");

      expect((await h.send("PUT", url, bytes: utf8.encode("x"))).status, 405);
      expect((await h.send("DELETE", url)).status, 405);
      expect(await contentOf("/readme.txt"), "hello world");
    });

    test("no tickets for folders, missing files or the recycle bin", () async {
      expect((await post("ticket", <String, Object?>{"path": "/docs"})).status, 400);
      expect((await post("ticket", <String, Object?>{"path": "/nope.txt"})).status, 404);
      expect((await post("ticket", <String, Object?>{"path": "/.vaultbox/recycle/keep.txt"})).status, 404);
      expect((await post("ticket", <String, Object?>{"path": "/../x"})).status, 400);
      expect((await post("ticket", <String, Object?>{})).status, 400);
    });

    test("asking for a ticket needs a login", () async {
      final ApiResponse response = await h.send(
        "POST",
        "/api/v1/roots/r1/ticket",
        json: <String, Object?>{"path": "/readme.txt"},
      );
      expect(response.status, 401);
    });

    test("the Authorizer is asked again when the link is used", () async {
      bool blocked = false;
      await start(authorizer: _RecordingAuthorizer(deny: (Permission p, StoragePath path) => blocked));
      final String url = await ticketFor("/readme.txt");
      expect((await h.send("GET", url)).status, 200);

      blocked = true; // e.g. access was taken away after the link was made

      expect((await h.send("GET", url)).status, 403);
    });

    test("a ticket for a file that has since been deleted is a 404", () async {
      final String url = await ticketFor("/readme.txt");
      await backend.delete(sp("/readme.txt"));

      expect((await h.send("GET", url)).status, 404);
    });
  });

  test("stat describes one item and the root", () async {
    final ApiResponse file = await h.send("GET", "/api/v1/roots/r1/stat", token: token, query: <String, String>{"path": "/readme.txt"});
    expect(file.status, 200);
    expect(body(file)["type"], "file");
    expect(body(file)["size"], 11);
    expect(body(file)["path"], "/readme.txt");

    final ApiResponse root = await h.send("GET", "/api/v1/roots/r1/stat", token: token);
    expect(body(root)["type"], "directory");
    expect(body(root)["path"], "/");

    expect((await h.send("GET", "/api/v1/roots/r1/stat", token: token, query: <String, String>{"path": "/nope"})).status, 404);
    expect((await h.send("GET", "/api/v1/roots/r1/stat", token: token, query: <String, String>{"path": "/.vaultbox"})).status, 404);
  });

  test("every endpoint needs a token", () async {
    for (final (String, String) call in <(String, String)>[
      ("GET", "entries"),
      ("GET", "stat"),
      ("GET", "content"),
      ("PUT", "content"),
      ("POST", "ticket"),
      ("POST", "mkdir"),
      ("POST", "rename"),
      ("POST", "move"),
      ("POST", "copy"),
      ("POST", "delete"),
    ]) {
      final ApiResponse response = await h.send(call.$1, "/api/v1/roots/r1/${call.$2}");
      expect(response.status, 401, reason: "${call.$1} ${call.$2}");
    }
  });
}
