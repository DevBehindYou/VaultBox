import "dart:async";
import "dart:convert";
import "dart:io";

import "api/api_types.dart";
import "api/vault_api.dart";
import "network_addresses.dart";
import "portal/portal_assets.dart";

/// Routes and answers HTTP requests. Transport-agnostic so it can be exercised
/// over plain loopback sockets in tests; `HttpsListener` / `HttpListener`
/// supply the transport.
///
/// Rules every response follows:
///  - JSON only, no HTML, no stack traces or internal detail ever leave here;
///  - `no-store` + `nosniff` + a `default-src 'none'` CSP;
///  - an unexpected error becomes a bare 500.
final class RequestRouter {
  /// [secure]: this router sits behind TLS (only then is HSTS meaningful).
  /// [privateClientsOnly]: refuse any client that isn't this phone or on a
  /// private network — used for the unencrypted HTTP listener.
  /// [api]: the `/api/v1/*` handlers; without it only `/health/` exists.
  /// [portal]: the browser page served at `/`; without it `/` is a plain 404.
  const RequestRouter({
    this.secure = true,
    this.privateClientsOnly = false,
    this.api,
    this.portal,
  });

  final bool secure;
  final bool privateClientsOnly;
  final VaultApi? api;
  final PortalAssets? portal;

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
      if (privateClientsOnly) {
        final InternetAddress? client = request.connectionInfo?.remoteAddress;
        if (client == null || !isPrivateOrLoopbackClient(client)) {
          _json(response, HttpStatus.forbidden, <String, Object?>{"error": "forbidden"});
          return;
        }
      }

      final String path = request.uri.path;
      if (path == "/health/" || path == "/health") {
        if (request.method == "GET") {
          _json(response, HttpStatus.ok, <String, Object?>{"status": "ok", "app": "vaultbox"});
        } else {
          response.headers.set(HttpHeaders.allowHeader, "GET");
          _json(response, HttpStatus.methodNotAllowed, <String, Object?>{"error": "method_not_allowed"});
        }
      } else if (api != null && (path == "/api/v1" || path.startsWith("/api/v1/") || path.startsWith("/d/"))) {
        await _handleApi(request, response);
      } else if (portal?.lookup(path) case final PortalAsset asset) {
        if (request.method == "GET" || request.method == "HEAD") {
          await _write(
            request,
            response,
            ApiResponse(
              HttpStatus.ok,
              bytes: asset.bytes,
              contentType: asset.contentType,
              headers: const <String, String>{"Content-Security-Policy": PortalAssets.contentSecurityPolicy},
            ),
          );
        } else {
          response.headers.set(HttpHeaders.allowHeader, "GET, HEAD");
          _json(response, HttpStatus.methodNotAllowed, <String, Object?>{"error": "method_not_allowed"});
        }
      } else {
        _json(response, HttpStatus.notFound, <String, Object?>{"error": "not_found"});
      }
    } on Object {
      // Never leak internals to a client.
      try {
        response.statusCode = HttpStatus.internalServerError;
      } on StateError {
        // The reply is already under way (a download that broke half-way): the
        // only honest thing left is to cut the connection.
        try {
          (await response.detachSocket(writeHeaders: false)).destroy();
        } on Object {
          // Already gone.
        }
      }
    } finally {
      try {
        await response.close();
      } on Object {
        // The connection is gone; nothing left to tell the client.
      }
    }
  }

  Future<void> _handleApi(HttpRequest request, HttpResponse response) async {
    final Map<String, String> headers = <String, String>{};
    request.headers.forEach((String name, List<String> values) {
      if (values.isNotEmpty) headers[name.toLowerCase()] = values.first;
    });

    final ApiResponse result = await api!.handle(
      ApiRequest(
        method: request.method,
        segments: request.uri.pathSegments.where((String s) => s.isNotEmpty).toList(),
        query: request.uri.queryParameters,
        remoteAddress: request.connectionInfo?.remoteAddress.address ?? "unknown",
        bearerToken: _bearerToken(request),
        headers: headers,
        // HttpRequest is a Stream<Uint8List>; cast so later .transform() calls type-check at runtime.
        bodyStream: request.cast<List<int>>(),
        contentLength: request.contentLength,
      ),
    );
    await _write(request, response, result);
  }

  Future<void> _write(HttpRequest request, HttpResponse response, ApiResponse result) async {
    response.statusCode = result.status;
    result.headers.forEach(response.headers.set);
    if (result.closeConnection) response.persistentConnection = false;

    final Object? json = result.json;
    final List<int>? bytes = result.bytes;
    final Stream<List<int>>? stream = result.stream;
    if (json != null) {
      response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(json));
    } else if (bytes != null) {
      _setContentType(response, result.contentType);
      response
        ..contentLength = bytes.length
        ..add(bytes);
    } else if (stream != null) {
      _setContentType(response, result.contentType);
      final int? length = result.contentLength;
      if (length != null) response.contentLength = length;
      await response.addStream(stream);
    }
  }

  static void _setContentType(HttpResponse response, String? contentType) {
    response.headers.set(HttpHeaders.contentTypeHeader, contentType ?? "application/octet-stream");
  }

  static String? _bearerToken(HttpRequest request) {
    final String? header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null) return null;
    const String prefix = "Bearer ";
    if (header.length <= prefix.length || header.substring(0, prefix.length).toLowerCase() != "bearer ") {
      return null;
    }
    final String token = header.substring(prefix.length).trim();
    return token.isEmpty ? null : token;
  }

  void _applySecurityHeaders(HttpResponse response) {
    response.headers
      ..set(HttpHeaders.cacheControlHeader, "no-store")
      ..set("X-Content-Type-Options", "nosniff")
      ..set("Content-Security-Policy", "default-src 'none'")
      ..set("Referrer-Policy", "no-referrer")
      ..set("X-Frame-Options", "DENY")
      ..set("Cross-Origin-Resource-Policy", "same-origin");
    if (secure) {
      response.headers.set("Strict-Transport-Security", "max-age=31536000");
    }
  }

  void _json(HttpResponse response, int status, Map<String, Object?> body) {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
  }
}
