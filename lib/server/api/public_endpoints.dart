import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:math";

import "package:crypto/crypto.dart";

import "../../core/errors/app_failure.dart";
import "../../core/utils/mime_types.dart";
import "../../domain/entities/account.dart";
import "../../domain/entities/activity.dart";
import "../../domain/entities/share.dart";
import "../../domain/entities/storage_root.dart";
import "../../domain/models/file_ref.dart";
import "../../domain/repositories/account_repository.dart";
import "../../domain/repositories/clock.dart";
import "../../domain/repositories/file_repository.dart";
import "../../domain/repositories/share_repository.dart";
import "../../domain/security/login_throttle.dart";
import "../../domain/security/password_hasher.dart";
import "../../domain/security/permission.dart";
import "../../domain/security/share_tokens.dart";
import "../../domain/value_objects/storage_entry.dart";
import "../../domain/value_objects/storage_path.dart";
import "../activity/activity_log.dart";
import "../files/content_disposition.dart";
import "../files/file_transfer.dart";
import "../files/storage_gate.dart";
import "api_json.dart";
import "api_types.dart";

/// Proof that someone typed a share's password. In memory, bounded, short-lived;
/// the proof itself is a random 256-bit value (only its hash is kept here).
final class ShareUnlocks {
  ShareUnlocks({
    required Clock clock,
    this.lifetime = const Duration(minutes: 30),
    this.maxEntries = 2000,
    Random? random,
  }) : _clock = clock,
       _random = random ?? Random.secure();

  final Clock _clock;
  final Random _random;
  final Duration lifetime;
  final int maxEntries;

  /// Insertion-ordered so the oldest goes first when full.
  final Map<String, _Unlock> _unlocks = <String, _Unlock>{};

  String issue(String shareId) {
    final String token = ShareTokens.generate(_random);
    _unlocks[_hash(token)] = _Unlock(shareId, _clock.now().add(lifetime));
    if (_unlocks.length > maxEntries) _unlocks.remove(_unlocks.keys.first);
    return token;
  }

  bool isValid(String shareId, String? token) {
    if (token == null || token.isEmpty || token.length > 128) return false;
    final String key = _hash(token);
    final _Unlock? unlock = _unlocks[key];
    if (unlock == null) return false;
    if (!_clock.now().isBefore(unlock.expiresAt)) {
      _unlocks.remove(key);
      return false;
    }
    return unlock.shareId == shareId;
  }

  void purgeExpired() {
    final DateTime now = _clock.now();
    _unlocks.removeWhere((String _, _Unlock u) => !now.isBefore(u.expiresAt));
  }

  static String _hash(String token) => sha256.convert(utf8.encode(token)).toString();
}

final class _Unlock {
  const _Unlock(this.shareId, this.expiresAt);

  final String shareId;
  final DateTime expiresAt;
}

/// `/api/v1/public/{token}/…` — share links for people without an account.
///
///   GET  /public/{token}                 what the link is (no secrets)
///   POST /public/{token}/unlock          {password} -> proof, for a password-protected link
///   GET  /public/{token}/entries         list a shared FOLDER (path relative to it)
///   GET|HEAD /public/{token}/content     download (a shared file, or a file in a shared folder)
///   PUT  /public/{token}/content?name=   upload-request links: send a file in
///
/// The token is the only credential, so it is 256 bits and looked up by hash.
/// Every request re-checks that the link is live and that the account that made
/// it may still do what it does. A password-protected link needs the `unlock`
/// proof (query `unlock=` or header `X-Share-Unlock`). Unknown tokens, wrong
/// passwords and busy password checks are all throttled.
final class PublicEndpoints {
  PublicEndpoints({
    required ShareRepository shares,
    required AccountRepository accounts,
    required StorageGate gate,
    required FileRepository files,
    required PasswordHasher hasher,
    required Clock clock,
    required ShareUnlocks unlocks,
    LoginThrottle? unlockThrottle,
    LoginThrottle? probeThrottle,
    ActivityLog? activity,
  }) : _activity = activity ?? ActivityLog.none(),
       _shares = shares,
       _accounts = accounts,
       _gate = gate,
       _files = files,
       _transfer = FileTransfer(files),
       _hasher = hasher,
       _clock = clock,
       _unlocks = unlocks,
       _unlockThrottle = unlockThrottle ?? LoginThrottle(clock: clock),
       _probeThrottle =
           probeThrottle ??
           LoginThrottle(clock: clock, freeAttempts: 30, baseLock: const Duration(minutes: 1));

  final ShareRepository _shares;
  final AccountRepository _accounts;
  final StorageGate _gate;
  final FileRepository _files;
  final FileTransfer _transfer;
  final PasswordHasher _hasher;
  final Clock _clock;
  final ShareUnlocks _unlocks;
  final ActivityLog _activity;

  /// Wrong passwords, keyed by link + address.
  final LoginThrottle _unlockThrottle;

  /// Guessed tokens, keyed by address.
  final LoginThrottle _probeThrottle;

  int _passwordChecks = 0;
  static const int maxConcurrentPasswordChecks = 2;
  static const int defaultPageSize = 200;
  static const int maxPageSize = 500;
  static const int maxNameLength = 255;

  Future<ApiResponse> handle(ApiRequest request, List<String> route) async {
    try {
      if (route.length > 2) return ApiResponse.error(HttpStatus.notFound, "not_found");
      final String? action = route.length == 2 ? route[1] : null;
      final _Open open = await _open(request, route[0]);

      return switch (action) {
        null => await _only("GET", request, () => _info(request, open)),
        "unlock" => await _only("POST", request, () => _unlock(request, open)),
        "entries" => await _only("GET", request, () => _entries(request, open)),
        "content" => await _content(request, open),
        _ => ApiResponse.error(HttpStatus.notFound, "not_found"),
      };
    } on ApiReject catch (reject) {
      return reject.response;
    } on StorageFault catch (fault) {
      return _fault(fault);
    } on PermissionRevokedFailure {
      return ApiResponse.error(HttpStatus.serviceUnavailable, "storage_unavailable");
    } on StorageDisconnectedFailure {
      return ApiResponse.error(HttpStatus.serviceUnavailable, "storage_unavailable");
    } on NotEnoughSpaceFailure {
      return ApiResponse.error(507, "insufficient_storage");
    }
  }

  static ApiResponse _fault(StorageFault fault) {
    return switch (fault.kind) {
      FaultKind.unavailable => ApiResponse.error(HttpStatus.serviceUnavailable, "storage_unavailable"),
      FaultKind.invalidPath || FaultKind.notAFile || FaultKind.notADirectory => ApiResponse.error(
        HttpStatus.badRequest,
        "invalid_path",
      ),
      FaultKind.interrupted => ApiResponse.error(HttpStatus.badRequest, "upload_interrupted", closeConnection: true),
      FaultKind.rangeNotSatisfiable => ApiResponse.error(
        HttpStatus.requestedRangeNotSatisfiable,
        "range_not_satisfiable",
        headers: <String, String>{"Content-Range": "bytes */${fault.size}"},
      ),
      // Everything else (no such root, no such file, no permission…) looks the same from outside.
      _ => ApiResponse.error(HttpStatus.notFound, "not_found"),
    };
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

  // ------------------------------------------------------------ the link

  Future<_Open> _open(ApiRequest request, String token) async {
    final String address = request.remoteAddress;
    final Duration? wait = _probeThrottle.lockedFor(address);
    if (wait != null) {
      throw ApiReject(
        ApiResponse.error(
          HttpStatus.tooManyRequests,
          "too_many_attempts",
          headers: <String, String>{"Retry-After": ((wait.inMilliseconds + 999) ~/ 1000).toString()},
        ),
      );
    }

    final Share? share = ShareTokens.looksValid(token) ? await _shares.findByTokenHash(ShareTokens.hash(token)) : null;
    if (share == null) {
      _probeThrottle.recordFailure(address);
      throw ApiReject(ApiResponse.error(HttpStatus.notFound, "not_found"));
    }

    final DateTime now = _clock.now();
    if (share.isExpired(now)) throw ApiReject(ApiResponse.error(410, "link_expired"));
    if (share.isUsedUp) throw ApiReject(ApiResponse.error(410, "link_used_up"));

    final Account? creator = await _accounts.findById(share.createdBy);
    if (creator == null || !creator.isEnabled) {
      throw ApiReject(ApiResponse.error(HttpStatus.notFound, "not_found"));
    }
    final StorageRoot root = await _gate.root(share.rootId, forWrite: share.kind == ShareKind.upload);
    final StoragePath base = StoragePath.parseDecoded(root.id, share.path);
    final Permission needed = share.kind == ShareKind.download ? Permission.read : Permission.write;
    // The link is only as strong as the person who made it is now.
    if (!_gate.allows(creator, needed, root, base)) {
      throw ApiReject(ApiResponse.error(HttpStatus.notFound, "not_found"));
    }
    return _Open(share, root, base);
  }

  void _requireUnlocked(ApiRequest request, _Open open) {
    if (!open.share.hasPassword) return;
    final String? proof = request.query["unlock"] ?? request.header("x-share-unlock");
    if (!_unlocks.isValid(open.share.id, proof)) {
      throw ApiReject(ApiResponse.error(HttpStatus.unauthorized, "password_required"));
    }
  }

  bool _isUnlocked(ApiRequest request, _Open open) {
    if (!open.share.hasPassword) return true;
    return _unlocks.isValid(open.share.id, request.query["unlock"] ?? request.header("x-share-unlock"));
  }

  // ------------------------------------------------------------- info/unlock

  Future<ApiResponse> _info(ApiRequest request, _Open open) async {
    final Share share = open.share;
    final bool unlocked = _isUnlocked(request, open);

    String? name;
    int? size;
    if (unlocked) {
      name = open.base.isRoot ? open.root.displayName : open.base.name;
      if (!share.isDirectory && share.kind == ShareKind.download) {
        final StorageEntry? entry = await _files.statEntry(FileRef(root: open.root, path: open.base));
        if (entry == null) throw ApiReject(ApiResponse.error(HttpStatus.notFound, "not_found"));
        size = entry.sizeBytes;
      }
    }

    return ApiResponse(
      HttpStatus.ok,
      json: <String, Object?>{
        "kind": share.kind.name,
        "isDirectory": share.isDirectory,
        "requiresPassword": share.hasPassword,
        "unlocked": unlocked,
        "name": name,
        "size": size,
        "expiresAt": share.expiresAt?.toUtc().toIso8601String(),
        "maxFileBytes": share.maxFileBytes,
        "remainingUses": share.maxUses == null ? null : share.maxUses! - share.useCount,
      },
    );
  }

  Future<ApiResponse> _unlock(ApiRequest request, _Open open) async {
    final Share share = open.share;
    if (!share.hasPassword) {
      return ApiResponse(HttpStatus.ok, json: <String, Object?>{"unlock": null, "expiresInSeconds": null});
    }

    final String key = "${share.id}|${request.remoteAddress}";
    final Duration? wait = _unlockThrottle.lockedFor(key);
    if (wait != null) {
      return ApiResponse.error(
        HttpStatus.tooManyRequests,
        "too_many_attempts",
        headers: <String, String>{"Retry-After": ((wait.inMilliseconds + 999) ~/ 1000).toString()},
      );
    }
    final Map<String, Object?> body = await readJsonObject(request);
    final Object? password = body["password"];
    if (password is! String) return ApiResponse.error(HttpStatus.badRequest, "bad_request");

    if (password.isEmpty || password.length > 128) {
      _unlockThrottle.recordFailure(key);
      return ApiResponse.error(HttpStatus.unauthorized, "invalid_password");
    }
    if (_passwordChecks >= maxConcurrentPasswordChecks) {
      return ApiResponse.error(
        HttpStatus.serviceUnavailable,
        "busy",
        headers: const <String, String>{"Retry-After": "2"},
      );
    }
    _passwordChecks++;
    final bool ok;
    try {
      ok = await _hasher.verify(password, share.passwordHash!);
    } finally {
      _passwordChecks--;
    }
    if (!ok) {
      _unlockThrottle.recordFailure(key);
      _activity.event(
        ActivityKind.linkUsed,
        "Someone typed the wrong password for a link.",
        severity: ActivitySeverity.warning,
        address: request.remoteAddress,
        throttleKey: "linkpw|$key",
        throttleFor: const Duration(seconds: 30),
      );
      return ApiResponse.error(HttpStatus.unauthorized, "invalid_password");
    }
    _unlockThrottle.recordSuccess(key);
    return ApiResponse(
      HttpStatus.ok,
      json: <String, Object?>{"unlock": _unlocks.issue(share.id), "expiresInSeconds": _unlocks.lifetime.inSeconds},
    );
  }

  // ------------------------------------------------------------- listing

  /// [base] plus a client-relative path, built name by name so it can never
  /// leave the shared folder.
  StoragePath _within(_Open open, String? relative) {
    final StoragePath rel;
    try {
      rel = StoragePath.parseDecoded(open.root.id, relative ?? "/");
    } on AppFailure {
      throw const StorageFault(FaultKind.invalidPath);
    }
    StoragePath full = open.base;
    try {
      for (final String segment in rel.segments) {
        full = full.child(segment);
      }
    } on AppFailure {
      throw const StorageFault(FaultKind.invalidPath);
    }
    if (StorageGate.isReserved(full)) throw const StorageFault(FaultKind.notFound);
    return full;
  }

  Future<ApiResponse> _entries(ApiRequest request, _Open open) async {
    if (open.share.kind != ShareKind.download || !open.share.isDirectory) {
      return ApiResponse.error(HttpStatus.badRequest, "not_a_folder_link");
    }
    _requireUnlocked(request, open);

    final int? limit = _parseLimit(request.query["limit"]);
    if (limit == null) return ApiResponse.error(HttpStatus.badRequest, "bad_request");
    final String? rawCursor = request.query["cursor"];
    final String? cursor = (rawCursor == null || rawCursor.isEmpty) ? null : rawCursor;

    final StoragePath directory = _within(open, request.query["path"]);
    final FileRef ref = FileRef(root: open.root, path: directory);
    if (directory != open.base) {
      final StorageEntry? stat = await _files.statEntry(ref);
      if (stat == null) return ApiResponse.error(HttpStatus.notFound, "not_found");
      if (!stat.isDirectory) return ApiResponse.error(HttpStatus.badRequest, "not_a_directory");
    }

    final List<StorageEntry> page = await _files.list(ref, cursor: cursor, pageSize: limit).toList();
    return ApiResponse(
      HttpStatus.ok,
      json: <String, Object?>{
        "path": "/${directory.segments.skip(open.base.segments.length).join("/")}",
        "entries": <Object?>[
          for (final StorageEntry entry in page)
            if (!(directory.isRoot && StorageGate.isReservedName(entry.name))) _entry(entry),
        ],
        "nextCursor": page.length == limit ? page.last.name : null,
      },
    );
  }

  static int? _parseLimit(String? raw) {
    if (raw == null) return defaultPageSize;
    final int? parsed = int.tryParse(raw);
    if (parsed == null || parsed < 1 || parsed > maxPageSize) return null;
    return parsed;
  }

  static Map<String, Object?> _entry(StorageEntry entry) => <String, Object?>{
    "name": entry.name,
    "type": entry.isDirectory ? "directory" : "file",
    "size": entry.sizeBytes,
    "modified": entry.modifiedAt?.toUtc().toIso8601String(),
  };

  // ------------------------------------------------------------- content

  Future<ApiResponse> _content(ApiRequest request, _Open open) {
    return switch (request.method) {
      "GET" || "HEAD" => _download(request, open),
      "PUT" => _upload(request, open),
      _ => Future<ApiResponse>.value(
        ApiResponse.error(
          HttpStatus.methodNotAllowed,
          "method_not_allowed",
          headers: const <String, String>{HttpHeaders.allowHeader: "GET, HEAD, PUT"},
        ),
      ),
    };
  }

  Future<ApiResponse> _download(ApiRequest request, _Open open) async {
    if (open.share.kind != ShareKind.download) {
      return ApiResponse.error(
        HttpStatus.methodNotAllowed,
        "method_not_allowed",
        headers: const <String, String>{HttpHeaders.allowHeader: "PUT"},
      );
    }
    _requireUnlocked(request, open);

    final StoragePath target;
    if (open.share.isDirectory) {
      target = _within(open, request.query["path"]);
      if (target == open.base) return ApiResponse.error(HttpStatus.badRequest, "invalid_path");
    } else {
      target = open.base;
    }

    final DownloadPlan plan = await _transfer.planDownload(open.root, target, rangeHeader: request.header("range"));

    // One download = one use: counted when the file is fetched from its start
    // (a resumed range or a HEAD isn't a second download).
    final bool fromStart = plan.range == null || plan.range!.start == 0;
    if (request.method == "GET" && fromStart && !await _shares.tryUse(open.share.id, _clock.now())) {
      return ApiResponse.error(410, "link_used_up");
    }

    final bool inline = request.query["inline"] == "1" && MimeTypes.isSafeToDisplayInline(plan.mimeType);
    final DateTime? modified = plan.entry.modifiedAt;

    Stream<List<int>> stream = request.method == "HEAD" ? Stream<List<int>>.empty() : plan.open();
    if (request.method == "GET" && fromStart) {
      _activity.event(
        ActivityKind.linkUsed,
        "Someone downloaded “${plan.entry.name}” with a link.",
        address: request.remoteAddress,
      );
      stream = _activity
          .transfer(
            direction: TransferDirection.download,
            via: AccessVia.link,
            actor: "Link",
            name: plan.entry.name,
            totalBytes: plan.length,
          )
          .watchDownload(stream);
    }
    return ApiResponse(
      plan.status,
      stream: stream,
      contentType: plan.mimeType,
      contentLength: plan.length,
      headers: <String, String>{
        "Content-Disposition": contentDisposition(plan.entry.name, inline: inline),
        "Accept-Ranges": plan.canRange ? "bytes" : "none",
        if (plan.contentRange != null) "Content-Range": plan.contentRange!,
        "Content-Security-Policy": downloadContentSecurityPolicy,
        if (modified != null) "Last-Modified": HttpDate.format(modified.toUtc()),
      },
    );
  }

  Future<ApiResponse> _upload(ApiRequest request, _Open open) async {
    final Share share = open.share;
    if (share.kind != ShareKind.upload) {
      return ApiResponse.error(
        HttpStatus.methodNotAllowed,
        "method_not_allowed",
        headers: const <String, String>{HttpHeaders.allowHeader: "GET, HEAD"},
      );
    }
    _requireUnlocked(request, open);

    // The person sending a file only picks a NAME; where it goes is fixed.
    final String? name = request.query["name"]?.trim();
    if (name == null || name.isEmpty || name.length > maxNameLength || name.startsWith(".")) {
      return ApiResponse.error(HttpStatus.badRequest, "invalid_name");
    }
    try {
      open.base.child(name);
    } on AppFailure {
      return ApiResponse.error(HttpStatus.badRequest, "invalid_name");
    }

    final int? limit = share.maxFileBytes;
    if (limit != null && request.contentLength > limit) {
      return ApiResponse.error(HttpStatus.requestEntityTooLarge, "file_too_large", closeConnection: true);
    }
    if (!await _shares.tryUse(share.id, _clock.now())) {
      return ApiResponse.error(410, "link_used_up");
    }

    // Never replace something already there: a second "notes.txt" becomes "notes (1).txt".
    final String finalName = await _files.resolveNonConflictingName(FileRef(root: open.root, path: open.base), name);
    final StoragePath target = open.base.child(finalName);

    bool tooLarge = false;
    int received = 0;
    Stream<List<int>> limited(Stream<List<int>> source) => limit == null
        ? source
        : source.transform(
            StreamTransformer<List<int>, List<int>>.fromHandlers(
              handleData: (List<int> chunk, EventSink<List<int>> sink) {
                if (tooLarge) return; // already refused: the rest is unwanted
                received += chunk.length;
                if (received > limit) {
                  tooLarge = true;
                  sink.addError(const FormatException("file too large"));
                } else {
                  sink.add(chunk);
                }
              },
            ),
          );

    final TransferMeter meter = _activity.transfer(
      direction: TransferDirection.upload,
      via: AccessVia.link,
      actor: "Link",
      name: finalName,
      totalBytes: request.contentLength >= 0 ? request.contentLength : null,
    );
    try {
      final UploadResult result = await meter.upload(
        request.bodyStream,
        (Stream<List<int>> counted) => _transfer.receive(open.root, target, limited(counted), overwrite: false),
      );
      _activity.event(
        ActivityKind.linkUsed,
        "Someone sent “$finalName” through an upload link.",
        address: request.remoteAddress,
      );
      return ApiResponse(HttpStatus.created, json: <String, Object?>{"name": finalName, "size": result.size});
    } on StorageFault {
      if (tooLarge) return ApiResponse.error(HttpStatus.requestEntityTooLarge, "file_too_large", closeConnection: true);
      rethrow;
    }
  }
}

final class _Open {
  const _Open(this.share, this.root, this.base);

  final Share share;
  final StorageRoot root;
  final StoragePath base;
}
