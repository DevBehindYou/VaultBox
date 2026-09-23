import "dart:io";

import "../../core/errors/app_failure.dart";
import "../../core/utils/mime_types.dart";
import "../../domain/entities/account.dart";
import "../../domain/entities/activity.dart";
import "../../domain/entities/storage_root.dart";
import "../../domain/models/file_ref.dart";
import "../../domain/models/operation_batch.dart";
import "../../domain/repositories/account_repository.dart";
import "../../domain/repositories/file_repository.dart";
import "../../domain/security/authorizer.dart";
import "../../domain/security/download_tickets.dart";
import "../../domain/usecases/copy_items.dart";
import "../../domain/usecases/delete_items_to_recycle_bin.dart";
import "../../domain/usecases/move_items.dart";
import "../../domain/value_objects/storage_entry.dart";
import "../../domain/value_objects/storage_path.dart";
import "../../domain/value_objects/write_mode.dart";
import "../activity/activity_log.dart";
import "../files/content_disposition.dart";
import "../files/file_transfer.dart";
import "../files/storage_gate.dart";
import "api_json.dart";
import "api_types.dart";

/// Everything under `/api/v1/roots/{id}/…` — browsing, downloads, uploads and
/// the file operations. Every request is authorised PER PATH through the
/// [Authorizer]; nothing here decides who may do what.
///
/// Rules that hold for every endpoint:
///  - client paths only ever enter through [StoragePath.parse];
///  - VaultBox's own `.vaultbox` folder (Recycle Bin) does not exist to clients;
///  - a read-only storage root refuses every mutation;
///  - failures become stable `{ "error": "<code>" }` answers, never internals.
final class FileEndpoints {
  FileEndpoints({
    required StorageGate gate,
    required FileRepository files,
    required AccountRepository accounts,
    required DownloadTicketService tickets,
    required CopyItems copy,
    required MoveItems move,
    required DeleteItemsToRecycleBin delete,
    ActivityLog? activity,
  }) : _gate = gate,
       _files = files,
       _transfer = FileTransfer(files),
       _accounts = accounts,
       _tickets = tickets,
       _copy = copy,
       _move = move,
       _delete = delete,
       _activity = activity ?? ActivityLog.none();

  final StorageGate _gate;
  final FileRepository _files;
  final FileTransfer _transfer;
  final AccountRepository _accounts;
  final DownloadTicketService _tickets;
  final CopyItems _copy;
  final MoveItems _move;
  final DeleteItemsToRecycleBin _delete;
  final ActivityLog _activity;

  static const int defaultPageSize = 200;
  static const int maxPageSize = 500;
  static const int maxBatchItems = 500;
  static const int maxNameLength = 255;

  /// The actions that exist under a root.
  static const Set<String> actions = <String>{
    "entries",
    "stat",
    "content",
    "ticket",
    "mkdir",
    "rename",
    "move",
    "copy",
    "delete",
  };

  Future<ApiResponse> handle(ApiRequest request, ApiCaller caller, String rootId, String action) {
    return _guarded(() async {
      return switch (action) {
        "entries" => await _only("GET", request, () => _entries(request, caller, rootId)),
        "stat" => await _only("GET", request, () => _stat(request, caller, rootId)),
        "content" => await _content(request, caller, rootId),
        "ticket" => await _only("POST", request, () => _ticket(request, caller, rootId)),
        "mkdir" => await _only("POST", request, () => _mkdir(request, caller, rootId)),
        "rename" => await _only("POST", request, () => _rename(request, caller, rootId)),
        "move" => await _only("POST", request, () => _moveOrCopy(request, caller, rootId, move: true)),
        "copy" => await _only("POST", request, () => _moveOrCopy(request, caller, rootId, move: false)),
        "delete" => await _only("POST", request, () => _deleteToRecycleBin(request, caller, rootId)),
        _ => ApiResponse.error(HttpStatus.notFound, "not_found"),
      };
    });
  }

  /// `GET|HEAD /d/<ticket>`: a short-lived link for one file (see
  /// [DownloadTicketService]). Unknown or expired tickets are a plain 404.
  Future<ApiResponse> downloadByTicket(ApiRequest request, String token) {
    return _guarded(() async {
      if (request.method != "GET" && request.method != "HEAD") {
        return ApiResponse.error(
          HttpStatus.methodNotAllowed,
          "method_not_allowed",
          headers: const <String, String>{HttpHeaders.allowHeader: "GET, HEAD"},
        );
      }
      final DownloadTicket? ticket = _tickets.resolve(token);
      final Account? account = ticket == null ? null : await _accounts.findById(ticket.accountId);
      if (ticket == null || account == null || !account.isEnabled) {
        return ApiResponse.error(HttpStatus.notFound, "not_found");
      }

      final StorageRoot root = await _root(ticket.rootId);
      final StoragePath path = _parse(root, ticket.path, allowRoot: false);
      return _serveFile(request, account, root, path);
    });
  }

  /// Revokes every ticket a login session asked for.
  void revokeTickets(String sessionHash) => _tickets.revokeSession(sessionHash);

  Future<ApiResponse> _guarded(Future<ApiResponse> Function() run) async {
    try {
      return await run();
    } on ApiReject catch (reject) {
      return reject.response;
    } on StorageFault catch (fault) {
      return _fault(fault);
    } on PermissionRevokedFailure {
      return ApiResponse.error(HttpStatus.conflict, "storage_permission_revoked");
    } on StorageDisconnectedFailure {
      return ApiResponse.error(HttpStatus.serviceUnavailable, "storage_unavailable");
    } on PathTraversalRejectedFailure {
      return ApiResponse.error(HttpStatus.badRequest, "invalid_path");
    } on PathConflictFailure {
      return ApiResponse.error(HttpStatus.conflict, "already_exists");
    } on NotEnoughSpaceFailure {
      return ApiResponse.error(507, "insufficient_storage");
    } on InvalidOperationFailure {
      return ApiResponse.error(HttpStatus.badRequest, "invalid_operation");
    } on ValidationFailure {
      return ApiResponse.error(HttpStatus.badRequest, "bad_request");
    }
    // Anything else is unexpected: the router turns it into a bare 500.
  }

  // --- routing helpers ---

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

  static ApiResponse _fault(StorageFault fault) {
    return switch (fault.kind) {
      FaultKind.rootNotFound => ApiResponse.error(HttpStatus.notFound, "root_not_found"),
      FaultKind.unavailable => ApiResponse.error(HttpStatus.serviceUnavailable, "storage_unavailable"),
      FaultKind.readOnly => ApiResponse.error(HttpStatus.forbidden, "read_only_storage"),
      FaultKind.invalidPath => ApiResponse.error(HttpStatus.badRequest, "invalid_path"),
      FaultKind.notFound => ApiResponse.error(HttpStatus.notFound, "not_found"),
      FaultKind.forbidden => ApiResponse.error(HttpStatus.forbidden, "forbidden"),
      FaultKind.notAFile => ApiResponse.error(HttpStatus.badRequest, "not_a_file"),
      FaultKind.notADirectory => ApiResponse.error(HttpStatus.badRequest, "not_a_directory"),
      FaultKind.parentMissing => ApiResponse.error(HttpStatus.conflict, "parent_not_found"),
      FaultKind.destinationMissing => ApiResponse.error(HttpStatus.conflict, "destination_not_found"),
      FaultKind.exists => ApiResponse.error(HttpStatus.conflict, "already_exists"),
      FaultKind.isADirectory => ApiResponse.error(HttpStatus.conflict, "is_a_directory"),
      FaultKind.interrupted => ApiResponse.error(HttpStatus.badRequest, "upload_interrupted", closeConnection: true),
      FaultKind.rangeNotSatisfiable => ApiResponse.error(
        HttpStatus.requestedRangeNotSatisfiable,
        "range_not_satisfiable",
        headers: <String, String>{"Content-Range": "bytes */${fault.size}"},
      ),
    };
  }

  Future<StorageRoot> _root(String rootId, {bool forWrite = false}) => _gate.root(rootId, forWrite: forWrite);

  StoragePath _parse(StorageRoot root, String? raw, {bool allowRoot = true}) =>
      _gate.parse(root, raw, allowRoot: allowRoot);

  void _require(ApiCaller caller, Permission permission, StorageRoot root, StoragePath path) {
    _gate.require(caller.account, permission, root, path);
  }

  List<StoragePath> _pathList(StorageRoot root, Object? raw) {
    if (raw is! List<Object?> || raw.isEmpty || raw.length > maxBatchItems) {
      throw ApiReject(ApiResponse.error(HttpStatus.badRequest, "bad_request"));
    }
    return <StoragePath>[
      for (final Object? item in raw)
        if (item is String)
          _parse(root, item, allowRoot: false)
        else
          throw ApiReject(ApiResponse.error(HttpStatus.badRequest, "bad_request")),
    ];
  }

  static String _fmt(StoragePath path) => "/${path.segments.join("/")}";

  // --- browsing ---

  Future<ApiResponse> _entries(ApiRequest request, ApiCaller caller, String rootId) async {
    final StorageRoot root = await _root(rootId);
    final int? limit = _parseLimit(request.query["limit"]);
    if (limit == null) return ApiResponse.error(HttpStatus.badRequest, "bad_request");
    final String? rawCursor = request.query["cursor"];
    final String? cursor = (rawCursor == null || rawCursor.isEmpty) ? null : rawCursor;

    final StoragePath path = _parse(root, request.query["path"]);
    _require(caller, Permission.read, root, path);

    final FileRef directory = FileRef(root: root, path: path);
    if (!path.isRoot) {
      final StorageEntry? stat = await _files.statEntry(directory);
      if (stat == null) return ApiResponse.error(HttpStatus.notFound, "not_found");
      if (!stat.isDirectory) return ApiResponse.error(HttpStatus.badRequest, "not_a_directory");
    }

    final List<StorageEntry> page = await _files.list(directory, cursor: cursor, pageSize: limit).toList();

    // The cursor follows the RAW page so hiding an entry can't stall paging.
    final bool hasMore = page.length == limit;
    return ApiResponse(
      HttpStatus.ok,
      json: <String, Object?>{
        "path": _fmt(path),
        "entries": <Object?>[
          for (final StorageEntry entry in page)
            if (!(path.isRoot && StorageGate.isReservedName(entry.name)) && _mayList(caller, root, path, entry))
              _entry(entry),
        ],
        "nextCursor": hasMore ? page.last.name : null,
      },
    );
  }

  /// A listing shows only what the caller may read (a member granted one folder
  /// sees just the way down to it).
  bool _mayList(ApiCaller caller, StorageRoot root, StoragePath directory, StorageEntry entry) {
    final StoragePath child;
    try {
      child = directory.child(entry.name);
    } on AppFailure {
      return false; // a name that can't be represented safely is never listed
    }
    return _gate.allows(caller.account, Permission.read, root, child);
  }

  Future<ApiResponse> _stat(ApiRequest request, ApiCaller caller, String rootId) async {
    final StorageRoot root = await _root(rootId);
    final StoragePath path = _parse(root, request.query["path"]);
    _require(caller, Permission.read, root, path);

    if (path.isRoot) {
      return ApiResponse(
        HttpStatus.ok,
        json: <String, Object?>{
          "path": "/",
          "name": root.displayName,
          "type": "directory",
          "size": null,
          "modified": null,
          "mime": null,
        },
      );
    }
    final StorageEntry? entry = await _files.statEntry(FileRef(root: root, path: path));
    if (entry == null) return ApiResponse.error(HttpStatus.notFound, "not_found");
    return ApiResponse(HttpStatus.ok, json: <String, Object?>{"path": _fmt(path), ..._entry(entry)});
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
    "mime": entry.mimeType,
  };

  // --- content: download + upload ---

  Future<ApiResponse> _content(ApiRequest request, ApiCaller caller, String rootId) {
    return switch (request.method) {
      "GET" || "HEAD" => _download(request, caller, rootId),
      "PUT" => _upload(request, caller, rootId),
      _ => Future<ApiResponse>.value(
        ApiResponse.error(
          HttpStatus.methodNotAllowed,
          "method_not_allowed",
          headers: const <String, String>{HttpHeaders.allowHeader: "GET, HEAD, PUT"},
        ),
      ),
    };
  }

  Future<ApiResponse> _download(ApiRequest request, ApiCaller caller, String rootId) async {
    final StorageRoot root = await _root(rootId);
    final StoragePath path = _parse(root, request.query["path"], allowRoot: false);
    return _serveFile(request, caller.account, root, path);
  }

  /// Streams one file (whole, or one byte range). Shared by the bearer-token
  /// download and the ticket link, so both enforce exactly the same rules.
  Future<ApiResponse> _serveFile(ApiRequest request, Account account, StorageRoot root, StoragePath path) async {
    _gate.require(account, Permission.read, root, path);

    final DownloadPlan plan = await _transfer.planDownload(root, path, rangeHeader: request.header("range"));
    final bool inline = request.query["inline"] == "1" && MimeTypes.isSafeToDisplayInline(plan.mimeType);
    final DateTime? modified = plan.entry.modifiedAt;

    // One row per download: a HEAD moves nothing, and a resumed range isn't a new file.
    Stream<List<int>> body = request.method == "HEAD" ? Stream<List<int>>.empty() : plan.open();
    if (request.method == "GET" && (plan.range == null || plan.range!.start == 0)) {
      body = _activity
          .transfer(
            direction: TransferDirection.download,
            via: AccessVia.web,
            actor: account.username,
            name: plan.entry.name,
            totalBytes: plan.length,
          )
          .watchDownload(body);
    }

    return ApiResponse(
      plan.status,
      stream: body,
      contentType: plan.mimeType,
      contentLength: plan.length,
      headers: <String, String>{
        "Content-Disposition": contentDisposition(plan.entry.name, inline: inline),
        "Accept-Ranges": plan.canRange ? "bytes" : "none",
        if (plan.contentRange != null) "Content-Range": plan.contentRange!,
        // Even a "safe" inline type gets no scripting: a hostile file can't act as the site.
        "Content-Security-Policy": downloadContentSecurityPolicy,
        if (modified != null) "Last-Modified": HttpDate.format(modified.toUtc()),
      },
    );
  }

  /// Issues a short-lived link for one existing file (see [DownloadTicketService]).
  Future<ApiResponse> _ticket(ApiRequest request, ApiCaller caller, String rootId) async {
    final StorageRoot root = await _root(rootId);
    final Map<String, Object?> body = await readJsonObject(request);
    final Object? raw = body["path"];
    if (raw is! String) return ApiResponse.error(HttpStatus.badRequest, "bad_request");

    final StoragePath path = _parse(root, raw, allowRoot: false);
    _require(caller, Permission.read, root, path);
    final StorageEntry? entry = await _files.statEntry(FileRef(root: root, path: path));
    if (entry == null) return ApiResponse.error(HttpStatus.notFound, "not_found");
    if (entry.isDirectory) return ApiResponse.error(HttpStatus.badRequest, "not_a_file");

    final String token = _tickets.issue(
      accountId: caller.account.id,
      sessionHash: caller.session.tokenHash,
      rootId: root.id,
      path: _fmt(path),
    );
    return ApiResponse(
      HttpStatus.ok,
      json: <String, Object?>{"url": "/d/$token", "expiresInSeconds": _tickets.lifetime.inSeconds},
    );
  }

  Future<ApiResponse> _upload(ApiRequest request, ApiCaller caller, String rootId) async {
    final StorageRoot root = await _root(rootId, forWrite: true);
    final StoragePath path = _parse(root, request.query["path"], allowRoot: false);
    _require(caller, Permission.write, root, path);

    final TransferMeter meter = _activity.transfer(
      direction: TransferDirection.upload,
      via: AccessVia.web,
      actor: caller.account.username,
      name: path.name,
      totalBytes: request.contentLength >= 0 ? request.contentLength : null,
    );
    final UploadResult result = await meter.upload(
      request.bodyStream,
      (Stream<List<int>> counted) =>
          _transfer.receive(root, path, counted, overwrite: request.query["overwrite"] == "1"),
    );
    return ApiResponse(
      result.created ? HttpStatus.created : HttpStatus.ok,
      json: <String, Object?>{"path": _fmt(path), "size": result.size},
    );
  }

  // --- changes ---

  Future<ApiResponse> _mkdir(ApiRequest request, ApiCaller caller, String rootId) async {
    final StorageRoot root = await _root(rootId, forWrite: true);
    final Map<String, Object?> body = await readJsonObject(request);
    final Object? raw = body["path"];
    if (raw is! String) return ApiResponse.error(HttpStatus.badRequest, "bad_request");

    final StoragePath path = _parse(root, raw, allowRoot: false);
    _require(caller, Permission.write, root, path);
    await _transfer.requireDirectory(FileRef(root: root, path: path.parent), FaultKind.parentMissing);
    if (await _files.statEntry(FileRef(root: root, path: path)) != null) {
      return ApiResponse.error(HttpStatus.conflict, "already_exists");
    }

    await _files.createDirectory(FileRef(root: root, path: path.parent), path.name);
    return ApiResponse(HttpStatus.created, json: <String, Object?>{"path": _fmt(path)});
  }

  Future<ApiResponse> _rename(ApiRequest request, ApiCaller caller, String rootId) async {
    final StorageRoot root = await _root(rootId, forWrite: true);
    final Map<String, Object?> body = await readJsonObject(request);
    final Object? rawPath = body["path"];
    final Object? newName = body["newName"];
    if (rawPath is! String || newName is! String) return ApiResponse.error(HttpStatus.badRequest, "bad_request");

    final StoragePath path = _parse(root, rawPath, allowRoot: false);
    _require(caller, Permission.write, root, path);

    final StoragePath target;
    try {
      if (newName.length > maxNameLength) throw const ValidationFailure(message: "name too long");
      target = path.parent.child(newName);
    } on AppFailure {
      return ApiResponse.error(HttpStatus.badRequest, "invalid_name");
    }
    if (target.parent.isRoot && StorageGate.isReservedName(target.name)) {
      return ApiResponse.error(HttpStatus.badRequest, "invalid_name");
    }
    _require(caller, Permission.write, root, target);

    final FileRef source = FileRef(root: root, path: path);
    if (await _files.statEntry(source) == null) return ApiResponse.error(HttpStatus.notFound, "not_found");
    if (target != path && await _files.statEntry(FileRef(root: root, path: target)) != null) {
      return ApiResponse.error(HttpStatus.conflict, "already_exists");
    }

    await _files.renameSingle(source, newName);
    return ApiResponse(HttpStatus.ok, json: <String, Object?>{"path": _fmt(target)});
  }

  Future<ApiResponse> _moveOrCopy(ApiRequest request, ApiCaller caller, String rootId, {required bool move}) async {
    final StorageRoot root = await _root(rootId, forWrite: true);
    final Map<String, Object?> body = await readJsonObject(request);
    final List<StoragePath> sources = _pathList(root, body["sources"]);
    final Object? rawDestination = body["destination"];
    if (rawDestination is! String) return ApiResponse.error(HttpStatus.badRequest, "bad_request");
    final StoragePath destination = _parse(root, rawDestination);
    final ConflictPolicy? policy = _conflictPolicy(body["conflict"]);
    if (policy == null) return ApiResponse.error(HttpStatus.badRequest, "bad_request");

    for (final StoragePath source in sources) {
      _require(caller, Permission.read, root, source);
      if (move) _require(caller, Permission.delete, root, source);
    }
    _require(caller, Permission.write, root, destination);

    final FileRef destinationDirectory = FileRef(root: root, path: destination);
    await _transfer.requireDirectory(destinationDirectory, FaultKind.destinationMissing);

    final List<FileRef> refs = <FileRef>[for (final StoragePath s in sources) FileRef(root: root, path: s)];
    final OperationBatch batch = move
        ? await _move(sources: refs, destinationDirectory: destinationDirectory, conflictPolicy: policy)
        : await _copy(sources: refs, destinationDirectory: destinationDirectory, conflictPolicy: policy);
    return _batchResponse(batch);
  }

  Future<ApiResponse> _deleteToRecycleBin(ApiRequest request, ApiCaller caller, String rootId) async {
    final StorageRoot root = await _root(rootId, forWrite: true);
    final Map<String, Object?> body = await readJsonObject(request);
    final List<StoragePath> paths = _pathList(root, body["paths"]);
    for (final StoragePath path in paths) {
      _require(caller, Permission.delete, root, path);
    }

    final OperationBatch batch = await _delete(
      sources: <FileRef>[for (final StoragePath p in paths) FileRef(root: root, path: p)],
    );
    return _batchResponse(batch);
  }

  static ConflictPolicy? _conflictPolicy(Object? raw) {
    return switch (raw) {
      null || "skip" => ConflictPolicy.skip,
      "keepBoth" => ConflictPolicy.keepBoth,
      "replace" => ConflictPolicy.replace,
      _ => null,
    };
  }

  static ApiResponse _batchResponse(OperationBatch batch) {
    return ApiResponse(
      HttpStatus.ok,
      json: <String, Object?>{
        "completed": batch.completedCount,
        "skipped": batch.skippedCount,
        "failed": batch.failedCount,
        "results": <Object?>[
          for (final ItemOutcome outcome in batch.outcomes)
            <String, Object?>{
              "source": _fmt(outcome.source),
              "status": outcome.status.name,
              "target": outcome.target == null ? null : _fmt(outcome.target!),
              "message": outcome.userMessage,
            },
        ],
      },
    );
  }
}
