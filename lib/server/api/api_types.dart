/// One request, already stripped down to what the API needs. Built by
/// `RequestRouter` from the raw `HttpRequest`, so the API layer is plain Dart
/// that tests can call without opening a socket.
final class ApiRequest {
  const ApiRequest({
    required this.method,
    required this.segments,
    required this.query,
    required this.remoteAddress,
    this.bearerToken,
    this.body = const <int>[],
  });

  final String method;

  /// Path segments, percent-decoded once (`/api/v1/me` -> `[api, v1, me]`).
  final List<String> segments;

  /// Query parameters, percent-decoded once.
  final Map<String, String> query;

  /// The client's IP address (used to throttle logins).
  final String remoteAddress;

  /// The token from `Authorization: Bearer <token>`, if one was sent.
  final String? bearerToken;

  final List<int> body;
}

/// A JSON answer. [json] is `null` for an empty body (e.g. 204).
final class ApiResponse {
  const ApiResponse(this.status, {this.json, this.headers = const <String, String>{}});

  /// `{ "error": "<code>" }` — codes are stable strings, never internal detail.
  ApiResponse.error(this.status, String code, {this.headers = const <String, String>{}})
    : json = <String, Object?>{"error": code};

  final int status;
  final Object? json;
  final Map<String, String> headers;
}
