import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/server/request_router.dart";
import "package:vaultbox/server/server_main.dart" show isPrivateIPv4;

/// The router over plain loopback sockets (TLS is HttpsListener's job and is
/// verified on a device — a certificate can't be minted in a plain Dart test).
void main() {
  late HttpServer server;
  late Uri base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(RequestRouter().serve(server));
    base = Uri(scheme: "http", host: "127.0.0.1", port: server.port);
  });
  tearDown(() => server.close(force: true));

  Future<HttpClientResponse> send(String method, String path) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.openUrl(method, base.replace(path: path));
      return await request.close();
    } finally {
      client.close();
    }
  }

  Future<String> body(HttpClientResponse response) => utf8.decoder.bind(response).join();

  test("GET /health/ answers ok JSON", () async {
    final HttpClientResponse response = await send("GET", "/health/");
    expect(response.statusCode, 200);
    expect(response.headers.contentType?.mimeType, "application/json");
    expect(jsonDecode(await body(response)), <String, Object?>{"status": "ok", "app": "vaultbox"});
  });

  test("every response carries the security headers", () async {
    for (final String path in <String>["/health/", "/nope"]) {
      final HttpClientResponse response = await send("GET", path);
      await body(response);
      expect(response.headers.value("cache-control"), "no-store", reason: path);
      expect(response.headers.value("x-content-type-options"), "nosniff", reason: path);
      expect(response.headers.value("content-security-policy"), "default-src 'none'", reason: path);
      expect(response.headers.value("referrer-policy"), "no-referrer", reason: path);
      expect(response.headers.value("strict-transport-security"), isNotNull, reason: path);
    }
  });

  test("unknown paths are a JSON 404 that reveals nothing", () async {
    final HttpClientResponse response = await send("GET", "/api/v1/secrets");
    expect(response.statusCode, 404);
    expect(jsonDecode(await body(response)), <String, Object?>{"error": "not_found"});
  });

  test("the wrong method is 405 with an Allow header", () async {
    final HttpClientResponse response = await send("POST", "/health/");
    await body(response);
    expect(response.statusCode, 405);
    expect(response.headers.value("allow"), "GET");
  });

  group("isPrivateIPv4", () {
    test("accepts RFC 1918 ranges", () {
      for (final String ip in <String>["10.0.0.5", "172.16.0.1", "172.31.255.254", "192.168.1.42"]) {
        expect(isPrivateIPv4(ip), isTrue, reason: ip);
      }
    });

    test("rejects public, loopback, link-local and junk", () {
      for (final String ip in <String>["8.8.8.8", "127.0.0.1", "172.32.0.1", "172.15.0.1", "169.254.1.1", "192.169.0.1", "", "1.2.3", "a.b.c.d"]) {
        expect(isPrivateIPv4(ip), isFalse, reason: ip);
      }
    });
  });
}
