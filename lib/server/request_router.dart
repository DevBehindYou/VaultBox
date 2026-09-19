import "dart:async";
import "dart:convert";
import "dart:io";

import "api/api_types.dart";
import "api/vault_api.dart";
import "network_addresses.dart";

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
  const RequestRouter({this.secure = true, this.privateClientsOnly = false, this.api});

  final bool secure;
  final bool privateClientsOnly;
  final VaultApi? api;

  /// Request bodies are tiny JSON documents (a login); anything bigger is refused.
  static const int maxBodyBytes = 16 * 1024;

  /// How much of an oversized body is read and discarded before hanging up.
  static const int maxDrainBytes = 256 * 1024;

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
      } else if (api != null && (path == "/api/v1" || path.startsWith("/api/v1/"))) {
        await _handleApi(request, response);
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

  Future<void> _handleApi(HttpRequest request, HttpResponse response) async {
    List<int> body = const <int>[];
    if (request.method == "POST" || request.method == "PUT" || request.method == "PATCH") {
      final List<int>? read = await _readBody(request);
      if (read == null) {
        // Refuse and hang up rather than read on: the rest of an oversized body is never wanted.
        response.persistentConnection = false;
        _json(response, HttpStatus.requestEntityTooLarge, <String, Object?>{"error": "payload_too_large"});
        return;
      }
      body = read;
    }

    final ApiResponse result = await api!.handle(
      ApiRequest(
        method: request.method,
        segments: request.uri.pathSegments.where((String s) => s.isNotEmpty).toList(),
        query: request.uri.queryParameters,
        remoteAddress: request.connectionInfo?.remoteAddress.address ?? "unknown",
        bearerToken: _bearerToken(request),
        body: body,
      ),
    );

    response.statusCode = result.status;
    result.headers.forEach(response.headers.set);
    final Object? json = result.json;
    if (json != null) {
      response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(json));
    }
  }

  /// The whole body, or `null` if it is larger than [maxBodyBytes].
  ///
  /// A body that is only a little too big is still read and thrown away, so the
  /// client gets to see the 413: closing a socket that still has unread data
  /// makes the OS reset the connection, and the client would lose the answer.
  /// Anything bigger than [maxDrainBytes] is not worth reading — the caller
  /// hangs up on it.
  Future<List<int>?> _readBody(HttpRequest request) async {
    if (request.contentLength > maxDrainBytes) return null;
    final BytesBuilder builder = BytesBuilder(copy: false);
    int total = 0;
    bool tooBig = request.contentLength > maxBodyBytes;
    await for (final List<int> chunk in request) {
      total += chunk.length;
      if (total > maxDrainBytes) return null;
      if (!tooBig) {
        builder.add(chunk);
        tooBig = total > maxBodyBytes;
      }
    }
    return tooBig ? null : builder.takeBytes();
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
      ..set("Referrer-Policy", "no-referrer");
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
