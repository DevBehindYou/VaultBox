import "dart:convert";
import "dart:io";

import "../../core/errors/app_failure.dart";
import "../../core/utils/mime_types.dart";
import "../../domain/entities/account.dart";
import "../../domain/entities/activity.dart";
import "../../domain/entities/storage_root.dart";
import "../../domain/models/file_ref.dart";
import "../../domain/models/operation_batch.dart";
import "../../domain/repositories/file_repository.dart";
import "../../domain/security/authorizer.dart";
import "../../domain/usecases/delete_items_to_recycle_bin.dart";
import "../../domain/value_objects/storage_entry.dart";
import "../../domain/value_objects/storage_path.dart";
import "../../domain/value_objects/write_mode.dart";
import "../activity/activity_log.dart";
import "../api/api_types.dart";
import "../files/file_transfer.dart";
import "../files/root_names.dart";
import "../files/storage_gate.dart";
import "dav_auth.dart";
import "dav_locks.dart";
import "dav_xml.dart";

/// WebDAV (RFC 4918, classes 1 and 2) over the same storage the web API uses.
///
/// Mounted at `/dav/`. Each storage location appears as a top-level folder named
/// after it (`/dav/Phone-storage/…`). Every request goes through [StorageGate]
/// (paths, hidden Recycle Bin folder, read-only roots, per-path authorisation)
/// and [FileTransfer] (safe streamed writes, ranged reads) — the same code as
/// the web API — so a rule can't hold on one surface and be missing here.
///
/// Deliberate choices:
///  - DELETE goes to the Recycle Bin (ADR-012), never straight to oblivion;
///  - COPY/MOVE that would overwrite a folder recycle it first; overwriting a
///    file replaces it atomically;
///  - PROPPATCH stores nothing (only Microsoft's cosmetic Win32* timestamps are
///    acknowledged); real properties are refused honestly with 403;
///  - locks are in memory, owned by the account that took them.
final class WebDavHandler {
  WebDavHandler({
    required StorageGate gate,
    required FileRepository files,
    required DeleteItemsToRecycleBin delete,
    required DavAuthenticator auth,
    required DavLockManager locks,
    ActivityLog? activity,
  }) : _activity = activity ?? ActivityLog.none(),
       _gate = gate,
       _files = files,
       _transfer = FileTransfer(files),
       _delete = delete,
       _auth = auth,
       _locks = locks;

  final StorageGate _gate;
  final FileRepository _files;
  final FileTransfer _transfer;
  final DeleteItemsToRecycleBin _delete;
  final DavAuthenticator _auth;
  final DavLockManager _locks;
  final ActivityLog _activity;

  /// First URL segment that belongs to WebDAV.
  static const String prefix = "dav";

  static const int maxBodyBytes = 64 * 1024;

  /// A folder with more entries than this can't be listed in one PROPFIND.
  static const int maxListing = 50000;

  static const String allowedMethods = "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, COPY, MOVE, PROPFIND, PROPPATCH, LOCK, UNLOCK";

  static const String _xmlType = "application/xml; charset=utf-8";

  Future<ApiResponse> _allowed(ApiRequest request, Account account) {
    _activity.seen(actor: account.username, address: request.remoteAddress, via: AccessVia.webdav);
    return _dispatch(request, account);
  }

  /// A request that arrived with no (or wrong) credentials. Only one that
  /// actually offered some is worth noting: a client's first, header-less probe
  /// is just how Basic authentication starts.
  ApiResponse _refused(ApiRequest request, ApiResponse response) {
    if (request.header("authorization") != null) {
      _activity.event(
        ActivityKind.signInRefused,
        "A WebDAV sign-in was refused: wrong name or password.",
        severity: ActivitySeverity.warning,
        address: request.remoteAddress,
        throttleKey: "davrefused|${request.remoteAddress}",
        throttleFor: const Duration(seconds: 10),
      );
    }
    return response;
  }

  Future<ApiResponse> handle(ApiRequest request) async {
    try {
      final DavAuthResult who = await _auth.authenticate(request);
      return switch (who) {
        DavAllowed(:final Account account) => await _allowed(request, account),
        DavUnauthorized() => _refused(
          request,
          const ApiResponse(
          HttpStatus.unauthorized,
          headers: <String, String>{HttpHeaders.wwwAuthenticateHeader: 'Basic realm="VaultBox", charset="UTF-8"'},
          ),
        ),
        DavThrottled(:final Duration retryAfter) => ApiResponse(
          HttpStatus.tooManyRequests,
          headers: <String, String>{"Retry-After": ((retryAfter.inMilliseconds + 999) ~/ 1000).toString()},
        ),
        DavBusy() => const ApiResponse(HttpStatus.serviceUnavailable, headers: <String, String>{"Retry-After": "2"}),
      };
    } on ApiReject catch (reject) {
      return reject.response;
    } on StorageFault catch (fault) {
      return _fault(fault);
    } on PermissionRevokedFailure {
      return const ApiResponse(HttpStatus.serviceUnavailable);
    } on StorageDisconnectedFailure {
      return const ApiResponse(HttpStatus.serviceUnavailable);
    } on NotEnoughSpaceFailure {
      return const ApiResponse(507);
    } on PathConflictFailure {
      return const ApiResponse(HttpStatus.preconditionFailed);
    } on InvalidOperationFailure {
      return const ApiResponse(HttpStatus.forbidden);
    } on PathTraversalRejectedFailure {
      return const ApiResponse(HttpStatus.badRequest);
    }
    // Anything else is unexpected: the router turns it into a bare 500.
  }

  static ApiResponse _fault(StorageFault fault) {
    return switch (fault.kind) {
      FaultKind.rootNotFound || FaultKind.notFound => const ApiResponse(HttpStatus.notFound),
      FaultKind.unavailable => const ApiResponse(HttpStatus.serviceUnavailable),
      FaultKind.readOnly || FaultKind.forbidden => const ApiResponse(HttpStatus.forbidden),
      FaultKind.invalidPath => const ApiResponse(HttpStatus.badRequest),
      FaultKind.notAFile || FaultKind.isADirectory => const ApiResponse(
        HttpStatus.methodNotAllowed,
        headers: <String, String>{HttpHeaders.allowHeader: allowedMethods},
      ),
      FaultKind.notADirectory || FaultKind.parentMissing || FaultKind.destinationMissing => const ApiResponse(
        HttpStatus.conflict,
      ),
      FaultKind.exists => const ApiResponse(HttpStatus.preconditionFailed),
      FaultKind.interrupted => const ApiResponse(HttpStatus.badRequest, closeConnection: true),
      FaultKind.rangeNotSatisfiable => ApiResponse(
        HttpStatus.requestedRangeNotSatisfiable,
        headers: <String, String>{"Content-Range": "bytes */${fault.size}"},
      ),
    };
  }

  Future<ApiResponse> _dispatch(ApiRequest request, Account account) async {
    final List<String> segments = request.segments.sublist(1); // after "dav"
    return switch (request.method) {
      "OPTIONS" => _options(),
      "PROPFIND" => await _propfind(request, account, segments),
      "PROPPATCH" => await _proppatch(request, account, segments),
      "GET" || "HEAD" => await _get(request, account, segments),
      "PUT" => await _put(request, account, segments),
      "MKCOL" => await _mkcol(request, account, segments),
      "DELETE" => await _deleteResource(request, account, segments),
      "COPY" => await _copyMove(request, account, segments, move: false),
      "MOVE" => await _copyMove(request, account, segments, move: true),
      "LOCK" => await _lock(request, account, segments),
      "UNLOCK" => await _unlock(request, account),
      _ => const ApiResponse(
        HttpStatus.methodNotAllowed,
        headers: <String, String>{HttpHeaders.allowHeader: allowedMethods},
      ),
    };
  }

  // ---------------------------------------------------------------- OPTIONS

  ApiResponse _options() => const ApiResponse(
    HttpStatus.ok,
    bytes: <int>[],
    headers: <String, String>{
      "DAV": "1, 2",
      "MS-Author-Via": "DAV",
      HttpHeaders.allowHeader: allowedMethods,
      "Accept-Ranges": "bytes",
    },
  );

  // ------------------------------------------------------------ resolution

  /// Roots by URL name. A root's URL name is its display name made URL-safe,
  /// with `-2`, `-3`… added when two roots would share one.
  Future<_Roots> _roots() async {
    final RootNames names = RootNames.of(await _gate.visibleRoots());
    return _Roots(names.bySlug, names.slugById);
  }

  /// Resolves URL segments (after `dav`) to a root + path, or the virtual top
  /// folder that lists the roots.
  Future<_Resolved> _resolve(_Roots roots, List<String> segments, {bool forWrite = false}) async {
    if (segments.isEmpty) return const _Resolved.top();
    final StorageRoot? known = roots.bySlug[segments.first.toLowerCase()];
    if (known == null) throw const StorageFault(FaultKind.rootNotFound);
    final StorageRoot root = await _gate.root(known.id, forWrite: forWrite);
    final StoragePath path = _gate.parse(root, "/${segments.skip(1).join("/")}");
    return _Resolved(root, path, roots.slugById[root.id]!);
  }

  /// Like [_resolve], but the target must be a real item inside a root (not the
  /// top folder and not a root itself).
  Future<_Resolved> _resolveItem(_Roots roots, List<String> segments, {bool forWrite = false}) async {
    final _Resolved target = await _resolve(roots, segments, forWrite: forWrite);
    if (target.isTop || target.path!.isRoot) throw const StorageFault(FaultKind.forbidden);
    return target;
  }

  static String _href(String? slug, StoragePath? path, {required bool collection}) {
    final List<String> parts = <String>[
      prefix,
      if (slug != null) slug,
      if (path != null) ...path.segments,
    ];
    return "/${parts.map(Uri.encodeComponent).join("/")}${collection ? "/" : ""}";
  }

  void _requireUnlocked(
    ApiRequest request,
    Account account,
    StorageRoot root,
    StoragePath path, {
    bool descendants = false,
  }) {
    final String key = DavLockManager.keyFor(root.id, path.normalized);
    final Set<String> presented = DavLockManager.tokensIn(request.header("if"));
    if (!_locks.mayModify(account.id, key, presented, includeDescendants: descendants)) {
      throw const ApiReject(ApiResponse(423));
    }
  }

  static String _etag(int? size, DateTime? modified) {
    final String stamp = modified == null ? "0" : modified.millisecondsSinceEpoch.toRadixString(16);
    return '"${size ?? 0}-$stamp"';
  }

  // ---------------------------------------------------------------- PROPFIND

  static const List<String> _knownProps = <String>[
    "resourcetype",
    "displayname",
    "getcontentlength",
    "getcontenttype",
    "getlastmodified",
    "creationdate",
    "getetag",
    "supportedlock",
    "lockdiscovery",
  ];

  static const String _supportedLockXml =
      "<D:supportedlock>"
      "<D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry>"
      "<D:lockentry><D:lockscope><D:shared/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry>"
      "</D:supportedlock>";

  Future<ApiResponse> _propfind(ApiRequest request, Account account, List<String> segments) async {
    final String depth = (request.header("depth") ?? "1").trim().toLowerCase();
    if (depth != "0" && depth != "1") {
      return ApiResponse(
        HttpStatus.forbidden,
        bytes: utf8.encode('<?xml version="1.0" encoding="utf-8"?><D:error xmlns:D="DAV:"><D:propfind-finite-depth/></D:error>'),
        contentType: _xmlType,
      );
    }
    final List<int> body = await _smallBody(request);
    final PropfindRequest query;
    try {
      query = parsePropfind(body);
    } on FormatException {
      return const ApiResponse(HttpStatus.badRequest);
    }

    final _Roots roots = await _roots();
    final _Resolved target = await _resolve(roots, segments);
    final MultiStatus out = MultiStatus();

    if (target.isTop) {
      out.response(_href(null, null, collection: true), _propstats(query, _DavResource.collection(displayName: "VaultBox")));
      if (depth == "1") {
        for (final StorageRoot root in roots.bySlug.values) {
          out.response(
            _href(roots.slugById[root.id], null, collection: true),
            _propstats(query, _rootResource(root)),
          );
        }
      }
      return _multiStatus(out);
    }

    final StorageRoot root = target.root!;
    final StoragePath path = target.path!;
    _gate.require(account, Permission.read, root, path);

    final bool isCollection;
    if (path.isRoot) {
      isCollection = true;
      out.response(_href(target.slug, path, collection: true), _propstats(query, _rootResource(root)));
    } else {
      final StorageEntry? entry = await _files.statEntry(FileRef(root: root, path: path));
      if (entry == null) return const ApiResponse(HttpStatus.notFound);
      isCollection = entry.isDirectory;
      out.response(_href(target.slug, path, collection: isCollection), _propstats(query, _entryResource(root, target.slug!, path, entry)));
    }

    if (isCollection && depth == "1") {
      int count = 0;
      await for (final StorageEntry child in _files.list(FileRef(root: root, path: path))) {
        if (path.isRoot && StorageGate.isReservedName(child.name)) continue;
        if (++count > maxListing) return const ApiResponse(507);
        final StoragePath childPath;
        try {
          childPath = path.child(child.name);
        } on AppFailure {
          continue; // a name that can't be represented safely is left out
        }
        if (!_gate.allows(account, Permission.read, root, childPath)) continue;
        out.response(
          _href(target.slug, childPath, collection: child.isDirectory),
          _propstats(query, _entryResource(root, target.slug!, childPath, child)),
        );
      }
    }
    return _multiStatus(out);
  }

  ApiResponse _multiStatus(MultiStatus out) => ApiResponse(207, bytes: out.toBytes(), contentType: _xmlType);

  _DavResource _rootResource(StorageRoot root) {
    final int? free = root.freeBytes;
    final int? total = root.totalBytes;
    return _DavResource.collection(
      displayName: root.displayName,
      quotaAvailable: free,
      quotaUsed: (free != null && total != null && total >= free) ? total - free : null,
    );
  }

  _DavResource _entryResource(StorageRoot root, String slug, StoragePath path, StorageEntry entry) {
    return _DavResource(
      displayName: entry.name,
      isCollection: entry.isDirectory,
      size: entry.sizeBytes,
      modified: entry.modifiedAt,
      mimeType: entry.isDirectory ? null : (entry.mimeType ?? MimeTypes.forName(entry.name)),
      lockKey: DavLockManager.keyFor(root.id, path.normalized),
      lockRootHref: _href(slug, path, collection: entry.isDirectory),
    );
  }

  List<PropStat> _propstats(PropfindRequest query, _DavResource resource) {
    final List<String> found = <String>[];
    final List<String> missing = <String>[];

    switch (query.mode) {
      case PropfindMode.propname:
        for (final String name in _knownProps) {
          found.add("<D:$name/>");
        }
      case PropfindMode.allprop:
        for (final String name in _knownProps) {
          final String? xml = _renderProp(DavProp.dav(name), resource);
          if (xml != null) found.add(xml);
        }
      case PropfindMode.prop:
        for (final DavProp prop in query.props) {
          final String? xml = _renderProp(prop, resource);
          if (xml != null) {
            found.add(xml);
          } else {
            final String? empty = emptyPropXml(prop);
            if (empty != null) missing.add(empty);
          }
        }
    }
    return <PropStat>[
      if (found.isNotEmpty) PropStat(200, found),
      if (missing.isNotEmpty) PropStat(404, missing),
    ];
  }

  String? _renderProp(DavProp prop, _DavResource r) {
    if (!prop.isDav) return null;
    switch (prop.name) {
      case "resourcetype":
        return r.isCollection ? "<D:resourcetype><D:collection/></D:resourcetype>" : "<D:resourcetype/>";
      case "displayname":
        return "<D:displayname>${xmlEscape(r.displayName)}</D:displayname>";
      case "getcontentlength":
        return (r.isCollection || r.size == null) ? null : "<D:getcontentlength>${r.size}</D:getcontentlength>";
      case "getcontenttype":
        return r.mimeType == null ? null : "<D:getcontenttype>${xmlEscape(r.mimeType!)}</D:getcontenttype>";
      case "getlastmodified":
        return r.modified == null ? null : "<D:getlastmodified>${HttpDate.format(r.modified!.toUtc())}</D:getlastmodified>";
      case "creationdate":
        return r.modified == null
            ? null
            : "<D:creationdate>${r.modified!.toUtc().toIso8601String().split(".").first}Z</D:creationdate>";
      case "getetag":
        return r.isCollection ? null : "<D:getetag>${xmlEscape(_etag(r.size, r.modified))}</D:getetag>";
      case "supportedlock":
        return _supportedLockXml;
      case "lockdiscovery":
        final String key = r.lockKey ?? "";
        final List<DavLock> active = key.isEmpty ? const <DavLock>[] : _locks.locksOn(key);
        return "<D:lockdiscovery>${active.map((DavLock l) => _activeLockXml(l, r.lockRootHref ?? "")).join()}</D:lockdiscovery>";
      case "quota-available-bytes":
        return r.quotaAvailable == null ? null : "<D:quota-available-bytes>${r.quotaAvailable}</D:quota-available-bytes>";
      case "quota-used-bytes":
        return r.quotaUsed == null ? null : "<D:quota-used-bytes>${r.quotaUsed}</D:quota-used-bytes>";
    }
    return null;
  }

  static String _activeLockXml(DavLock lock, String lockRootHref) {
    final String scope = lock.scope == DavLockScope.exclusive ? "exclusive" : "shared";
    return "<D:activelock>"
        "<D:locktype><D:write/></D:locktype>"
        "<D:lockscope><D:$scope/></D:lockscope>"
        "<D:depth>${lock.depthInfinity ? "infinity" : "0"}</D:depth>"
        "<D:owner>${xmlEscape(lock.owner)}</D:owner>"
        "<D:timeout>Second-${lock.timeout.inSeconds}</D:timeout>"
        "<D:locktoken><D:href>${xmlEscape(lock.token)}</D:href></D:locktoken>"
        "<D:lockroot><D:href>${xmlEscape(lockRootHref)}</D:href></D:lockroot>"
        "</D:activelock>";
  }

  Future<List<int>> _smallBody(ApiRequest request) async {
    final List<int>? body = await request.readBounded(maxBodyBytes);
    if (body == null) {
      throw const ApiReject(ApiResponse(HttpStatus.requestEntityTooLarge, closeConnection: true));
    }
    return body;
  }

  // --------------------------------------------------------------- PROPPATCH

  Future<ApiResponse> _proppatch(ApiRequest request, Account account, List<String> segments) async {
    final List<int> body = await _smallBody(request);
    final List<DavProp> props;
    try {
      props = parsePropertyUpdate(body);
    } on FormatException {
      return const ApiResponse(HttpStatus.badRequest);
    }

    final _Roots roots = await _roots();
    final _Resolved target = await _resolveItem(roots, segments, forWrite: true);
    final StorageRoot root = target.root!;
    final StoragePath path = target.path!;
    _gate.require(account, Permission.write, root, path);
    _requireUnlocked(request, account, root, path);
    final StorageEntry? entry = await _files.statEntry(FileRef(root: root, path: path));
    if (entry == null) return const ApiResponse(HttpStatus.notFound);

    // Nothing is stored. Microsoft's Win32* timestamps/attributes are cosmetic
    // hints Windows sends after every copy, and it is content with "accepted";
    // every other property is refused honestly.
    final List<String> accepted = <String>[];
    final List<String> refused = <String>[];
    for (final DavProp prop in props) {
      final String? xml = emptyPropXml(prop);
      if (xml == null) continue;
      if (prop.namespace.startsWith("urn:schemas-microsoft-com:")) {
        accepted.add(xml);
      } else {
        refused.add(xml);
      }
    }
    final MultiStatus out = MultiStatus()
      ..response(_href(target.slug, path, collection: entry.isDirectory), <PropStat>[
        if (accepted.isNotEmpty) PropStat(200, accepted),
        if (refused.isNotEmpty) PropStat(403, refused),
      ]);
    return _multiStatus(out);
  }

  // --------------------------------------------------------------------- GET

  Future<ApiResponse> _get(ApiRequest request, Account account, List<String> segments) async {
    final _Roots roots = await _roots();
    final _Resolved target = await _resolve(roots, segments);
    if (target.isTop) return _collectionNote(request);

    final StorageRoot root = target.root!;
    final StoragePath path = target.path!;
    _gate.require(account, Permission.read, root, path);
    if (path.isRoot) return _collectionNote(request);

    final DownloadPlan plan;
    try {
      plan = await _transfer.planDownload(root, path, rangeHeader: request.header("range"));
    } on StorageFault catch (fault) {
      if (fault.kind == FaultKind.notAFile) return _collectionNote(request);
      rethrow;
    }

    final DateTime? modified = plan.entry.modifiedAt;
    Stream<List<int>> body = request.method == "HEAD" ? Stream<List<int>>.empty() : plan.open();
    if (request.method == "GET" && (plan.range == null || plan.range!.start == 0)) {
      body = _activity
          .transfer(
            direction: TransferDirection.download,
            via: AccessVia.webdav,
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
        "Accept-Ranges": plan.canRange ? "bytes" : "none",
        if (plan.contentRange != null) "Content-Range": plan.contentRange!,
        "ETag": _etag(plan.totalSize, modified),
        if (modified != null) "Last-Modified": HttpDate.format(modified.toUtc()),
        // A file must never be able to act as the server if a browser opens it.
        "Content-Security-Policy": "sandbox; default-src 'none'; style-src 'unsafe-inline'",
        "Content-Disposition": "attachment",
      },
    );
  }

  ApiResponse _collectionNote(ApiRequest request) {
    final List<int> text = utf8.encode("This is a VaultBox WebDAV folder. Mount it as a network drive to browse it.\n");
    return ApiResponse(
      HttpStatus.ok,
      bytes: request.method == "HEAD" ? const <int>[] : text,
      contentType: "text/plain; charset=utf-8",
    );
  }

  // --------------------------------------------------------------------- PUT

  Future<ApiResponse> _put(ApiRequest request, Account account, List<String> segments) async {
    final _Roots roots = await _roots();
    final _Resolved target = await _resolveItem(roots, segments, forWrite: true);
    final StorageRoot root = target.root!;
    final StoragePath path = target.path!;
    _gate.require(account, Permission.write, root, path);
    _requireUnlocked(request, account, root, path);

    if (request.header("if-none-match")?.trim() == "*" &&
        await _files.statEntry(FileRef(root: root, path: path)) != null) {
      return const ApiResponse(HttpStatus.preconditionFailed);
    }

    final TransferMeter meter = _activity.transfer(
      direction: TransferDirection.upload,
      via: AccessVia.webdav,
      actor: account.username,
      name: path.name,
      totalBytes: request.contentLength >= 0 ? request.contentLength : null,
    );
    final UploadResult result = await meter.upload(
      request.bodyStream,
      (Stream<List<int>> counted) => _transfer.receive(root, path, counted, overwrite: true),
    );
    return ApiResponse(result.created ? HttpStatus.created : HttpStatus.noContent);
  }

  // ------------------------------------------------------------------- MKCOL

  Future<ApiResponse> _mkcol(ApiRequest request, Account account, List<String> segments) async {
    if (request.contentLength > 0) return const ApiResponse(HttpStatus.unsupportedMediaType);

    final _Roots roots = await _roots();
    final _Resolved target = await _resolveItem(roots, segments, forWrite: true);
    final StorageRoot root = target.root!;
    final StoragePath path = target.path!;
    _gate.require(account, Permission.write, root, path);
    _requireUnlocked(request, account, root, path);

    await _transfer.requireDirectory(FileRef(root: root, path: path.parent), FaultKind.parentMissing);
    if (await _files.statEntry(FileRef(root: root, path: path)) != null) {
      return const ApiResponse(
        HttpStatus.methodNotAllowed,
        headers: <String, String>{HttpHeaders.allowHeader: allowedMethods},
      );
    }
    await _files.createDirectory(FileRef(root: root, path: path.parent), path.name);
    return const ApiResponse(HttpStatus.created);
  }

  // ------------------------------------------------------------------ DELETE

  Future<ApiResponse> _deleteResource(ApiRequest request, Account account, List<String> segments) async {
    final _Roots roots = await _roots();
    final _Resolved target = await _resolveItem(roots, segments, forWrite: true);
    final StorageRoot root = target.root!;
    final StoragePath path = target.path!;
    _gate.require(account, Permission.delete, root, path);
    _requireUnlocked(request, account, root, path, descendants: true);

    final FileRef ref = FileRef(root: root, path: path);
    if (await _files.statEntry(ref) == null) return const ApiResponse(HttpStatus.notFound);

    final OperationBatch batch = await _delete(sources: <FileRef>[ref]);
    return batch.allCompleted ? const ApiResponse(HttpStatus.noContent) : const ApiResponse(HttpStatus.internalServerError);
  }

  // ------------------------------------------------------------- COPY / MOVE

  static List<String>? _destinationSegments(String? header) {
    if (header == null) return null;
    final Uri? uri = Uri.tryParse(header.trim());
    if (uri == null) return null;
    final List<String> segments = uri.pathSegments.where((String s) => s.isNotEmpty).toList();
    if (segments.isEmpty || segments.first != prefix) return null;
    return segments.sublist(1);
  }

  Future<ApiResponse> _copyMove(
    ApiRequest request,
    Account account,
    List<String> segments, {
    required bool move,
  }) async {
    final List<String>? destinationSegments = _destinationSegments(request.header("destination"));
    if (destinationSegments == null) return const ApiResponse(HttpStatus.badRequest);
    final bool overwrite = (request.header("overwrite") ?? "T").trim().toUpperCase() != "F";

    final _Roots roots = await _roots();
    final _Resolved source = await _resolveItem(roots, segments, forWrite: move);
    final _Resolved destination = await _resolveItem(roots, destinationSegments, forWrite: true);
    final StorageRoot sourceRoot = source.root!;
    final StorageRoot destinationRoot = destination.root!;
    final StoragePath sourcePath = source.path!;
    final StoragePath destinationPath = destination.path!;

    _gate.require(account, Permission.read, sourceRoot, sourcePath);
    if (move) _gate.require(account, Permission.delete, sourceRoot, sourcePath);
    _gate.require(account, Permission.write, destinationRoot, destinationPath);
    if (move) _requireUnlocked(request, account, sourceRoot, sourcePath, descendants: true);
    _requireUnlocked(request, account, destinationRoot, destinationPath);

    // Onto itself, or a folder into its own subtree.
    if (sourceRoot.id == destinationRoot.id && destinationPath.isDescendantOfOrEqualTo(sourcePath)) {
      return const ApiResponse(HttpStatus.forbidden);
    }

    final FileRef sourceRef = FileRef(root: sourceRoot, path: sourcePath);
    final FileRef destinationRef = FileRef(root: destinationRoot, path: destinationPath);

    final StorageEntry? sourceEntry = await _files.statEntry(sourceRef);
    if (sourceEntry == null) return const ApiResponse(HttpStatus.notFound);

    await _transfer.requireDirectory(
      FileRef(root: destinationRoot, path: destinationPath.parent),
      FaultKind.parentMissing,
    );
    final StorageEntry? existing = await _files.statEntry(destinationRef);
    if (existing != null && !overwrite) return const ApiResponse(HttpStatus.preconditionFailed);

    WriteMode mode = WriteMode.create;
    if (existing != null) {
      if (!existing.isDirectory && !sourceEntry.isDirectory) {
        mode = WriteMode.replace; // one file over another: replaced in place
      } else {
        // A folder is involved: keep what was there in the Recycle Bin first.
        final OperationBatch recycled = await _delete(sources: <FileRef>[destinationRef]);
        if (!recycled.allCompleted) return const ApiResponse(HttpStatus.internalServerError);
      }
    }

    if (move) {
      final bool sameFolder = sourceRoot.id == destinationRoot.id && sourcePath.parent == destinationPath.parent;
      if (sameFolder && existing == null) {
        await _files.renameSingle(sourceRef, destinationPath.name);
      } else {
        await _files.copySingle(sourceRef, destinationRef, mode: mode);
        await _files.deletePermanently(sourceRef);
      }
    } else if (sourceEntry.isDirectory && (request.header("depth") ?? "infinity").trim() == "0") {
      await _files.createDirectory(FileRef(root: destinationRoot, path: destinationPath.parent), destinationPath.name);
    } else {
      await _files.copySingle(sourceRef, destinationRef, mode: mode);
    }
    return ApiResponse(existing == null ? HttpStatus.created : HttpStatus.noContent);
  }

  // -------------------------------------------------------------- LOCK/UNLOCK

  Future<ApiResponse> _lock(ApiRequest request, Account account, List<String> segments) async {
    final List<int> body = await _smallBody(request);
    final Duration? requested = DavLockManager.parseTimeout(request.header("timeout"));

    final _Roots roots = await _roots();
    final _Resolved target = await _resolveItem(roots, segments, forWrite: true);
    final StorageRoot root = target.root!;
    final StoragePath path = target.path!;
    _gate.require(account, Permission.write, root, path);
    final String key = DavLockManager.keyFor(root.id, path.normalized);

    DavLock? lock;
    bool createdFile = false;

    if (body.isEmpty || utf8.decode(body).trim().isEmpty) {
      // A refresh: the lock to extend is named in the If header.
      for (final String token in DavLockManager.tokensIn(request.header("if"))) {
        lock = _locks.refresh(token, account.id, requested: requested);
        if (lock != null) break;
      }
      if (lock == null) return const ApiResponse(HttpStatus.preconditionFailed);
    } else {
      final LockRequest info;
      try {
        info = parseLockInfo(body);
      } on FormatException {
        return const ApiResponse(HttpStatus.badRequest);
      }
      final bool depthInfinity = (request.header("depth") ?? "infinity").trim() != "0";
      final DavLock? made = _locks.create(
        accountId: account.id,
        resourceKey: key,
        depthInfinity: depthInfinity,
        scope: info.scope,
        owner: info.owner,
        requested: requested,
      );
      if (made == null) return const ApiResponse(423);
      lock = made;

      // Locking a name that doesn't exist yet reserves it as an empty file.
      final FileRef ref = FileRef(root: root, path: path);
      try {
        if (await _files.statEntry(ref) == null) {
          await _transfer.receive(root, path, Stream<List<int>>.empty(), overwrite: false);
          createdFile = true;
        }
      } on Object {
        _locks.unlock(made.token, account.id);
        rethrow;
      }
    }

    final DavLock held = lock;
    final String xml =
        '<?xml version="1.0" encoding="utf-8"?><D:prop xmlns:D="DAV:"><D:lockdiscovery>'
        "${_activeLockXml(held, _href(target.slug, path, collection: false))}"
        "</D:lockdiscovery></D:prop>";
    return ApiResponse(
      createdFile ? HttpStatus.created : HttpStatus.ok,
      bytes: utf8.encode(xml),
      contentType: _xmlType,
      headers: <String, String>{"Lock-Token": "<${held.token}>"},
    );
  }

  Future<ApiResponse> _unlock(ApiRequest request, Account account) async {
    final String? header = request.header("lock-token");
    if (header == null) return const ApiResponse(HttpStatus.badRequest);
    final String token = header.trim().replaceAll(RegExp(r"^<|>$"), "");
    return _locks.unlock(token, account.id) ? const ApiResponse(HttpStatus.noContent) : const ApiResponse(HttpStatus.conflict);
  }
}

/// Roots keyed by lower-cased URL name, and each root's URL name by id.
final class _Roots {
  const _Roots(this.bySlug, this.slugById);

  final Map<String, StorageRoot> bySlug;
  final Map<String, String> slugById;
}

/// What a URL points at: the top folder (which lists the roots), or a path in a root.
final class _Resolved {
  const _Resolved(StorageRoot this.root, StoragePath this.path, String this.slug);

  const _Resolved.top() : root = null, path = null, slug = null;

  final StorageRoot? root;
  final StoragePath? path;
  final String? slug;

  bool get isTop => root == null;
}

/// One resource's worth of property values.
final class _DavResource {
  const _DavResource({
    required this.displayName,
    required this.isCollection,
    this.size,
    this.modified,
    this.mimeType,
    this.lockKey,
    this.lockRootHref,
  }) : quotaAvailable = null,
       quotaUsed = null;

  const _DavResource.collection({required this.displayName, this.quotaAvailable, this.quotaUsed})
    : isCollection = true,
      size = null,
      modified = null,
      mimeType = null,
      lockKey = null,
      lockRootHref = null;

  final String displayName;
  final bool isCollection;
  final int? size;
  final DateTime? modified;
  final String? mimeType;
  final int? quotaAvailable;
  final int? quotaUsed;
  final String? lockKey;
  final String? lockRootHref;
}
