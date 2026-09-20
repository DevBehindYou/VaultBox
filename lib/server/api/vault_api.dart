import "dart:io";

import "../../domain/entities/account.dart";
import "../../domain/entities/activity.dart";
import "../../domain/entities/storage_root.dart";
import "../../domain/repositories/account_repository.dart";
import "../../domain/security/authorizer.dart";
import "../../domain/security/login_service.dart";
import "../../domain/security/session.dart";
import "../../domain/security/session_manager.dart";
import "../../domain/value_objects/storage_path.dart";
import "../activity/activity_log.dart";
import "../files/storage_gate.dart";
import "api_json.dart";
import "api_types.dart";
import "file_endpoints.dart";
import "public_endpoints.dart";

/// The remote API, version 1. Everything except `POST /auth/login` needs a
/// valid `Authorization: Bearer <token>`.
///
///   POST /api/v1/auth/login                    {username, password} -> token
///   POST /api/v1/auth/logout                   revokes the token
///   GET  /api/v1/me                            who am I
///   GET  /api/v1/roots                         storage locations you may see (never their raw path/URI)
///   GET  /api/v1/roots/{id}/entries            list a folder (paged)
///   GET  /api/v1/roots/{id}/stat               one item's details
///   GET|HEAD|PUT /api/v1/roots/{id}/content    download (Range) / upload
///   POST /api/v1/roots/{id}/ticket             a short-lived `/d/<ticket>` link for one file
///   POST /api/v1/roots/{id}/{mkdir|rename|move|copy|delete}
///   ...  /api/v1/public/{token}/...            share links (no login; see [PublicEndpoints])
///
/// Failures are `{ "error": "<stable_code>" }` with a matching status; nothing
/// about the phone's internals (paths, exceptions, stack traces) leaves here.
final class VaultApi {
  VaultApi({
    required LoginService login,
    required SessionManager sessions,
    required AccountRepository accounts,
    required StorageGate gate,
    required FileEndpoints files,
    PublicEndpoints? public,
    ActivityLog? activity,
  }) : _login = login,
       _sessions = sessions,
       _accounts = accounts,
       _gate = gate,
       _files = files,
       _public = public,
       _activity = activity ?? ActivityLog.none();

  final LoginService _login;
  final SessionManager _sessions;
  final AccountRepository _accounts;
  final StorageGate _gate;
  final FileEndpoints _files;
  final PublicEndpoints? _public;
  final ActivityLog _activity;

  Future<ApiResponse> handle(ApiRequest request) async {
    try {
      return await _dispatch(request);
    } on ApiReject catch (reject) {
      return reject.response;
    }
  }

  Future<ApiResponse> _dispatch(ApiRequest request) async {
    // Ticket links: /d/<ticket> — the ticket itself is the credential.
    if (request.segments.isNotEmpty && request.segments.first == "d") {
      return request.segments.length == 2
          ? _files.downloadByTicket(request, request.segments[1])
          : ApiResponse.error(HttpStatus.notFound, "not_found");
    }

    // segments[0] == "api", segments[1] == "v1" (the router guarantees the prefix).
    final List<String> route = request.segments.length < 3
        ? const <String>[]
        : request.segments.sublist(2);

    if (route.length == 2 && route[0] == "auth" && route[1] == "login") {
      return _only("POST", request, () => _handleLogin(request));
    }

    // Links made for people without an account; each carries its own secret token.
    if (route.isNotEmpty && route[0] == "public") {
      final PublicEndpoints? public = _public;
      return public == null || route.length < 2
          ? ApiResponse.error(HttpStatus.notFound, "not_found")
          : public.handle(request, route.sublist(1));
    }

    // Everything else needs a session.
    final ApiCaller? caller = await _authenticate(request);
    if (route.isEmpty || !_isKnown(route)) {
      // Don't reveal the API's shape to someone who isn't logged in.
      return caller == null ? _unauthorized() : ApiResponse.error(HttpStatus.notFound, "not_found");
    }
    if (caller == null) return _unauthorized();

    if (route.length == 2 && route[0] == "auth") {
      return _only("POST", request, () => _handleLogout(request, caller));
    }
    if (route.length == 1 && route[0] == "me") {
      return _only("GET", request, () async => ApiResponse(HttpStatus.ok, json: _user(caller.account)));
    }
    if (route.length == 1 && route[0] == "roots") {
      return _only("GET", request, () => _handleRoots(caller));
    }
    // roots/{id}/{action}
    return _files.handle(request, caller, route[1], route[2]);
  }

  bool _isKnown(List<String> route) {
    return (route.length == 2 && route[0] == "auth" && route[1] == "logout") ||
        (route.length == 1 && (route[0] == "me" || route[0] == "roots")) ||
        (route.length == 3 && route[0] == "roots" && FileEndpoints.actions.contains(route[2]));
  }

  Future<ApiResponse> _only(String method, ApiRequest request, Future<ApiResponse> Function() run) {
    if (request.method != method) {
      return Future<ApiResponse>.value(
        ApiResponse.error(
          HttpStatus.methodNotAllowed,
          "method_not_allowed",
          headers: <String, String>{HttpHeaders.allowHeader: method},
        ),
      );
    }
    return run();
  }

  // --- auth ---

  Future<ApiResponse> _handleLogin(ApiRequest request) async {
    final Map<String, Object?> body = await readJsonObject(request);
    final Object? username = body["username"];
    final Object? password = body["password"];
    if (username is! String || password is! String) {
      return ApiResponse.error(HttpStatus.badRequest, "bad_request");
    }

    final LoginOutcome outcome = await _login.login(
      username: username,
      password: password,
      remoteAddress: request.remoteAddress,
    );
    switch (outcome) {
      case LoginSucceeded(:final Account account):
        _activity.event(
          ActivityKind.signedIn,
          "${account.username} signed in.",
          actor: account.username,
          address: request.remoteAddress,
        );
        _activity.seen(actor: account.username, address: request.remoteAddress, via: AccessVia.web);
      case LoginRejected():
        // The name that was typed is deliberately not recorded: it may be a password.
        _activity.event(
          ActivityKind.signInRefused,
          "A sign-in was refused: wrong name or password.",
          severity: ActivitySeverity.warning,
          address: request.remoteAddress,
          throttleKey: "refused|${request.remoteAddress}",
          throttleFor: const Duration(seconds: 10),
        );
      case LoginThrottled():
        _activity.event(
          ActivityKind.signInRefused,
          "Too many failed sign-ins: further attempts from this address are being delayed.",
          severity: ActivitySeverity.warning,
          address: request.remoteAddress,
          throttleKey: "locked|${request.remoteAddress}",
          throttleFor: const Duration(minutes: 5),
        );
      case LoginBusy():
        break;
    }
    return switch (outcome) {
      LoginSucceeded(:final IssuedSession issued, :final Account account) => ApiResponse(
        HttpStatus.ok,
        json: <String, Object?>{
          "token": issued.token,
          "tokenType": "Bearer",
          "idleTimeoutSeconds": _sessions.idleTimeout.inSeconds,
          "maxLifetimeSeconds": _sessions.absoluteTimeout.inSeconds,
          "user": _user(account),
        },
      ),
      LoginRejected() => ApiResponse.error(HttpStatus.unauthorized, "invalid_credentials"),
      LoginThrottled(:final Duration retryAfter) => ApiResponse.error(
        HttpStatus.tooManyRequests,
        "too_many_attempts",
        headers: <String, String>{"Retry-After": _seconds(retryAfter).toString()},
      ),
      LoginBusy() => ApiResponse.error(
        HttpStatus.serviceUnavailable,
        "busy",
        headers: const <String, String>{"Retry-After": "2"},
      ),
    };
  }

  Future<ApiResponse> _handleLogout(ApiRequest request, ApiCaller caller) async {
    await _sessions.revoke(request.bearerToken!);
    _files.revokeTickets(caller.session.tokenHash);
    _activity.event(
      ActivityKind.signedOut,
      "${caller.account.username} signed out.",
      actor: caller.account.username,
      address: request.remoteAddress,
    );
    return const ApiResponse(HttpStatus.noContent);
  }

  // --- storage ---

  Future<ApiResponse> _handleRoots(ApiCaller caller) async {
    final List<StorageRoot> roots = await _gate.visibleRoots();
    return ApiResponse(
      HttpStatus.ok,
      json: <String, Object?>{
        "roots": <Object?>[
          for (final StorageRoot root in roots)
            if (_gate.allows(caller.account, Permission.read, root, StoragePath.root(root.id)))
              <String, Object?>{
                "id": root.id,
                "name": root.displayName,
                "available": root.isAvailable,
                "writable": root.capabilities.canWrite,
                "isDefault": root.isDefault,
                "freeBytes": root.freeBytes,
                "totalBytes": root.totalBytes,
              },
        ],
      },
    );
  }

  // --- helpers ---

  Future<ApiCaller?> _authenticate(ApiRequest request) async {
    final String? token = request.bearerToken;
    if (token == null) return null;
    final Session? session = await _sessions.validate(token);
    if (session == null) return null;
    final Account? account = await _accounts.findById(session.accountId);
    // Gone, disabled, or its password changed since this session began: the
    // session is over (this is how a change made in the app reaches the server).
    if (account == null || !account.isEnabled || account.credentialVersion != session.credentialVersion) {
      await _sessions.revoke(token);
      return null;
    }
    _activity.seen(actor: account.username, address: request.remoteAddress, via: AccessVia.web);
    return ApiCaller(session: session, account: account);
  }

  ApiResponse _unauthorized() => ApiResponse.error(
    HttpStatus.unauthorized,
    "unauthorized",
    headers: const <String, String>{HttpHeaders.wwwAuthenticateHeader: "Bearer"},
  );

  static int _seconds(Duration duration) => (duration.inMilliseconds / 1000).ceil();

  static Map<String, Object?> _user(Account account) => <String, Object?>{
    "id": account.id,
    "username": account.username,
    "role": account.role.name,
  };
}
