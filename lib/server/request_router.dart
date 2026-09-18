import "dart:async";
import "dart:convert";
import "dart:io";

/// Routes and answers HTTP requests. Transport-agnostic (no TLS here) so it can
/// be exercised over plain loopback sockets in tests; `HttpsListener` supplies
/// the TLS.
///
/// Rules every response follows:
///  - JSON only, no HTML, no stack traces or internal detail ever leave here;
///  - `no-store` + `nosniff` + a `default-src 'none'` CSP;
///  - an unexpected error becomes a bare 500.
final class RequestRouter {
  /// Accepts connections from [server] until it is closed.
  Future<void> serve(HttpServer server) async {
    await for (final HttpRequest request in server) {
      unawaited(handle(request));
    }
  }

  Future<void> handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    _applySecurityHeaders(response);
    try {
      final String path = request.uri.path;
      if (path == "/health/" || path == "/health") {
        if (request.method == "GET") {
          _json(response, HttpStatus.ok, <String, Object?>{"status": "ok", "app": "vaultbox"});
        } else {
          response.headers.set(HttpHeaders.allowHeader, "GET");
          _json(response, HttpStatus.methodNotAllowed, <String, Object?>{"error": "method_not_allowed"});
        }
      } else {
        _json(response, HttpStatus.notFound, <String, Object?>{"error": "not_found"});
      }
    } on Object {
      // Never leak internals to a client.
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      await response.close();
    }
  }

  void _applySecurityHeaders(HttpResponse response) {
    response.headers
      ..set(HttpHeaders.cacheControlHeader, "no-store")
      ..set("X-Content-Type-Options", "nosniff")
      ..set("Content-Security-Policy", "default-src 'none'")
      ..set("Referrer-Policy", "no-referrer")
      ..set("Strict-Transport-Security", "max-age=31536000");
  }

  void _json(HttpResponse response, int status, Map<String, Object?> body) {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
  }
}
