import "dart:async";

import "../../domain/entities/account.dart";
import "../../domain/security/session.dart";

/// One request, already stripped down to what the API needs. Built by
/// `RequestRouter` from the raw `HttpRequest`, so the API layer is plain Dart
/// that tests can call without opening a socket.
final class ApiRequest {
  /// Either [body] (a small, already-read body) or [bodyStream] (the live,
  /// unread request body — for uploads) may be given, not both.
  ApiRequest({
    required this.method,
    required this.segments,
    required this.query,
    required this.remoteAddress,
    this.bearerToken,
    this.headers = const <String, String>{},
    this.secure = true,
    List<int>? body,
    Stream<List<int>>? bodyStream,
    int? contentLength,
  }) : assert(body == null || bodyStream == null, "give a body or a stream, not both"),
       bodyStream = bodyStream ?? Stream<List<int>>.value(body ?? const <int>[]),
       contentLength = contentLength ?? (bodyStream == null ? (body?.length ?? 0) : -1);

  final String method;

  /// Path segments, percent-decoded once (`/api/v1/me` -> `[api, v1, me]`).
  final List<String> segments;

  /// Query parameters, percent-decoded once.
  final Map<String, String> query;

  /// The client's IP address (used to throttle logins).
  final String remoteAddress;

  /// Which listener this request arrived on — `RequestRouter.secure` at the
  /// time it built this request. Decides which "Storage access" set applies
  /// ([ProtocolKind.webPortalHttps] vs [ProtocolKind.plainHttp]) when a
  /// handler resolves a storage root.
  final bool secure;

  /// The token from `Authorization: Bearer <token>`, if one was sent.
  final String? bearerToken;

  /// Request headers, lower-case names (first value only).
  final Map<String, String> headers;

  /// The request body. Read it once, and only if the route needs it.
  final Stream<List<int>> bodyStream;

  /// The declared body length, or -1 when unknown (chunked).
  final int contentLength;

  String? header(String name) => headers[name.toLowerCase()];

  /// The whole body, or `null` if it is larger than [maxBytes].
  ///
  /// A body that is only a little too big is still read and thrown away, so the
  /// client gets to see the "too large" answer: closing a socket that still has
  /// unread data makes the OS reset the connection and the client would lose
  /// the reply. Anything beyond [maxDrainBytes] is not worth reading (the
  /// caller answers and hangs up).
  Future<List<int>?> readBounded(int maxBytes, {int maxDrainBytes = 256 * 1024}) async {
    if (contentLength > maxDrainBytes) return null;
    final List<int> collected = <int>[];
    int total = 0;
    bool tooBig = contentLength > maxBytes;
    await for (final List<int> chunk in bodyStream) {
      total += chunk.length;
      if (total > maxDrainBytes) return null;
      if (!tooBig) {
        collected.addAll(chunk);
        tooBig = total > maxBytes;
      }
    }
    return tooBig ? null : collected;
  }
}

/// An answer. Exactly one of [json], [bytes] or [stream] carries a body (or
/// none, for e.g. 204).
final class ApiResponse {
  const ApiResponse(
    this.status, {
    this.json,
    this.bytes,
    this.stream,
    this.contentType,
    this.contentLength,
    this.headers = const <String, String>{},
    this.closeConnection = false,
  });

  /// `{ "error": "<code>" }` — codes are stable strings, never internal detail.
  ApiResponse.error(
    this.status,
    String code, {
    this.headers = const <String, String>{},
    this.closeConnection = false,
  }) : json = <String, Object?>{"error": code},
       bytes = null,
       stream = null,
       contentType = null,
       contentLength = null;

  final int status;
  final Object? json;
  final List<int>? bytes;

  /// A streamed body (a download). Errors while it is being sent cut the connection.
  final Stream<List<int>>? stream;

  /// For [bytes] and [stream]; JSON is always `application/json`.
  final String? contentType;

  /// For [stream]: the exact number of bytes it will produce, if known.
  final int? contentLength;

  final Map<String, String> headers;

  /// Ask the router to close the connection after answering.
  final bool closeConnection;
}

/// Who is asking: a valid session and the account behind it.
final class ApiCaller {
  const ApiCaller({required this.session, required this.account});

  final Session session;
  final Account account;
}

/// Thrown inside an endpoint to stop and answer right away.
final class ApiReject implements Exception {
  const ApiReject(this.response);

  final ApiResponse response;
}
