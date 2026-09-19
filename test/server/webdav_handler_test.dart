import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/security/authorizer.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/server/api/api_types.dart";

import "../helpers/dav_harness.dart";

const String _propfindAll = '<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:allprop/></D:propfind>';
const String _lockInfo =
    '<?xml version="1.0"?><D:lockinfo xmlns:D="DAV:"><D:lockscope><D:exclusive/></D:lockscope>'
    "<D:locktype><D:write/></D:locktype><D:owner><D:href>admin</D:href></D:owner></D:lockinfo>";

String _propfindProps(List<String> names) =>
    '<D:propfind xmlns:D="DAV:"><D:prop>${names.map((String n) => "<D:$n/>").join()}</D:prop></D:propfind>';

final class _DenyingAuthorizer implements Authorizer {
  _DenyingAuthorizer(this.deny);

  final bool Function(Permission permission, StoragePath path) deny;

  @override
  bool allows(Account account, Permission permission, StorageRoot root, StoragePath path) => !deny(permission, path);
}

void main() {
  late DavHarness h;

  setUp(() => h = DavHarness());

  StoragePath sp(String value, {String root = "r1"}) => StoragePath.parseDecoded(root, value);
  Future<bool> exists(String value, {String root = "r1"}) async =>
      (await (root == "r1" ? h.phone : h.card).stat(sp(value, root: root))).exists;
  Future<String> contentOf(String value) async =>
      utf8.decode(await h.phone.openRead(sp(value)).expand((List<int> c) => c).toList());

  const String dest = "http://phone.local:8443/dav/Phone";

  group("authentication", () {
    test("no credentials: 401 with a Basic challenge, for any method", () async {
      for (final String method in <String>["OPTIONS", "PROPFIND", "GET", "PUT", "DELETE"]) {
        final ApiResponse response = await h.send(method, "/dav/Phone/readme.txt", anonymous: true);
        expect(response.status, 401, reason: method);
        expect(response.headers["www-authenticate"], startsWith("Basic realm="), reason: method);
      }
    });

    test("wrong password, unknown user and garbage headers are 401", () async {
      for (final String header in <String>[
        DavHarness.basic("admin", "not the password"),
        DavHarness.basic("nobody", DavHarness.password),
        "Basic !!!not-base64!!!",
        "Basic ${base64.encode(utf8.encode("no-colon"))}",
        "Bearer abc",
        "Basic",
      ]) {
        expect((await h.send("OPTIONS", "/dav/", authorization: header)).status, 401, reason: header);
      }
    });

    test("a right answer is remembered, so Argon2 isn't repeated for every request", () async {
      await h.send("OPTIONS", "/dav/");
      final int afterFirst = h.hasher.verifyCalls;

      for (int i = 0; i < 5; i++) {
        expect((await h.send("OPTIONS", "/dav/")).status, 200);
      }

      expect(afterFirst, 1);
      expect(h.hasher.verifyCalls, afterFirst, reason: "later requests come from the short-lived cache");
    });

    test("the memory expires, and clear() forgets it at once", () async {
      await h.send("OPTIONS", "/dav/");
      h.clock.advance(const Duration(minutes: 6));
      await h.send("OPTIONS", "/dav/");
      expect(h.hasher.verifyCalls, 2, reason: "re-verified after the cache lifetime");

      h.auth.clear();
      await h.send("OPTIONS", "/dav/");
      expect(h.hasher.verifyCalls, 3);
    });

    test("repeated wrong passwords are throttled with 429 and Retry-After", () async {
      for (int i = 0; i < 5; i++) {
        await h.send("OPTIONS", "/dav/", authorization: DavHarness.basic("admin", "wrong $i"));
      }

      final ApiResponse response = await h.send("OPTIONS", "/dav/", authorization: DavHarness.basic("admin", "wrong again"));
      expect(response.status, 429);
      expect(response.headers["Retry-After"], "30");
    });

    test("the memory is keyed by the exact password: another password is still 401", () async {
      await h.send("OPTIONS", "/dav/"); // the right one is now remembered
      expect((await h.send("OPTIONS", "/dav/", authorization: DavHarness.basic("admin", "someone else"))).status, 401);
    });
  });

  group("OPTIONS", () {
    test("announces class 1+2 and the methods", () async {
      final ApiResponse response = await h.send("OPTIONS", "/dav/Phone/");

      expect(response.status, 200);
      expect(response.headers["DAV"], "1, 2");
      expect(response.headers["MS-Author-Via"], "DAV");
      for (final String method in <String>["PROPFIND", "MKCOL", "COPY", "MOVE", "LOCK", "UNLOCK", "PUT", "DELETE"]) {
        expect(response.headers["allow"], contains(method));
      }
    });

    test("unknown methods are 405 and list what is allowed", () async {
      final ApiResponse response = await h.send("PATCH", "/dav/Phone/readme.txt");
      expect(response.status, 405);
      expect(response.headers["allow"], contains("PROPFIND"));
    });
  });

  group("PROPFIND", () {
    test("the top folder lists the storage roots as collections", () async {
      final Map<String, Map<int, Map<String, String>>> ms = DavHarness.multistatus(
        await h.send("PROPFIND", "/dav/", headers: <String, String>{"Depth": "1"}, body: _propfindAll),
      );

      expect(ms.keys, containsAll(<String>["/dav/", "/dav/Phone/", "/dav/Card/"]));
      expect(ms["/dav/Phone/"]![200]!["resourcetype"], contains("collection"));
      expect(ms["/dav/Phone/"]![200]!["displayname"], "Phone");
    });

    test("depth 0 answers about the folder only", () async {
      final Map<String, Map<int, Map<String, String>>> ms = DavHarness.multistatus(
        await h.send("PROPFIND", "/dav/", headers: <String, String>{"Depth": "0"}, body: _propfindAll),
      );
      expect(ms.keys, <String>["/dav/"]);
    });

    test("a folder lists its children — and never the hidden .vaultbox", () async {
      final Map<String, Map<int, Map<String, String>>> ms = DavHarness.multistatus(
        await h.send("PROPFIND", "/dav/Phone/", headers: <String, String>{"Depth": "1"}, body: _propfindAll),
      );

      expect(ms.keys.toSet(), <String>{"/dav/Phone/", "/dav/Phone/readme.txt", "/dav/Phone/docs/", "/dav/Phone/empty/"});
      expect(ms.keys.any((String k) => k.toLowerCase().contains("vaultbox")), isFalse);
    });

    test("a file's properties: size, type, etag and dates", () async {
      final Map<String, Map<int, Map<String, String>>> ms = DavHarness.multistatus(
        await h.send("PROPFIND", "/dav/Phone/readme.txt", headers: <String, String>{"Depth": "0"}, body: _propfindAll),
      );
      final Map<String, String> props = ms["/dav/Phone/readme.txt"]![200]!;

      expect(props["getcontentlength"], "11");
      expect(props["getcontenttype"], "text/plain");
      expect(props["getetag"], matches(RegExp(r'^"11-[0-9a-f]+"$')));
      expect(props["resourcetype"], anyOf("", isNot(contains("collection"))));
      expect(props["displayname"], "readme.txt");
      expect(props.containsKey("supportedlock"), isTrue);
    });

    test("only the requested properties come back, unknown ones as 404", () async {
      final ApiResponse response = await h.send(
        "PROPFIND",
        "/dav/Phone/readme.txt",
        headers: <String, String>{"Depth": "0"},
        body:
            '<D:propfind xmlns:D="DAV:" xmlns:Z="urn:example"><D:prop><D:getcontentlength/><Z:color/><D:nothing/></D:prop></D:propfind>',
      );
      final Map<int, Map<String, String>> groups = DavHarness.multistatus(response)["/dav/Phone/readme.txt"]!;

      expect(groups[200]!.keys, <String>["getcontentlength"]);
      expect(groups[404]!.keys, containsAll(<String>["color", "nothing"]));
      expect(DavHarness.text(response), contains('xmlns:X="urn:example"'));
    });

    test("propname lists names without values", () async {
      final Map<String, Map<int, Map<String, String>>> ms = DavHarness.multistatus(
        await h.send(
          "PROPFIND",
          "/dav/Phone/readme.txt",
          headers: <String, String>{"Depth": "0"},
          body: '<D:propfind xmlns:D="DAV:"><D:propname/></D:propfind>',
        ),
      );
      expect(ms["/dav/Phone/readme.txt"]![200]!.keys, containsAll(<String>["getcontentlength", "getetag", "resourcetype"]));
    });

    test("an empty body means allprop; no Depth header means 1", () async {
      final Map<String, Map<int, Map<String, String>>> ms = DavHarness.multistatus(await h.send("PROPFIND", "/dav/Phone/docs/"));
      expect(ms.keys.toSet(), <String>{"/dav/Phone/docs/", "/dav/Phone/docs/a.txt"});
    });

    test("Depth: infinity is refused with the standard error body", () async {
      final ApiResponse response = await h.send("PROPFIND", "/dav/Phone/", headers: <String, String>{"Depth": "infinity"});
      expect(response.status, 403);
      expect(DavHarness.text(response), contains("propfind-finite-depth"));
    });

    test("storage quota is offered on a root when asked for", () async {
      final Map<int, Map<String, String>> groups = DavHarness.multistatus(
        await h.send(
          "PROPFIND",
          "/dav/Phone/",
          headers: <String, String>{"Depth": "0"},
          body: _propfindProps(<String>["quota-available-bytes", "quota-used-bytes"]),
        ),
      )["/dav/Phone/"]!;

      expect(groups[200]!["quota-available-bytes"], "1000");
      expect(groups[200]!["quota-used-bytes"], "4000");
    });

    test("names with spaces, %, & and non-ASCII are percent-encoded in hrefs and round-trip", () async {
      await h.send("PUT", "/dav/Phone/a%20b%26c.txt", body: "1");
      await h.send("PUT", "/dav/Phone/Report%2520final.pdf", body: "2");
      await h.send("PUT", "/dav/Phone/${Uri.encodeComponent("naïve café.txt")}", body: "3");

      final Map<String, Map<int, Map<String, String>>> ms = DavHarness.multistatus(
        await h.send("PROPFIND", "/dav/Phone/", headers: <String, String>{"Depth": "1"}, body: _propfindAll),
      );

      expect(ms["/dav/Phone/a%20b%26c.txt"]![200]!["displayname"], "a b&c.txt");
      expect(ms["/dav/Phone/Report%2520final.pdf"]![200]!["displayname"], "Report%20final.pdf");
      expect(ms["/dav/Phone/na%C3%AFve%20caf%C3%A9.txt"]![200]!["displayname"], "naïve café.txt");
    });

    test("missing items are 404; bad XML and DTDs are 400", () async {
      expect((await h.send("PROPFIND", "/dav/Phone/nope.txt", body: _propfindAll)).status, 404);
      expect((await h.send("PROPFIND", "/dav/Nowhere/", body: _propfindAll)).status, 404);
      expect((await h.send("PROPFIND", "/dav/Phone/", body: "<not xml")).status, 400);
      expect((await h.send("PROPFIND", "/dav/Phone/", body: "<propfind/>")).status, 400);
      expect(
        (await h.send(
          "PROPFIND",
          "/dav/Phone/",
          body:
              '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "aaaa">]><D:propfind xmlns:D="DAV:"><D:allprop/></D:propfind>',
        )).status,
        400,
      );
    });

    test("the hidden folder and traversal never resolve", () async {
      expect((await h.send("PROPFIND", "/dav/Phone/.vaultbox/", body: _propfindAll)).status, 404);
      expect((await h.send("PROPFIND", "/dav/Phone/%2e%2e/", body: _propfindAll)).status, 400);
      expect((await h.send("PROPFIND", "/dav/Phone/docs/..", body: _propfindAll)).status, 400);
    });

    test("an oversized body is 413", () async {
      final ApiResponse response = await h.send("PROPFIND", "/dav/Phone/", body: List<int>.filled(70 * 1024, 0x20));
      expect(response.status, 413);
    });

    test("items the Authorizer hides are left out of a listing", () async {
      h = DavHarness(authorizer: _DenyingAuthorizer((Permission p, StoragePath path) => path.name == "docs"));

      final Map<String, Map<int, Map<String, String>>> ms = DavHarness.multistatus(
        await h.send("PROPFIND", "/dav/Phone/", headers: <String, String>{"Depth": "1"}, body: _propfindAll),
      );
      expect(ms.keys, isNot(contains("/dav/Phone/docs/")));
      expect(ms.keys, contains("/dav/Phone/readme.txt"));
      expect((await h.send("PROPFIND", "/dav/Phone/docs/", body: _propfindAll)).status, 403);
    });
  });

  group("GET and HEAD", () {
    test("GET streams the file with validators", () async {
      final ApiResponse response = await h.send("GET", "/dav/Phone/readme.txt");

      expect(response.status, 200);
      expect(utf8.decode(await DavHarness.bodyBytes(response)), "hello world");
      expect(response.contentType, "text/plain");
      expect(response.headers["Accept-Ranges"], "bytes");
      expect(response.headers["ETag"], matches(RegExp(r'^"11-[0-9a-f]+"$')));
      expect(response.headers["Content-Security-Policy"], contains("sandbox"));
    });

    test("byte ranges give 206 and the right slice", () async {
      final ApiResponse response = await h.send("GET", "/dav/Phone/readme.txt", headers: <String, String>{"Range": "bytes=6-"});
      expect(response.status, 206);
      expect(utf8.decode(await DavHarness.bodyBytes(response)), "world");
      expect(response.headers["Content-Range"], "bytes 6-10/11");

      expect((await h.send("GET", "/dav/Phone/readme.txt", headers: <String, String>{"Range": "bytes=50-"})).status, 416);
    });

    test("HEAD has the headers and no body", () async {
      final ApiResponse response = await h.send("HEAD", "/dav/Phone/readme.txt");
      expect(response.status, 200);
      expect(response.contentLength, 11);
      expect(await DavHarness.bodyBytes(response), isEmpty);
    });

    test("a folder answers with a short note, not an error", () async {
      for (final String path in <String>["/dav/", "/dav/Phone/", "/dav/Phone/docs/"]) {
        final ApiResponse response = await h.send("GET", path);
        expect(response.status, 200, reason: path);
        expect(DavHarness.text(response), contains("WebDAV"));
      }
    });

    test("missing files, the hidden folder and traversal", () async {
      expect((await h.send("GET", "/dav/Phone/nope.txt")).status, 404);
      expect((await h.send("GET", "/dav/Phone/.vaultbox/recycle/keep.txt")).status, 404);
      expect((await h.send("GET", "/dav/Phone/%2e%2e/etc")).status, 400);
    });

    test("a denied read is 403", () async {
      h = DavHarness(authorizer: _DenyingAuthorizer((Permission p, StoragePath path) => path.name == "readme.txt"));
      expect((await h.send("GET", "/dav/Phone/readme.txt")).status, 403);
    });
  });

  group("PUT", () {
    test("creates (201) then replaces (204)", () async {
      expect((await h.send("PUT", "/dav/Phone/new.txt", body: "one")).status, 201);
      expect(await contentOf("/new.txt"), "one");

      expect((await h.send("PUT", "/dav/Phone/new.txt", body: "two")).status, 204);
      expect(await contentOf("/new.txt"), "two");
    });

    test("an empty file is fine", () async {
      expect((await h.send("PUT", "/dav/Phone/empty.bin")).status, 201);
      expect(await contentOf("/empty.bin"), "");
    });

    test("If-None-Match: * refuses to overwrite", () async {
      final ApiResponse response = await h.send("PUT", "/dav/Phone/readme.txt", headers: <String, String>{"If-None-Match": "*"}, body: "x");
      expect(response.status, 412);
      expect(await contentOf("/readme.txt"), "hello world");
    });

    test("the parent must exist, and a folder can't be overwritten by a file", () async {
      expect((await h.send("PUT", "/dav/Phone/missing/new.txt", body: "x")).status, 409);
      expect(await exists("/missing"), isFalse);
      expect((await h.send("PUT", "/dav/Phone/docs", body: "x")).status, 405);
    });

    test("not on a storage root itself, the top folder, the hidden folder or a read-only card", () async {
      expect((await h.send("PUT", "/dav/Phone", body: "x")).status, 403);
      expect((await h.send("PUT", "/dav/x.txt", body: "x")).status, 404, reason: "no such storage location");
      expect((await h.send("PUT", "/dav/Phone/.vaultbox/x.txt", body: "x")).status, 404);
      expect((await h.send("PUT", "/dav/Card/new.jpg", body: "x")).status, 403);
      expect(await exists("/new.jpg", root: "r2"), isFalse);
    });

    test("a connection that breaks mid-upload keeps the old file and creates nothing", () async {
      Stream<List<int>> broken() async* {
        yield utf8.encode("part");
        throw const FormatException("connection reset");
      }

      expect((await h.send("PUT", "/dav/Phone/broken.txt", stream: broken())).status, 400);
      expect(await exists("/broken.txt"), isFalse);

      expect((await h.send("PUT", "/dav/Phone/readme.txt", stream: broken())).status, 400);
      expect(await contentOf("/readme.txt"), "hello world");
    });
  });

  group("MKCOL", () {
    test("creates a folder", () async {
      expect((await h.send("MKCOL", "/dav/Phone/docs/sub")).status, 201);
      expect(await exists("/docs/sub"), isTrue);
    });

    test("existing (405), missing parent (409), body (415), read-only (403), root (403)", () async {
      expect((await h.send("MKCOL", "/dav/Phone/docs")).status, 405);
      expect((await h.send("MKCOL", "/dav/Phone/a/b")).status, 409);
      expect((await h.send("MKCOL", "/dav/Phone/withbody", body: "<x/>")).status, 415);
      expect((await h.send("MKCOL", "/dav/Card/new")).status, 403);
      expect((await h.send("MKCOL", "/dav/Phone")).status, 403);
      expect(await exists("/withbody"), isFalse);
    });
  });

  group("DELETE", () {
    test("moves the item to the Recycle Bin", () async {
      expect((await h.send("DELETE", "/dav/Phone/readme.txt")).status, 204);

      expect(await exists("/readme.txt"), isFalse);
      final List<String> recycled = await h.phone.list(sp("/.vaultbox/recycle")).map((e) => e.name).toList();
      expect(recycled.any((String n) => n.endsWith("__readme.txt")), isTrue);
    });

    test("a folder goes as one item", () async {
      expect((await h.send("DELETE", "/dav/Phone/docs/")).status, 204);
      expect(await exists("/docs"), isFalse);
    });

    test("missing is 404; roots, the top folder, read-only and the hidden folder are refused", () async {
      expect((await h.send("DELETE", "/dav/Phone/nope.txt")).status, 404);
      expect((await h.send("DELETE", "/dav/Phone/")).status, 403);
      expect((await h.send("DELETE", "/dav/")).status, 403);
      expect((await h.send("DELETE", "/dav/Card/photo.jpg")).status, 403);
      expect(await exists("/photo.jpg", root: "r2"), isTrue);
      expect((await h.send("DELETE", "/dav/Phone/.vaultbox/recycle")).status, 404);
    });

    test("a denied delete is 403 and leaves the file", () async {
      h = DavHarness(authorizer: _DenyingAuthorizer((Permission p, StoragePath path) => p == Permission.delete));
      expect((await h.send("DELETE", "/dav/Phone/readme.txt")).status, 403);
      expect(await exists("/readme.txt"), isTrue);
    });
  });

  group("COPY and MOVE", () {
    test("COPY leaves the source and creates the copy (201)", () async {
      final ApiResponse response = await h.send("COPY", "/dav/Phone/readme.txt", headers: <String, String>{"Destination": "$dest/copy.txt"});

      expect(response.status, 201);
      expect(await contentOf("/copy.txt"), "hello world");
      expect(await exists("/readme.txt"), isTrue);
    });

    test("COPY of a folder copies what is inside; Depth 0 copies only the folder", () async {
      expect((await h.send("COPY", "/dav/Phone/docs/", headers: <String, String>{"Destination": "$dest/docs2/"})).status, 201);
      expect(await contentOf("/docs2/a.txt"), "A");

      expect(
        (await h.send("COPY", "/dav/Phone/docs/", headers: <String, String>{"Destination": "$dest/docs3/", "Depth": "0"})).status,
        201,
      );
      expect(await exists("/docs3"), isTrue);
      expect(await exists("/docs3/a.txt"), isFalse);
    });

    test("MOVE renames in place and moves between folders", () async {
      expect((await h.send("MOVE", "/dav/Phone/readme.txt", headers: <String, String>{"Destination": "$dest/renamed.txt"})).status, 201);
      expect(await exists("/readme.txt"), isFalse);
      expect(await contentOf("/renamed.txt"), "hello world");

      expect((await h.send("MOVE", "/dav/Phone/renamed.txt", headers: <String, String>{"Destination": "$dest/docs/moved.txt"})).status, 201);
      expect(await exists("/renamed.txt"), isFalse);
      expect(await contentOf("/docs/moved.txt"), "hello world");
    });

    test("destination percent-encoding is decoded once", () async {
      final String encoded = "$dest/${Uri.encodeComponent("100% done.txt")}";
      expect((await h.send("COPY", "/dav/Phone/readme.txt", headers: <String, String>{"Destination": encoded})).status, 201);
      expect(await exists("/100% done.txt"), isTrue);
    });

    test("Overwrite: F refuses (412); the default replaces a file (204) in place", () async {
      await h.send("PUT", "/dav/Phone/target.txt", body: "old");

      final ApiResponse refused = await h.send(
        "COPY",
        "/dav/Phone/readme.txt",
        headers: <String, String>{"Destination": "$dest/target.txt", "Overwrite": "F"},
      );
      expect(refused.status, 412);
      expect(await contentOf("/target.txt"), "old");

      final ApiResponse replaced = await h.send("COPY", "/dav/Phone/readme.txt", headers: <String, String>{"Destination": "$dest/target.txt"});
      expect(replaced.status, 204);
      expect(await contentOf("/target.txt"), "hello world");
    });

    test("overwriting a folder keeps the old one in the Recycle Bin", () async {
      await h.send("MKCOL", "/dav/Phone/victim");
      await h.send("PUT", "/dav/Phone/victim/keep-me.txt", body: "precious");

      final ApiResponse response = await h.send("MOVE", "/dav/Phone/docs/", headers: <String, String>{"Destination": "$dest/victim/"});

      expect(response.status, 204);
      expect(await contentOf("/victim/a.txt"), "A");
      expect(await exists("/victim/keep-me.txt"), isFalse);
      final List<String> recycled = await h.phone.list(sp("/.vaultbox/recycle")).map((e) => e.name).toList();
      expect(recycled.any((String n) => n.endsWith("__victim")), isTrue, reason: "the replaced folder is recoverable");
    });

    test("onto itself or into its own subtree is 403", () async {
      expect((await h.send("COPY", "/dav/Phone/docs/", headers: <String, String>{"Destination": "$dest/docs/"})).status, 403);
      expect((await h.send("MOVE", "/dav/Phone/docs/", headers: <String, String>{"Destination": "$dest/docs/inner/"})).status, 403);
      expect(await exists("/docs/a.txt"), isTrue);
    });

    test("missing pieces: no Destination (400), missing source (404), missing parent (409)", () async {
      expect((await h.send("COPY", "/dav/Phone/readme.txt")).status, 400);
      expect((await h.send("COPY", "/dav/Phone/readme.txt", headers: <String, String>{"Destination": "http://x/elsewhere/a"})).status, 400);
      expect((await h.send("COPY", "/dav/Phone/nope.txt", headers: <String, String>{"Destination": "$dest/a.txt"})).status, 404);
      expect((await h.send("COPY", "/dav/Phone/readme.txt", headers: <String, String>{"Destination": "$dest/nodir/a.txt"})).status, 409);
    });

    test("between storage locations: copy from the read-only card works, moving out of it doesn't", () async {
      expect(
        (await h.send("COPY", "/dav/Card/photo.jpg", headers: <String, String>{"Destination": "$dest/photo.jpg"})).status,
        201,
      );
      expect(await contentOf("/photo.jpg"), "jpg");

      expect(
        (await h.send("MOVE", "/dav/Card/photo.jpg", headers: <String, String>{"Destination": "$dest/photo2.jpg"})).status,
        403,
      );
      expect(await exists("/photo.jpg", root: "r2"), isTrue);
      expect(
        (await h.send("COPY", "/dav/Phone/readme.txt", headers: <String, String>{"Destination": "http://x/dav/Card/r.txt"})).status,
        403,
      );
    });

    test("roots and the top folder can't be copied or moved", () async {
      expect((await h.send("MOVE", "/dav/Phone/", headers: <String, String>{"Destination": "$dest/x/"})).status, 403);
      expect((await h.send("COPY", "/dav/", headers: <String, String>{"Destination": "$dest/x/"})).status, 403);
      expect((await h.send("COPY", "/dav/Phone/readme.txt", headers: <String, String>{"Destination": "http://x/dav/Phone"})).status, 403);
    });
  });

  group("locks", () {
    String? tokenOf(ApiResponse r) => RegExp(r"<(opaquelocktoken:[^>]+)>").firstMatch(r.headers["Lock-Token"] ?? "")?.group(1);

    test("LOCK on an existing file returns a token and the lock description", () async {
      final ApiResponse response = await h.send("LOCK", "/dav/Phone/readme.txt", body: _lockInfo, headers: <String, String>{"Timeout": "Second-300"});

      expect(response.status, 200);
      expect(tokenOf(response), isNotNull);
      expect(DavHarness.text(response), allOf(contains("activelock"), contains("Second-300"), contains("exclusive")));
    });

    test("LOCK on a new name reserves it as an empty file (201)", () async {
      final ApiResponse response = await h.send("LOCK", "/dav/Phone/fresh.docx", body: _lockInfo);

      expect(response.status, 201);
      expect(await exists("/fresh.docx"), isTrue);
      expect(await contentOf("/fresh.docx"), "");
    });

    test("while locked, writing needs the token (423 without, ok with)", () async {
      final String token = tokenOf(await h.send("LOCK", "/dav/Phone/readme.txt", body: _lockInfo))!;

      expect((await h.send("PUT", "/dav/Phone/readme.txt", body: "x")).status, 423);
      expect((await h.send("DELETE", "/dav/Phone/readme.txt")).status, 423);
      expect((await h.send("MOVE", "/dav/Phone/readme.txt", headers: <String, String>{"Destination": "$dest/r2.txt"})).status, 423);
      expect(await contentOf("/readme.txt"), "hello world");

      final ApiResponse ok = await h.send("PUT", "/dav/Phone/readme.txt", body: "changed", headers: <String, String>{"If": "(<$token>)"});
      expect(ok.status, 204);
      expect(await contentOf("/readme.txt"), "changed");
    });

    test("a second exclusive lock on the same file is 423", () async {
      await h.send("LOCK", "/dav/Phone/readme.txt", body: _lockInfo);
      expect((await h.send("LOCK", "/dav/Phone/readme.txt", body: _lockInfo)).status, 423);
    });

    test("a lock on a folder covers what is inside it", () async {
      final String token = tokenOf(await h.send("LOCK", "/dav/Phone/docs/", body: _lockInfo))!;

      expect((await h.send("PUT", "/dav/Phone/docs/a.txt", body: "x")).status, 423);
      expect((await h.send("PUT", "/dav/Phone/docs/a.txt", body: "x", headers: <String, String>{"If": "(<$token>)"})).status, 204);
      expect((await h.send("DELETE", "/dav/Phone/docs/")).status, 423);
    });

    test("deleting a folder is blocked by a lock on something inside it", () async {
      await h.send("LOCK", "/dav/Phone/docs/a.txt", body: _lockInfo);
      expect((await h.send("DELETE", "/dav/Phone/docs/")).status, 423);
      expect(await exists("/docs/a.txt"), isTrue);
    });

    test("refresh extends the lock; UNLOCK releases it", () async {
      final String token = tokenOf(await h.send("LOCK", "/dav/Phone/readme.txt", body: _lockInfo, headers: <String, String>{"Timeout": "Second-60"}))!;
      h.clock.advance(const Duration(seconds: 50));

      final ApiResponse refreshed = await h.send(
        "LOCK",
        "/dav/Phone/readme.txt",
        headers: <String, String>{"If": "(<$token>)", "Timeout": "Second-60"},
      );
      expect(refreshed.status, 200);
      h.clock.advance(const Duration(seconds: 50));
      expect((await h.send("PUT", "/dav/Phone/readme.txt", body: "x")).status, 423, reason: "still locked after the refresh");

      expect((await h.send("UNLOCK", "/dav/Phone/readme.txt", headers: <String, String>{"Lock-Token": "<$token>"})).status, 204);
      expect((await h.send("PUT", "/dav/Phone/readme.txt", body: "free")).status, 204);
    });

    test("UNLOCK with a wrong token is 409; without a header 400", () async {
      await h.send("LOCK", "/dav/Phone/readme.txt", body: _lockInfo);
      expect((await h.send("UNLOCK", "/dav/Phone/readme.txt", headers: <String, String>{"Lock-Token": "<opaquelocktoken:nope>"})).status, 409);
      expect((await h.send("UNLOCK", "/dav/Phone/readme.txt")).status, 400);
    });

    test("a lock expires by itself", () async {
      await h.send("LOCK", "/dav/Phone/readme.txt", body: _lockInfo, headers: <String, String>{"Timeout": "Second-30"});
      h.clock.advance(const Duration(seconds: 31));
      expect((await h.send("PUT", "/dav/Phone/readme.txt", body: "x")).status, 204);
    });

    test("PROPFIND shows the active lock", () async {
      final String token = tokenOf(await h.send("LOCK", "/dav/Phone/readme.txt", body: _lockInfo))!;

      final Map<String, Map<int, Map<String, String>>> ms = DavHarness.multistatus(
        await h.send("PROPFIND", "/dav/Phone/readme.txt", headers: <String, String>{"Depth": "0"}, body: _propfindProps(<String>["lockdiscovery"])),
      );
      expect(ms["/dav/Phone/readme.txt"]![200]!["lockdiscovery"], contains(token));
    });

    test("bad lock requests: garbage body 400, refresh with no lock 412, read-only card 403", () async {
      expect((await h.send("LOCK", "/dav/Phone/readme.txt", body: "<nope")).status, 400);
      expect((await h.send("LOCK", "/dav/Phone/readme.txt")).status, 412);
      expect((await h.send("LOCK", "/dav/Card/photo.jpg", body: _lockInfo)).status, 403);
    });
  });

  group("PROPPATCH", () {
    String update(String namespace) =>
        '<D:propertyupdate xmlns:D="DAV:" xmlns:P="$namespace"><D:set><D:prop><P:Win32LastModifiedTime>x</P:Win32LastModifiedTime></D:prop></D:set></D:propertyupdate>';

    test("Microsoft's cosmetic properties are accepted, real ones refused honestly", () async {
      final Map<int, Map<String, String>> ms = DavHarness.multistatus(
        await h.send(
          "PROPPATCH",
          "/dav/Phone/readme.txt",
          body:
              '<D:propertyupdate xmlns:D="DAV:" xmlns:M="urn:schemas-microsoft-com:" xmlns:Z="urn:example"><D:set><D:prop><M:Win32FileAttributes>20</M:Win32FileAttributes><Z:rating>5</Z:rating></D:prop></D:set></D:propertyupdate>',
        ),
      )["/dav/Phone/readme.txt"]!;

      expect(ms[200]!.keys, <String>["Win32FileAttributes"]);
      expect(ms[403]!.keys, <String>["rating"]);
    });

    test("missing item 404, garbage 400, read-only 403, locked 423", () async {
      expect((await h.send("PROPPATCH", "/dav/Phone/nope.txt", body: update("urn:schemas-microsoft-com:"))).status, 404);
      expect((await h.send("PROPPATCH", "/dav/Phone/readme.txt", body: "<x")).status, 400);
      expect((await h.send("PROPPATCH", "/dav/Card/photo.jpg", body: update("urn:schemas-microsoft-com:"))).status, 403);

      await h.send("LOCK", "/dav/Phone/readme.txt", body: _lockInfo);
      expect((await h.send("PROPPATCH", "/dav/Phone/readme.txt", body: update("urn:schemas-microsoft-com:"))).status, 423);
    });
  });

  group("root names", () {
    test("names that would collide get -2, -3 (ignoring case); odd characters become dashes", () async {
      h = DavHarness(withCard: false, extraRootNames: <String>["My Files", "My-Files", "my files", "Docs & Stuff", "***"]);

      final Map<String, Map<int, Map<String, String>>> ms = DavHarness.multistatus(
        await h.send("PROPFIND", "/dav/", headers: <String, String>{"Depth": "1"}, body: _propfindAll),
      );

      expect(
        ms.keys.toSet(),
        <String>{
          "/dav/",
          "/dav/Phone/",
          "/dav/My-Files/",
          "/dav/My-Files-2/",
          "/dav/my-files-3/",
          "/dav/Docs-Stuff/",
          "/dav/storage/",
        },
      );
      expect(ms["/dav/My-Files-2/"]![200]!["displayname"], "My-Files");
    });

    test("a root is addressed case-insensitively", () async {
      expect((await h.send("PROPFIND", "/dav/phone/", body: _propfindAll)).status, 207);
      expect((await h.send("GET", "/dav/PHONE/readme.txt")).status, 200);
    });
  });
}
