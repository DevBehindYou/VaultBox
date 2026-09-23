import "dart:async";
import "dart:io";

import "request_router.dart";

/// Plain-HTTP listener. NOT encrypted: passwords and file contents cross the
/// network in clear text, so it exists only as an explicit opt-in for a trusted
/// home network (off by default). Its router refuses clients that aren't on a
/// private network, and it is never used as a silent fallback for HTTPS.
final class HttpListener {
  HttpListener({required RequestRouter router}) : _router = router;

  final RequestRouter _router;
  HttpServer? _server;

  int? get port => _server?.port;

  Future<void> start({required bool allowNetworkAccess, required int port}) async {
    final HttpServer server = await HttpServer.bind(
      allowNetworkAccess ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
      port,
    );
    server.idleTimeout = const Duration(seconds: 30);
    _server = server;
    unawaited(_router.serve(server));
  }

  Future<void> stop() async {
    final HttpServer? server = _server;
    _server = null;
    await server?.close(force: true);
  }
}
