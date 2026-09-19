import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";
import "package:vaultbox/server/request_router.dart";

import "../helpers/dav_harness.dart";

/// WebDAV through the real HTTP stack: custom methods, status lines, headers and
/// streamed bodies exactly as a client such as `curl -X PROPFIND` sees them.
void main() {
  late HttpServer server;
  late Uri base;
  late DavHarness h;

  setUp(() async {
    h = DavHarness();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(RequestRouter(dav: h.handler).serve(server));
    base = Uri(scheme: "http", host: "127.0.0.1", port: server.port);
  });
  tearDown(() => server.close(force: true));

  Future<({int status, String reason, HttpHeaders headers, String body})> dav(
    String method,
    String path, {
    Map<String, String> headers = const <String, String>{},
    List<int>? body,
    bool anonymous = false,
  }) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.openUrl(method, base.resolve(path));
      if (!anonymous) request.headers.set("Authorization", DavHarness.basic("admin", DavHarness.password));
      headers.forEach(request.headers.set);
      if (body != null) request.add(body);
      final HttpClientResponse response = await request.close();
      final String text = await utf8.decoder.bind(response).join();
      return (status: response.statusCode, reason: response.reasonPhrase, headers: response.headers, body: text);
    } finally {
      client.close();
    }
  }

  test("OPTIONS: 401 challenge without credentials, class 1+2 with them", () async {
    final r = await dav("OPTIONS", "/dav/", anonymous: true);
    expect(r.status, 401);
    expect(r.headers.value("www-authenticate"), startsWith("Basic realm="));

    final ok = await dav("OPTIONS", "/dav/");
    expect(ok.status, 200);
    expect(ok.headers.value("dav"), "1, 2");
    expect(ok.headers.value("allow"), contains("PROPFIND"));
  });

  test("a whole session: MKCOL, PUT, PROPFIND, GET (with range), MOVE, LOCK, DELETE", () async {
    expect((await dav("MKCOL", "/dav/Phone/projects")).status, 201);

    final String payload = String.fromCharCodes(List<int>.generate(100000, (int i) => 97 + i % 26));
    expect((await dav("PUT", "/dav/Phone/projects/big.txt", body: utf8.encode(payload))).status, 201);

    final listing = await dav(
      "PROPFIND",
      "/dav/Phone/projects/",
      headers: <String, String>{"Depth": "1", "Content-Type": "application/xml"},
      body: utf8.encode('<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:allprop/></D:propfind>'),
    );
    expect(listing.status, 207);
    expect(listing.reason, "Multi-Status");
    expect(listing.headers.contentType?.mimeType, "application/xml");
    expect(listing.body, contains("<D:href>/dav/Phone/projects/big.txt</D:href>"));
    expect(listing.body, contains("<D:getcontentlength>100000</D:getcontentlength>"));

    final whole = await dav("GET", "/dav/Phone/projects/big.txt");
    expect(whole.status, 200);
    expect(whole.body, payload);
    expect(whole.headers.value("content-length"), "100000");

    final part = await dav("GET", "/dav/Phone/projects/big.txt", headers: <String, String>{"Range": "bytes=10-19"});
    expect(part.status, 206);
    expect(part.body, payload.substring(10, 20));
    expect(part.headers.value("content-range"), "bytes 10-19/100000");

    final moved = await dav(
      "MOVE",
      "/dav/Phone/projects/big.txt",
      headers: <String, String>{"Destination": "${base.origin}/dav/Phone/projects/renamed.txt"},
    );
    expect(moved.status, 201);
    expect((await dav("GET", "/dav/Phone/projects/big.txt")).status, 404);

    final locked = await dav(
      "LOCK",
      "/dav/Phone/projects/renamed.txt",
      headers: <String, String>{"Timeout": "Second-120"},
      body: utf8.encode(
        '<?xml version="1.0"?><D:lockinfo xmlns:D="DAV:"><D:lockscope><D:exclusive/></D:lockscope>'
        "<D:locktype><D:write/></D:locktype></D:lockinfo>",
      ),
    );
    expect(locked.status, 200);
    final String? token = RegExp(r"<(opaquelocktoken:[^>]+)>").firstMatch(locked.headers.value("lock-token") ?? "")?.group(1);
    expect(token, isNotNull);

    final blocked = await dav("DELETE", "/dav/Phone/projects/renamed.txt");
    expect(blocked.status, 423);
    expect(blocked.reason, "Locked");

    final deleted = await dav("DELETE", "/dav/Phone/projects/renamed.txt", headers: <String, String>{"If": "(<$token>)"});
    expect(deleted.status, 204);
  });

  test("chunked uploads (Windows and macOS send them) work", () async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.openUrl("PUT", base.resolve("/dav/Phone/chunked.bin"));
      request.headers.set("Authorization", DavHarness.basic("admin", DavHarness.password));
      request.headers.chunkedTransferEncoding = true;
      request.add(List<int>.filled(30000, 1));
      await request.flush();
      request.add(List<int>.filled(30000, 2));
      final HttpClientResponse response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, 201);
      final stat = await h.phone.stat(StoragePath.parseDecoded("r1", "/chunked.bin"));
      expect(stat.sizeBytes, 60000);
    } finally {
      client.close();
    }
  });

  test("a wrong password over HTTP is 401 and a plain listing needs no body", () async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.openUrl("PROPFIND", base.resolve("/dav/"));
      request.headers.set("Authorization", DavHarness.basic("admin", "wrong wrong wrong"));
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 401);
    } finally {
      client.close();
    }

    final ok = await dav("PROPFIND", "/dav/", headers: <String, String>{"Depth": "0"});
    expect(ok.status, 207);
  });

  test("the API and the portal are separate: /dav is all this router serves here", () async {
    expect((await dav("GET", "/api/v1/me")).status, 404);
    expect((await dav("GET", "/")).status, 404);
  });
}
