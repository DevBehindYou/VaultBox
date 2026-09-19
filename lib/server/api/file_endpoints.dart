import "dart:async";
import "dart:io";

import "../../core/errors/app_failure.dart";
import "../../core/utils/mime_types.dart";
import "../../domain/entities/account.dart";
import "../../domain/entities/storage_root.dart";
import "../../domain/models/file_ref.dart";
import "../../domain/models/operation_batch.dart";
import "../../domain/repositories/account_repository.dart";
import "../../domain/repositories/file_repository.dart";
import "../../domain/repositories/storage_backend.dart";
import "../../domain/repositories/storage_root_repository.dart";
import "../../domain/security/authorizer.dart";
import "../../domain/security/download_tickets.dart";
import "../../domain/usecases/copy_items.dart";
import "../../domain/usecases/delete_items_to_recycle_bin.dart";
import "../../domain/usecases/move_items.dart";
import "../../domain/value_objects/storage_entry.dart";
import "../../domain/value_objects/storage_path.dart";
import "../../domain/value_objects/write_mode.dart";
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
    required StorageRootRepository roots,
    required FileRepository files,
    required AccountRepository accounts,
    required Authorizer authorizer,
    required DownloadTicketService tickets,
    required CopyItems copy,
    required MoveItems move,
    required DeleteItemsToRecycleBin delete,
  }) : _roots = roots,
       _files = files,
       _accounts = accounts,
       _tickets = tickets,
       _authorizer = authorizer,
       _copy = copy,
       _move = move,
       _delete = delete;

  final StorageRootRepository _roots;
  final FileRepository _files;
  final AccountRepository _accounts;
  final DownloadTicketService _tickets;
  final Authorizer _authorizer;
  final CopyItems _copy;
  final MoveItems _move;
  final DeleteItemsToRecycleBin _delete;

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

  /// VaultBox's bookkeeping folder (Recycle Bin). Lower-cased: some Android
  /// storage is case-insensitive.
  static const String _reservedDirName = ".vaultbox";

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
      if (ticket == null || account == null) return ApiResponse.error(HttpStatus.notFound, "not_found");

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

  Future<StorageRoot> _root(String rootId, {bool forWrite = false}) async {
    final StorageRoot? root = await _roots.getRoot(rootId);
    if (root == null || !root.isEnabled) {
      throw ApiReject(ApiResponse.error(HttpStatus.notFound, "root_not_found"));
    }
    if (!root.isAvailable) {
      throw ApiReject(ApiResponse.error(HttpStatus.serviceUnavailable, "storage_unavailable"));
    }
    if (forWrite && !root.capabilities.canWrite) {
      throw ApiReject(ApiResponse.error(HttpStatus.forbidden, "read_only_storage"));
    }
    return root;
  }

  StoragePath _parse(StorageRoot root, String? raw, {bool allowRoot = true}) {
    final StoragePath path;
    try {
      path = StoragePath.parse(root.id, raw ?? "/");
    } on AppFailure {
      throw ApiReject(ApiResponse.error(HttpStatus.badRequest, "invalid_path"));
    }
    if (path.segments.isNotEmpty && path.segments.first.toLowerCase() == _reservedDirName) {
      throw ApiReject(ApiResponse.error(HttpStatus.notFound, "not_found"));
    }
    if (!allowRoot && path.isRoot) {
      throw ApiReject(ApiResponse.error(HttpStatus.badRequest, "invalid_path"));
    }
    return path;
  }

  void _require(ApiCaller caller, Permission permission, StorageRoot root, StoragePath path) {
    _requireAccount(caller.account, permission, root, path);
  }

  void _requireAccount(Account account, Permission permission, StorageRoot root, StoragePath path) {
    if (!_authorizer.allows(account, permission, root, path)) {
      throw ApiReject(ApiResponse.error(HttpStatus.forbidden, "forbidden"));
    }
  }

  /// A directory that must exist (the root always does).
  Future<void> _requireDirectory(FileRef directory, {required int status, required String code}) async {
    if (directory.path.isRoot) return;
    final StorageEntry? entry = await _files.statEntry(directory);
    if (entry == null || !entry.isDirectory) throw ApiReject(ApiResponse.error(status, code));
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
            if (!(path.isRoot && entry.name.toLowerCase() == _reservedDirName)) _entry(entry),
        ],
        "nextCursor": hasMore ? page.last.name : null,
      },
    );
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
    _requireAccount(account, Permission.read, root, path);

    final FileRef ref = FileRef(root: root, path: path);
    final StorageEntry? entry = await _files.statEntry(ref);
    if (entry == null) return ApiResponse.error(HttpStatus.notFound, "not_found");
    if (entry.isDirectory) return ApiResponse.error(HttpStatus.badRequest, "not_a_file");

    final String mime = MimeTypes.forName(entry.name);
    final bool inline = request.query["inline"] == "1" && MimeTypes.isSafeToDisplayInline(mime);
    final int? size = entry.sizeBytes;
    final bool canRange = root.capabilities.supportsRandomAccess && size != null;

    final Map<String, String> headers = <String, String>{
      "Content-Disposition": _disposition(entry.name, inline: inline),
      "Accept-Ranges": canRange ? "bytes" : "none",
      // Even a "safe" inline type gets no scripting: a hostile file can't act as the site.
      "Content-Security-Policy": "sandbox; default-src 'none'; style-src 'unsafe-inline'",
      if (entry.modifiedAt != null) "Last-Modified": HttpDate.format(entry.modifiedAt!.toUtc()),
    };

    int start = 0;
    int? end; // inclusive
    int status = HttpStatus.ok;
    final String? rangeHeader = request.header("range");
    if (rangeHeader != null && canRange) {
      final _ByteRange? parsed = _ByteRange.parse(rangeHeader, size);
      if (parsed == _ByteRange.unsatisfiable) {
        return ApiResponse.error(
          HttpStatus.requestedRangeNotSatisfiable,
          "range_not_satisfiable",
          headers: <String, String>{"Content-Range": "bytes */$size"},
        );
      }
      if (parsed != null) {
        start = parsed.start;
        end = parsed.end;
        status = HttpStatus.partialContent;
        headers["Content-Range"] = "bytes $start-$end/$size";
      }
    }

    final int? length = status == HttpStatus.partialContent ? end! - start + 1 : size;
    if (request.method == "HEAD") {
      return ApiResponse(
        status,
        stream: Stream<List<int>>.empty(),
        contentType: mime,
        contentLength: length,
        headers: headers,
      );
    }
    return ApiResponse(
      status,
      stream: _files.openRead(ref, start: status == HttpStatus.partialContent ? start : null, end: end),
      contentType: mime,
      contentLength: length,
      headers: headers,
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
    final bool overwrite = request.query["overwrite"] == "1";

    await _requireDirectory(
      FileRef(root: root, path: path.parent),
      status: HttpStatus.conflict,
      code: "parent_not_found",
    );
    final FileRef ref = FileRef(root: root, path: path);
    final StorageEntry? existing = await _files.statEntry(ref);
    if (existing != null) {
      if (existing.isDirectory) return ApiResponse.error(HttpStatus.conflict, "is_a_directory");
      if (!overwrite) return ApiResponse.error(HttpStatus.conflict, "already_exists");
    }

    final StorageWriteHandle handle = await _files.openWrite(
      ref,
      mode: existing == null ? WriteMode.create : WriteMode.replace,
    );

    // Capture a failure of the CLIENT's stream ourselves: sinks differ in how
    // they report a broken source, and a half-received file must never be
    // committed as if it were complete.
    // (An `async*` wrapper can't do this: `yield*` forwards a stream's errors
    // without throwing them inside the generator, so a try/catch never sees them.)
    Object? sourceError;
    final Stream<List<int>> body = request.bodyStream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleError: (Object error, StackTrace trace, EventSink<List<int>> sink) {
          sourceError ??= error;
          sink.addError(error, trace);
        },
      ),
    );

    try {
      try {
        await handle.sink.addStream(body);
      } on Object {
        if (sourceError == null) rethrow;
      }
      if (sourceError != null) {
        await handle.abort();
        return ApiResponse.error(HttpStatus.badRequest, "upload_interrupted", closeConnection: true);
      }
      final int written = await handle.commit();
      return ApiResponse(
        existing == null ? HttpStatus.created : HttpStatus.ok,
        json: <String, Object?>{"path": _fmt(path), "size": written},
      );
    } catch (_) {
      await handle.abort(); // no-op if already committed
      rethrow;
    }
  }

  static String _disposition(String name, {required bool inline}) {
    final String ascii = name.replaceAll(RegExp(r"[^A-Za-z0-9._ -]"), "_");
    final String encoded = Uri.encodeComponent(name).replaceAll("'", "%27");
    return "${inline ? "inline" : "attachment"}; filename=\"$ascii\"; filename*=UTF-8''$encoded";
  }

  // --- changes ---

  Future<ApiResponse> _mkdir(ApiRequest request, ApiCaller caller, String rootId) async {
    final StorageRoot root = await _root(rootId, forWrite: true);
    final Map<String, Object?> body = await readJsonObject(request);
    final Object? raw = body["path"];
    if (raw is! String) return ApiResponse.error(HttpStatus.badRequest, "bad_request");

    final StoragePath path = _parse(root, raw, allowRoot: false);
    _require(caller, Permission.write, root, path);
    await _requireDirectory(
      FileRef(root: root, path: path.parent),
      status: HttpStatus.conflict,
      code: "parent_not_found",
    );
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
    if (target.parent.isRoot && target.name.toLowerCase() == _reservedDirName) {
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
    await _requireDirectory(destinationDirectory, status: HttpStatus.conflict, code: "destination_not_found");

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

/// One satisfiable `Range: bytes=…` (single range only), inclusive on both ends.
final class _ByteRange {
  const _ByteRange(this.start, this.end);

  /// Marker: syntactically valid but outside the file (answer 416).
  static const _ByteRange unsatisfiable = _ByteRange(-1, -1);

  final int start;
  final int end;

  /// `null` means "ignore the header and send everything" (unparseable, or a
  /// multi-range request we don't split).
  static _ByteRange? parse(String header, int size) {
    final RegExpMatch? match = RegExp(r"^bytes=(\d*)-(\d*)$").firstMatch(header.trim());
    if (match == null) return null;
    final String from = match.group(1)!;
    final String to = match.group(2)!;
    if (from.isEmpty && to.isEmpty) return null;

    if (from.isEmpty) {
      // Suffix: the last N bytes.
      final int? count = int.tryParse(to);
      if (count == null) return null;
      if (count == 0 || size == 0) return unsatisfiable;
      return _ByteRange(count >= size ? 0 : size - count, size - 1);
    }
    final int? start = int.tryParse(from);
    if (start == null) return null;
    if (to.isEmpty) {
      // Open-ended: from [start] to the end.
      return start >= size ? unsatisfiable : _ByteRange(start, size - 1);
    }
    final int? last = int.tryParse(to);
    if (last == null || last < start) return null; // an invalid range is ignored (RFC 9110)
    if (start >= size) return unsatisfiable;
    return _ByteRange(start, last >= size ? size - 1 : last);
  }
}
