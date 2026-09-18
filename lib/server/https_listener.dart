import "dart:async";
import "dart:convert";
import "dart:io";

import "request_router.dart";

/// TLS listener for the server.
///
/// Binds to loopback unless network access was explicitly enabled. There is
/// deliberately NO plain-HTTP fallback: if the certificate can't be loaded the
/// server fails to start instead of downgrading (no silent downgrade).
final class HttpsListener {
  HttpsListener({required RequestRouter router}) : _router = router;

  final RequestRouter _router;
  HttpServer? _server;

  /// The bound port once started (useful when [start] was given port 0).
  int? get port => _server?.port;

  Future<void> start({
    required String certificatePem,
    required String privateKeyPem,
    required bool allowNetworkAccess,
    required int port,
  }) async {
    final SecurityContext context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(certificatePem))
      ..usePrivateKeyBytes(utf8.encode(privateKeyPem));

    final HttpServer server = await HttpServer.bindSecure(
      allowNetworkAccess ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
      port,
      context,
    );
    // Drop connections that go quiet, so idle sockets can't pile up.
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
