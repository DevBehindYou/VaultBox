import "dart:convert";
import "dart:io";

import "../../core/errors/app_failure.dart";
import "../../domain/entities/account.dart";
import "../../domain/entities/storage_root.dart";
import "../../domain/models/file_ref.dart";
import "../../domain/repositories/account_repository.dart";
import "../../domain/repositories/file_repository.dart";
import "../../domain/repositories/storage_root_repository.dart";
import "../../domain/security/login_service.dart";
import "../../domain/security/session.dart";
import "../../domain/security/session_manager.dart";
import "../../domain/value_objects/storage_entry.dart";
import "../../domain/value_objects/storage_path.dart";
import "api_types.dart";

/// The remote API, version 1. Everything except `POST /auth/login` needs a
/// valid `Authorization: Bearer <token>`.
///
///   POST /api/v1/auth/login                   {username, password} -> token
///   POST /api/v1/auth/logout                  revokes the token
///   GET  /api/v1/me                           who am I
///   GET  /api/v1/roots                        storage locations (never their raw path/URI)
///   GET  /api/v1/roots/{id}/entries?path=/&limit=200&cursor=<name>
///
/// Failures are `{ "error": "<stable_code>" }` with a matching status; nothing
/// about the phone's internals (paths, exceptions, stack traces) leaves here.
final class VaultApi {
  VaultApi({
    required LoginService login,
    required SessionManager sessions,
    required AccountRepository accounts,
    required StorageRootRepository roots,
    required FileRepository files,
  }) : _login = login,
       _sessions = sessions,
       _accounts = accounts,
       _roots = roots,
       _files = files;

  final LoginService _login;
  final SessionManager _sessions;
  final AccountRepository _accounts;
  final StorageRootRepository _roots;
  final FileRepository _files;

  static const int defaultPageSize = 200;
  static const int maxPageSize = 500;

  /// VaultBox's own bookkeeping folder (Recycle Bin). Never listed or reachable.
  static const String _reservedDirName = ".vaultbox";

  Future<ApiResponse> handle(ApiRequest request) async {
    // segments[0] == "api", segments[1] == "v1" (the router guarantees the prefix).
    final List<String> route = request.segments.length < 3
        ? const <String>[]
        : request.segments.sublist(2);

    if (route.length == 2 && route[0] == "auth" && route[1] == "login") {
      return _only("POST", request, _handleLogin);
    }

    // Everything else needs a session.
    final _Caller? caller = await _authenticate(request);
    if (route.isEmpty || !_isKnown(route)) {
      // Don't reveal the API's shape to someone who isn't logged in.
      return caller == null ? _unauthorized() : ApiResponse.error(HttpStatus.notFound, "not_found");
    }
    if (caller == null) return _unauthorized();

    if (route.length == 2 && route[0] == "auth" && route[1] == "logout") {
      return _only("POST", request, (ApiRequest r) => _handleLogout(r, caller));
    }
    if (route.length == 1 && route[0] == "me") {
      return _only("GET", request, (ApiRequest r) => _handleMe(caller));
    }
    if (route.length == 1 && route[0] == "roots") {
      return _only("GET", request, (ApiRequest r) => _handleRoots());
    }
    // route is roots/{id}/entries
    return _only("GET", request, (ApiRequest r) => _handleEntries(r, route[1]));
  }

  bool _isKnown(List<String> route) {
    return (route.length == 2 && route[0] == "auth" && route[1] == "logout") ||
        (route.length == 1 && (route[0] == "me" || route[0] == "roots")) ||
        (route.length == 3 && route[0] == "roots" && route[2] == "entries");
  }

  Future<ApiResponse> _only(
    String method,
    ApiRequest request,
    Future<ApiResponse> Function(ApiRequest) handler,
  ) {
    if (request.method != method) {
      return Future<ApiResponse>.value(
        ApiResponse.error(
          HttpStatus.methodNotAllowed,
          "method_not_allowed",
          headers: <String, String>{HttpHeaders.allowHeader: method},
        ),
      );
    }
    return handler(request);
  }

  // --- auth ---

  Future<ApiResponse> _handleLogin(ApiRequest request) async {
    final Object? decoded = _decodeJson(request.body);
    if (decoded is! Map<String, Object?>) return ApiResponse.error(HttpStatus.badRequest, "bad_request");
    final Object? username = decoded["username"];
    final Object? password = decoded["password"];
    if (username is! String || password is! String) {
      return ApiResponse.error(HttpStatus.badRequest, "bad_request");
    }

    final LoginOutcome outcome = await _login.login(
      username: username,
      password: password,
      remoteAddress: request.remoteAddress,
    );
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

  Future<ApiResponse> _handleLogout(ApiRequest request, _Caller caller) async {
    await _sessions.revoke(request.bearerToken!);
    return const ApiResponse(HttpStatus.noContent);
  }

  Future<ApiResponse> _handleMe(_Caller caller) async {
    return ApiResponse(HttpStatus.ok, json: _user(caller.account));
  }

  // --- storage ---

  Future<ApiResponse> _handleRoots() async {
    final List<StorageRoot> roots = await _roots.listRoots();
    return ApiResponse(
      HttpStatus.ok,
      json: <String, Object?>{
        "roots": <Object?>[
          for (final StorageRoot root in roots)
            if (root.isEnabled)
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

  Future<ApiResponse> _handleEntries(ApiRequest request, String rootId) async {
    final StorageRoot? root = await _roots.getRoot(rootId);
    if (root == null || !root.isEnabled) return ApiResponse.error(HttpStatus.notFound, "root_not_found");
    if (!root.isAvailable) return ApiResponse.error(HttpStatus.serviceUnavailable, "storage_unavailable");

    final int? limit = _parseLimit(request.query["limit"]);
    if (limit == null) return ApiResponse.error(HttpStatus.badRequest, "bad_request");
    final String? rawCursor = request.query["cursor"];
    final String? cursor = (rawCursor == null || rawCursor.isEmpty) ? null : rawCursor;

    final StoragePath path;
    try {
      path = StoragePath.parse(root.id, request.query["path"] ?? "/");
    } on AppFailure {
      return ApiResponse.error(HttpStatus.badRequest, "invalid_path");
    }
    if (path.segments.isNotEmpty && path.segments.first == _reservedDirName) {
      return ApiResponse.error(HttpStatus.notFound, "not_found");
    }

    try {
      final FileRef directory = FileRef(root: root, path: path);
      if (!path.isRoot) {
        final StorageEntry? stat = await _files.statEntry(directory);
        if (stat == null) return ApiResponse.error(HttpStatus.notFound, "not_found");
        if (!stat.isDirectory) return ApiResponse.error(HttpStatus.badRequest, "not_a_directory");
      }

      final List<StorageEntry> page = await _files
          .list(directory, cursor: cursor, pageSize: limit)
          .toList();

      // The cursor follows the RAW page so hiding an entry can't stall paging.
      final bool hasMore = page.length == limit;
      final String? next = hasMore ? page.last.name : null;

      return ApiResponse(
        HttpStatus.ok,
        json: <String, Object?>{
          "path": "/${path.segments.join("/")}",
          "entries": <Object?>[
            for (final StorageEntry entry in page)
              if (!(path.isRoot && entry.name == _reservedDirName)) _entry(entry),
          ],
          "nextCursor": next,
        },
      );
    } on PermissionRevokedFailure {
      return ApiResponse.error(HttpStatus.conflict, "storage_permission_revoked");
    } on StorageDisconnectedFailure {
      return ApiResponse.error(HttpStatus.serviceUnavailable, "storage_unavailable");
    } on PathTraversalRejectedFailure {
      return ApiResponse.error(HttpStatus.badRequest, "invalid_path");
    }
  }

  // --- helpers ---

  Future<_Caller?> _authenticate(ApiRequest request) async {
    final String? token = request.bearerToken;
    if (token == null) return null;
    final Session? session = await _sessions.validate(token);
    if (session == null) return null;
    final Account? account = await _accounts.findById(session.accountId);
    if (account == null) {
      await _sessions.revoke(token);
      return null;
    }
    return _Caller(session: session, account: account);
  }

  ApiResponse _unauthorized() => ApiResponse.error(
    HttpStatus.unauthorized,
    "unauthorized",
    headers: const <String, String>{HttpHeaders.wwwAuthenticateHeader: "Bearer"},
  );

  static Object? _decodeJson(List<int> body) {
    try {
      return jsonDecode(utf8.decode(body));
    } on FormatException {
      return null;
    }
  }

  static int? _parseLimit(String? raw) {
    if (raw == null) return defaultPageSize;
    final int? parsed = int.tryParse(raw);
    if (parsed == null || parsed < 1 || parsed > maxPageSize) return null;
    return parsed;
  }

  static int _seconds(Duration duration) => (duration.inMilliseconds / 1000).ceil();

  static Map<String, Object?> _user(Account account) => <String, Object?>{
    "id": account.id,
    "username": account.username,
  };

  static Map<String, Object?> _entry(StorageEntry entry) => <String, Object?>{
    "name": entry.name,
    "type": entry.isDirectory ? "directory" : "file",
    "size": entry.sizeBytes,
    "modified": entry.modifiedAt?.toUtc().toIso8601String(),
    "mime": entry.mimeType,
  };
}

final class _Caller {
  const _Caller({required this.session, required this.account});

  final Session session;
  final Account account;
}
