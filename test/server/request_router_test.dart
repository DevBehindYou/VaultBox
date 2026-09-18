import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/server/network_addresses.dart";
import "package:vaultbox/server/request_router.dart";

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

  test("the root path is a plain 404 (nothing is served there)", () async {
    final HttpClientResponse response = await send("GET", "/");
    await body(response);
    expect(response.statusCode, 404);
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

  group("plain-HTTP router", () {
    test("omits HSTS (meaningless without TLS) but keeps the other headers", () async {
      final HttpServer plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => plain.close(force: true));
      unawaited(const RequestRouter(secure: false, privateClientsOnly: true).serve(plain));

      final HttpClient client = HttpClient();
      addTearDown(client.close);
      final HttpClientRequest request = await client.getUrl(
        Uri(scheme: "http", host: "127.0.0.1", port: plain.port, path: "/health/"),
      );
      final HttpClientResponse response = await request.close();
      await body(response);

      expect(response.statusCode, 200, reason: "loopback counts as a private client");
      expect(response.headers.value("strict-transport-security"), isNull);
      expect(response.headers.value("cache-control"), "no-store");
      expect(response.headers.value("x-content-type-options"), "nosniff");
    });
  });

  group("isPrivateOrLoopbackClient", () {
    test("accepts this phone and private-network clients", () {
      for (final String ip in <String>["127.0.0.1", "10.1.2.3", "172.20.0.9", "192.168.134.20"]) {
        expect(isPrivateOrLoopbackClient(InternetAddress(ip)), isTrue, reason: ip);
      }
      expect(isPrivateOrLoopbackClient(InternetAddress("::1")), isTrue);
    });

    test("refuses public and link-local clients and non-loopback IPv6", () {
      for (final String ip in <String>["8.8.8.8", "203.0.113.7", "169.254.10.10", "172.32.0.1"]) {
        expect(isPrivateOrLoopbackClient(InternetAddress(ip)), isFalse, reason: ip);
      }
      expect(isPrivateOrLoopbackClient(InternetAddress("2001:db8::1")), isFalse);
      expect(isPrivateOrLoopbackClient(InternetAddress("fe80::1")), isFalse);
    });
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
