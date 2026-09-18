import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/server/loopback_health_server.dart";

/// Real sockets on loopback (plain `test`, real event loop).
void main() {
  late LoopbackHealthServer server;

  setUp(() => server = LoopbackHealthServer());
  tearDown(() => server.stop());

  Future<(int, String)> get(Uri uri) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientResponse response = await (await client.getUrl(uri)).close();
      return (response.statusCode, await utf8.decoder.bind(response).join());
    } finally {
      client.close(force: true);
    }
  }

  test("no endpoint before start", () {
    expect(server.endpoint, isNull);
  });

  test("answers GET /health/ with ok JSON", () async {
    final Uri endpoint = await server.start();
    final (int status, String body) = await get(endpoint);

    expect(status, 200);
    expect(jsonDecode(body), <String, Object?>{"status": "ok", "app": "vaultbox"});
  });

  test("endpoint is loopback only", () async {
    final Uri endpoint = await server.start();
    expect(endpoint.host, "127.0.0.1");
    expect(endpoint.port, greaterThan(0));
    expect(server.endpoint, endpoint);
  });

  test("unknown paths are 404", () async {
    final Uri endpoint = await server.start();
    final (int status, String _) = await get(endpoint.replace(path: "/secrets/"));
    expect(status, 404);
  });

  test("stop closes the listener", () async {
    final Uri endpoint = await server.start();
    await server.stop();

    expect(server.endpoint, isNull);
    await expectLater(get(endpoint), throwsA(isA<SocketException>()));
  });
}
