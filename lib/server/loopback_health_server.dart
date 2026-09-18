import "dart:async";
import "dart:convert";
import "dart:io";

/// Phase 2 stand-in for the real server: an HTTP listener bound to **loopback
/// only** that answers `GET /health/`. It proves the whole pipeline (service ->
/// headless Dart engine -> a live socket -> state back to the UI) without
/// exposing anything to the network before TLS and authentication exist
/// (Phase 3). Binding is 127.0.0.1 on purpose — do not widen it here.
final class LoopbackHealthServer {
  HttpServer? _server;

  /// The address the server answers on, or null when stopped.
  Uri? get endpoint {
    final HttpServer? server = _server;
    if (server == null) return null;
    return Uri(scheme: "http", host: "127.0.0.1", port: server.port, path: "/health/");
  }

  /// Starts listening. [port] 0 picks a free port.
  Future<Uri> start({int port = 0}) async {
    final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    unawaited(_serve(server));
    return endpoint!;
  }

  Future<void> _serve(HttpServer server) async {
    await for (final HttpRequest request in server) {
      try {
        final String path = request.uri.path;
        if (request.method == "GET" && (path == "/health/" || path == "/health")) {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(<String, String>{"status": "ok", "app": "vaultbox"}));
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
      } finally {
        await request.response.close();
      }
    }
  }

  Future<void> stop() async {
    final HttpServer? server = _server;
    _server = null;
    await server?.close(force: true);
  }
}
