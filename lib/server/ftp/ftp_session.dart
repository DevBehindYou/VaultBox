import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:math";
import "dart:typed_data";

import "../../core/errors/app_failure.dart";
import "../../domain/entities/account.dart";
import "../../domain/entities/activity.dart";
import "../../domain/entities/ftp_settings.dart";
import "../../domain/entities/storage_root.dart";
import "../../domain/models/file_ref.dart";
import "../../domain/models/operation_batch.dart";
import "../../domain/security/authorizer.dart";
import "../../domain/value_objects/storage_entry.dart";
import "../../domain/value_objects/storage_path.dart";
import "../../domain/value_objects/write_mode.dart";
import "../activity/activity_log.dart";
import "../api/api_types.dart";
import "../files/file_transfer.dart";
import "../files/root_names.dart";
import "../files/storage_gate.dart";
import "../webdav/dav_auth.dart";
import "ftp_deps.dart";
import "ftp_listing.dart";
import "ftp_paths.dart";

/// Where a path in the FTP tree points: the top (the list of storage
/// locations), or an item inside one of them.
final class _Target {
  const _Target.top(this.segments) : root = null, path = null, rootName = null;

  const _Target(this.segments, StorageRoot this.root, StoragePath this.path, String this.rootName);

  final List<String> segments;
  final StorageRoot? root;
  final StoragePath? path;
  final String? rootName;

  bool get isTop => root == null;
  bool get isRootFolder => path != null && path!.isRoot;

  FileRef get ref => FileRef(root: root!, path: path!);
}

/// A listening socket waiting for the client to open the data connection.
final class _Passive {
  _Passive(this.server, this.connection, this.port);

  final ServerSocket server;
  final Future<Socket> connection;
  final int port;
}

/// One client's control connection: reads commands, answers them, and opens a
/// data connection for each listing or file transfer.
///
/// Commands are handled one at a time. Everything that touches storage goes
/// through [StorageGate] and [FileTransfer], as the web API and WebDAV do.
/// Active mode (`PORT`) is refused: it lets a client point the phone at some
/// other machine, and passive mode does everything a modern client needs.
final class FtpSession {
  FtpSession({
    required Socket socket,
    required FtpDeps deps,
    required FtpSettings settings,
    required SecurityContext? tls,
    required FtpLimits limits,
    required bool tlsActive,
    required DateTime Function() now,
    Random? random,
  }) : _control = socket,
       _deps = deps,
       _settings = settings,
       _tls = tls,
       _limits = limits,
       _tlsActive = tlsActive,
       _now = now,
       _transfer = FileTransfer(deps.files),
       _random = random ?? Random.secure(),
       _peer = socket.remoteAddress.address;

  Socket _control;
  final FtpDeps _deps;
  final FtpSettings _settings;
  final SecurityContext? _tls;
  final FtpLimits _limits;
  final DateTime Function() _now;
  final FileTransfer _transfer;
  final Random _random;
  final String _peer;

  final Completer<void> _done = Completer<void>();
  // Uint8List (not the wider List<int>) so this can be handed straight to
  // SecureSocket.secureServer's `subscription:` parameter during the TLS
  // upgrade in _auth() below.
  StreamSubscription<Uint8List>? _subscription;
  Timer? _idle;
  bool _closed = false;
  bool _pumping = false;
  bool _transferring = false;

  final List<int> _pending = <int>[];
  final List<List<int>> _lines = <List<int>>[];

  bool _tlsActive;
  bool _dataProtected = false;
  Account? _account;
  String? _pendingUser;
  int _failedLogins = 0;
  List<String> _cwd = <String>[];
  _Passive? _passive;
  int _restartAt = 0;
  _Target? _renameFrom;

  /// Completes when the connection has ended.
  Future<void> get done => _done.future;

  bool get _mustUseTls => _settings.usesTls;

  /// Starts the conversation.
  void start() {
    _reply(220, "VaultBox FTP server ready.");
    _listen();
    _touch();
  }

  /// Closes the connection now (the server is stopping).
  void close() => _close();

  // ------------------------------------------------------------- plumbing

  void _listen() {
    _subscription = _control.listen(
      _onData,
      onError: (Object error) => _close(),
      onDone: _close,
      cancelOnError: true,
    );
  }

  void _touch() {
    _idle?.cancel();
    _idle = Timer(_limits.idleTimeout, () {
      if (_closed) return;
      if (_transferring) {
        _touch();
        return;
      }
      _reply(421, "No command for too long. Goodbye.");
      _close();
    });
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _idle?.cancel();
    final _Passive? passive = _passive;
    _passive = null;
    if (passive != null) unawaited(passive.server.close().then<void>((_) {}, onError: (Object _) {}));
    unawaited(_subscription?.cancel());
    try {
      _control.destroy();
    } on Object {
      // already gone
    }
    if (!_done.isCompleted) _done.complete();
  }

  void _reply(int code, String text) {
    if (_closed) return;
    try {
      _control.add(utf8.encode("$code $text\r\n"));
    } on Object {
      _close();
    }
  }

  void _replyLines(int code, String first, List<String> middle, String last) {
    if (_closed) return;
    final StringBuffer out = StringBuffer("$code-$first\r\n");
    for (final String line in middle) {
      out.write(" $line\r\n");
    }
    out.write("$code $last\r\n");
    try {
      _control.add(utf8.encode(out.toString()));
    } on Object {
      _close();
    }
  }

  void _onData(List<int> chunk) {
    _pending.addAll(chunk);
    while (true) {
      final int newline = _pending.indexOf(10);
      if (newline == -1) {
        if (_pending.length > _limits.maxCommandBytes) {
          _reply(500, "Command too long.");
          _close();
        }
        break;
      }
      List<int> line = _pending.sublist(0, newline);
      _pending.removeRange(0, newline + 1);
      if (line.isNotEmpty && line.last == 13) line = line.sublist(0, line.length - 1);
      if (line.length > _limits.maxCommandBytes) {
        _reply(500, "Command too long.");
        _close();
        return;
      }
      _lines.add(line);
    }
    if (_lines.length > 100) {
      _reply(421, "Too many commands at once.");
      _close();
      return;
    }
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_lines.isNotEmpty && !_closed) {
        final List<int> bytes = _lines.removeAt(0);
        _touch();
        await _handleLine(bytes);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _handleLine(List<int> raw) async {
    // Some clients send Telnet control bytes in front of ABOR and friends.
    int from = 0;
    while (from < raw.length && raw[from] >= 0xF0) {
      from++;
    }
    final String line;
    try {
      line = utf8.decode(raw.sublist(from));
    } on FormatException {
      _reply(501, "That isn't valid text.");
      return;
    }
    if (line.trim().isEmpty) return;

    final int space = line.indexOf(" ");
    final String command = (space == -1 ? line : line.substring(0, space)).toUpperCase();
    final String? argument = ftpArgument(line);

    try {
      await _dispatch(command, argument);
    } on StorageFault catch (fault) {
      _replyFault(fault);
    } on PathTraversalRejectedFailure {
      _reply(550, "That name isn't allowed.");
    } on NotEnoughSpaceFailure {
      _reply(552, "There isn't enough space.");
    } on PermissionRevokedFailure {
      _reply(450, "The storage isn't available right now.");
    } on StorageDisconnectedFailure {
      _reply(450, "The storage isn't available right now.");
    } on PathConflictFailure {
      _reply(553, "Something with that name already exists.");
    } on AppFailure catch (failure) {
      _reply(550, failure.message);
    } on SocketException {
      _close();
    } on Object {
      _reply(451, "Something went wrong. Try again.");
    }
  }

  void _replyFault(StorageFault fault) {
    switch (fault.kind) {
      case FaultKind.forbidden:
        _reply(550, "Permission denied.");
      case FaultKind.readOnly:
        _reply(550, "This storage is read-only.");
      case FaultKind.unavailable:
        _reply(450, "The storage isn't available right now.");
      case FaultKind.interrupted:
        _reply(426, "The transfer was interrupted.");
      default:
        _reply(550, "No such file or folder.");
    }
  }

  // ------------------------------------------------------------- dispatch

  static const Set<String> _beforeLogin = <String>{
    "USER", "PASS", "AUTH", "PBSZ", "PROT", "FEAT", "SYST", "OPTS", "QUIT", "NOOP", "HELP", "CLNT", "LANG",
  };

  Future<void> _dispatch(String command, String? argument) async {
    if (!_beforeLogin.contains(command) && _account == null) {
      _reply(530, "Please sign in with USER and PASS.");
      return;
    }
    switch (command) {
      case "USER":
        return _user(argument);
      case "PASS":
        return _pass(argument ?? "");
      case "AUTH":
        return _auth(argument);
      case "PBSZ":
        return _pbsz();
      case "PROT":
        return _prot(argument);
      case "SYST":
        _reply(215, "UNIX Type: L8");
      case "FEAT":
        _feat();
      case "OPTS":
        _opts(argument);
      case "NOOP":
      case "ALLO":
        _reply(200, "OK.");
      case "CLNT":
      case "LANG":
        _reply(200, "Noted.");
      case "HELP":
        _reply(214, "VaultBox FTP server. Use PASV or EPSV for transfers.");
      case "QUIT":
        _reply(221, "Goodbye.");
        try {
          await _control.flush();
        } on Object {
          // closing anyway
        }
        _close();
      case "PWD":
      case "XPWD":
        _reply(257, "${quoteFtpPath(formatFtpPath(_cwd))} is the current folder.");
      case "CWD":
      case "XCWD":
        return _cwdTo(argument ?? "/");
      case "CDUP":
      case "XCUP":
        return _cwdTo("..");
      case "TYPE":
        _reply(200, "Type set. Files are always sent as they are.");
      case "MODE":
        _reply((argument ?? "").toUpperCase() == "S" ? 200 : 504, (argument ?? "").toUpperCase() == "S" ? "Stream mode." : "Only stream mode is supported.");
      case "STRU":
        _reply((argument ?? "").toUpperCase() == "F" ? 200 : 504, (argument ?? "").toUpperCase() == "F" ? "File structure." : "Only file structure is supported.");
      case "PASV":
        return _pasv();
      case "EPSV":
        return _epsv(argument);
      case "PORT":
      case "EPRT":
        _reply(502, "Active mode is off. Use passive mode (PASV or EPSV).");
      case "LIST":
      case "NLST":
      case "MLSD":
        return _list(command, argument);
      case "MLST":
        return _mlst(argument);
      case "RETR":
        return _retr(argument);
      case "STOR":
        return _stor(argument);
      case "APPE":
        _reply(502, "Appending isn't supported. Upload the whole file instead.");
      case "REST":
        _rest(argument);
      case "DELE":
        return _delete(argument, folder: false);
      case "RMD":
      case "XRMD":
        return _delete(argument, folder: true);
      case "MKD":
      case "XMKD":
        return _mkd(argument);
      case "RNFR":
        return _rnfr(argument);
      case "RNTO":
        return _rnto(argument);
      case "SIZE":
        return _size(argument);
      case "MDTM":
        return _mdtm(argument);
      case "STAT":
        _reply(211, "VaultBox FTP server. Signed in as ${_account!.username}.");
      case "ABOR":
        _reply(226, "Nothing to abort.");
      default:
        _reply(500, "That command isn't understood.");
    }
  }

  // ---------------------------------------------------------------- login

  Future<void> _user(String? name) async {
    if (name == null) {
      _reply(501, "Say who you are: USER name.");
      return;
    }
    if (_mustUseTls && !_tlsActive) {
      _reply(530, "This server needs a secure connection. Send AUTH TLS first.");
      return;
    }
    _account = null;
    _pendingUser = name;
    _reply(331, "Password required.");
  }

  Future<void> _pass(String password) async {
    final String? user = _pendingUser;
    if (user == null) {
      _reply(503, "Send USER first.");
      return;
    }
    if (_mustUseTls && !_tlsActive) {
      _reply(530, "This server needs a secure connection. Send AUTH TLS first.");
      return;
    }
    _pendingUser = null;

    final DavAuthResult result = await _deps.auth.authenticate(
      ApiRequest(
        method: "FTP",
        segments: const <String>[],
        query: const <String, String>{},
        remoteAddress: _peer,
        headers: <String, String>{"authorization": "Basic ${base64.encode(utf8.encode("$user:$password"))}"},
      ),
    );
    switch (result) {
      case DavAllowed(:final Account account):
        _account = account;
        _failedLogins = 0;
        _deps.activity.event(
          ActivityKind.signedIn,
          "${account.username} signed in over FTP.",
          actor: account.username,
          address: _peer,
        );
        _deps.activity.seen(actor: account.username, address: _peer, via: AccessVia.ftp);
        _reply(230, "Signed in.");
      case DavUnauthorized():
        _failedLogins++;
        _deps.activity.event(
          ActivityKind.signInRefused,
          "An FTP sign-in was refused: wrong name or password.",
          severity: ActivitySeverity.warning,
          address: _peer,
          throttleKey: "ftprefused|$_peer",
          throttleFor: const Duration(seconds: 10),
        );
        await Future<void>.delayed(_limits.failedLoginDelay);
        if (_failedLogins >= _limits.maxFailedLogins) {
          _reply(421, "Too many wrong passwords. Goodbye.");
          _close();
        } else {
          _reply(530, "Sign-in failed.");
        }
      case DavThrottled(:final Duration retryAfter):
        _reply(421, "Too many attempts. Try again in ${(retryAfter.inMilliseconds / 1000).ceil()} seconds.");
        _close();
      case DavBusy():
        _reply(421, "The server is busy. Try again in a moment.");
        _close();
    }
  }

  // ------------------------------------------------------------------ TLS

  Future<void> _auth(String? mechanism) async {
    final String kind = (mechanism ?? "").toUpperCase();
    if (kind != "TLS" && kind != "SSL" && kind != "TLS-C" && kind != "TLS-P") {
      _reply(504, "That security mechanism isn't supported.");
      return;
    }
    final SecurityContext? tls = _tls;
    if (!_settings.usesTls || tls == null) {
      _reply(534, "TLS isn't available on this server.");
      return;
    }
    if (_tlsActive) {
      _reply(503, "This connection is already secure.");
      return;
    }

    // Pause the control-socket subscription BEFORE replying: once the client
    // sees "234" it may send its TLS ClientHello immediately, and those bytes
    // must reach the TLS handshake, never the plain-text command parser in
    // _onData. Pausing after the reply (as this used to) leaves a window —
    // the `await _control.flush()` below yields to the event loop — where an
    // already-arrived ClientHello could be delivered to _onData first.
    final StreamSubscription<Uint8List>? old = _subscription;
    old?.pause();

    _reply(234, "Starting TLS.");
    await _control.flush();

    SecureSocket secure;
    try {
      // `subscription: old` hands the still-open (paused) subscription to the
      // handshake: `_control` already has a listener attached (it is a
      // single-subscription stream), so secureServer must reuse it rather
      // than trying to listen() again, which would throw.
      //
      // Known gap (acceptable per docs/TASKS.md): if the handshake itself
      // hangs, `.timeout()` only makes THIS call give up — it can't cancel
      // the handshake running underneath, so the socket lives until the
      // client goes away or the idle timer elsewhere closes it.
      secure = await SecureSocket.secureServer(_control, tls, subscription: old).timeout(_limits.tlsHandshakeTimeout);
    } on Object {
      _close();
      return;
    }
    _control = secure;
    // secureServer took ownership of `old` to read the handshake bytes; it
    // must not be cancelled separately (that would tear down the new
    // SecureSocket's own input).
    _subscription = null;
    _tlsActive = true;
    _account = null;
    _pendingUser = null;
    _dataProtected = false;
    _pending.clear();
    _lines.clear();
    _listen();
  }

  void _pbsz() {
    if (!_tlsActive) {
      _reply(503, "Send AUTH TLS first.");
      return;
    }
    _reply(200, "PBSZ=0");
  }

  void _prot(String? level) {
    if (!_tlsActive) {
      _reply(503, "Send AUTH TLS first.");
      return;
    }
    switch ((level ?? "").toUpperCase()) {
      case "P":
        _dataProtected = true;
        _reply(200, "File transfers will be encrypted.");
      case "C":
        _reply(534, "Unencrypted file transfers aren't allowed here.");
      default:
        _reply(504, "Use PROT P.");
    }
  }

  void _feat() {
    _replyLines(211, "Features:", <String>[
      "UTF8",
      "MLST type*;size*;modify*;perm*;",
      "MLSD",
      "SIZE",
      "MDTM",
      "REST STREAM",
      "PASV",
      "EPSV",
      if (_settings.usesTls && _tls != null) ...<String>["AUTH TLS", "PBSZ", "PROT"],
    ], "End");
  }

  void _opts(String? argument) {
    final String text = (argument ?? "").toUpperCase();
    if (text == "UTF8 ON" || text == "UTF8 OFF" || text.startsWith("MLST")) {
      _reply(200, "OK.");
    } else {
      _reply(501, "That option isn't supported.");
    }
  }

  // ----------------------------------------------------------- resolution

  Future<_Target> _resolve(String? argument, {bool forWrite = false}) async {
    final List<String> segments = resolveFtpPath(_cwd, argument ?? "");
    if (segments.isEmpty) return const _Target.top(<String>[]);

    final RootNames names = RootNames.of(await _deps.gate.visibleRoots());
    final StorageRoot? known = names.byName(segments.first);
    if (known == null) throw const StorageFault(FaultKind.rootNotFound);
    final StorageRoot root = await _deps.gate.root(known.id, forWrite: forWrite);

    StoragePath path = StoragePath.root(root.id);
    for (final String segment in segments.skip(1)) {
      path = path.child(segment);
    }
    if (StorageGate.isReserved(path)) throw const StorageFault(FaultKind.notFound);
    return _Target(segments, root, path, names.nameOf(root.id)!);
  }

  /// The item itself, not the top and not a whole storage location.
  Future<_Target> _resolveItem(String? argument, {bool forWrite = false}) async {
    final _Target target = await _resolve(argument, forWrite: forWrite);
    if (target.isTop || target.isRootFolder) throw const StorageFault(FaultKind.forbidden);
    return target;
  }

  Account get _who => _account!;

  // ------------------------------------------------------------ navigation

  Future<void> _cwdTo(String argument) async {
    final _Target target = await _resolve(argument);
    if (target.isTop) {
      _cwd = <String>[];
      _reply(250, "Now in /.");
      return;
    }
    _deps.gate.require(_who, Permission.read, target.root!, target.path!);
    if (!target.isRootFolder) {
      final StorageEntry? entry = await _deps.files.statEntry(target.ref);
      if (entry == null || !entry.isDirectory) throw const StorageFault(FaultKind.notADirectory);
    }
    _cwd = target.segments;
    _reply(250, "Now in ${formatFtpPath(_cwd)}.");
  }

  // ------------------------------------------------------ data connection

  Future<void> _pasv() async {
    await _closePassive();
    final _Passive passive = await _openPassive();
    final InternetAddress local = _control.address;
    if (local.type != InternetAddressType.IPv4) {
      await passive.server.close();
      _reply(522, "Use EPSV.");
      return;
    }
    _passive = passive;
    final List<String> octets = local.address.split(".");
    _reply(227, "Entering Passive Mode (${octets.join(",")},${passive.port >> 8},${passive.port & 255}).");
  }

  Future<void> _epsv(String? argument) async {
    if ((argument ?? "").toUpperCase() == "ALL") {
      _reply(200, "OK.");
      return;
    }
    await _closePassive();
    final _Passive passive = await _openPassive();
    _passive = passive;
    _reply(229, "Entering Extended Passive Mode (|||${passive.port}|).");
  }

  Future<void> _closePassive() async {
    final _Passive? passive = _passive;
    _passive = null;
    if (passive != null) {
      try {
        await passive.server.close();
      } on Object {
        // already closed
      }
    }
  }

  Future<_Passive> _openPassive() async {
    final int start = _settings.passiveStart;
    final int span = _settings.passiveEnd - start + 1;
    final int offset = _random.nextInt(span);
    for (int i = 0; i < span; i++) {
      final int port = start + (offset + i) % span;
      try {
        final ServerSocket server = await ServerSocket.bind(_control.address, port);
        final Completer<Socket> first = Completer<Socket>();
        server.listen(
          (Socket connection) {
            if (first.isCompleted) {
              connection.destroy();
            } else {
              first.complete(connection);
            }
          },
          onError: (Object error) {},
          onDone: () {
            if (!first.isCompleted) first.completeError(StateError("The data port was closed."));
          },
        );
        // Nobody may ever wait on this; a late failure must not be reported as unhandled.
        unawaited(first.future.then<void>((Socket _) {}, onError: (Object _) {}));
        return _Passive(server, first.future, port);
      } on SocketException {
        continue;
      }
    }
    throw const SocketException("No passive port is free.");
  }

  /// Announces the transfer, waits for the client's data connection and (in the
  /// secure modes) wraps it in TLS. `null`, after telling the client why, when
  /// it can't be done.
  Future<Socket?> _openData(String announcement) async {
    final _Passive? passive = _passive;
    if (passive == null) {
      _reply(425, "Use PASV or EPSV first.");
      return null;
    }
    if (_mustUseTls && !_dataProtected) {
      await _closePassive();
      _reply(521, "File transfers must be encrypted: send PBSZ 0 and PROT P first.");
      return null;
    }
    _passive = null;
    _reply(150, announcement);

    Socket socket;
    try {
      socket = await passive.connection.timeout(_limits.dataConnectTimeout);
    } on Object {
      await passive.server.close();
      _reply(425, "Couldn't open the data connection.");
      return null;
    }
    unawaited(passive.server.close().then<void>((_) {}, onError: (Object _) {}));

    if (socket.remoteAddress.address != _peer) {
      socket.destroy();
      _reply(425, "The data connection must come from the same address.");
      return null;
    }
    if (_mustUseTls) {
      final SecurityContext? tls = _tls;
      if (tls == null) {
        socket.destroy();
        _reply(425, "TLS isn't available.");
        return null;
      }
      try {
        // No prior listener on this fresh data socket, so (unlike the control
        // connection's upgrade in _auth) secureServer needs no `subscription:`.
        // Same known gap as _auth: a hung handshake outlives this .timeout().
        socket = await SecureSocket.secureServer(socket, tls).timeout(_limits.tlsHandshakeTimeout);
      } on Object {
        socket.destroy();
        _reply(425, "The secure data connection couldn't be set up.");
        return null;
      }
    }
    return socket;
  }

  Future<void> _sendText(Socket data, String text) async {
    data.add(utf8.encode(text));
    await data.flush();
    await data.close();
  }

  // -------------------------------------------------------------- listings

  Future<List<FtpEntry>> _entriesOf(_Target target) async {
    if (target.isTop) {
      final List<StorageRoot> roots = await _deps.gate.visibleRoots();
      final RootNames names = RootNames.of(roots);
      return <FtpEntry>[
        for (final StorageRoot root in roots)
          if (_deps.gate.allows(_who, Permission.read, root, StoragePath.root(root.id)))
            FtpEntry(
              name: names.nameOf(root.id)!,
              isDirectory: true,
              canWrite: root.capabilities.canWrite && _deps.gate.allows(_who, Permission.write, root, StoragePath.root(root.id)),
            ),
      ];
    }

    final StorageRoot root = target.root!;
    final StoragePath path = target.path!;
    _deps.gate.require(_who, Permission.read, root, path);
    if (!target.isRootFolder) {
      final StorageEntry? entry = await _deps.files.statEntry(target.ref);
      if (entry == null) throw const StorageFault(FaultKind.notFound);
      if (!entry.isDirectory) return <FtpEntry>[_entryOf(root, path, entry)];
    }

    final List<FtpEntry> out = <FtpEntry>[];
    String? cursor;
    while (true) {
      final List<StorageEntry> page = await _deps.files.list(target.ref, cursor: cursor, pageSize: 500).toList();
      for (final StorageEntry entry in page) {
        if (path.isRoot && StorageGate.isReservedName(entry.name)) continue;
        final StoragePath child;
        try {
          child = path.child(entry.name);
        } on AppFailure {
          continue; // a name that can't be represented safely is never listed
        }
        if (!_deps.gate.allows(_who, Permission.read, root, child)) continue;
        out.add(_entryOf(root, child, entry));
      }
      if (out.length > _limits.maxListedEntries) throw const StorageFault(FaultKind.unavailable);
      if (page.length < 500) break;
      cursor = page.last.name;
    }
    return out;
  }

  /// What a listing says about an entry. The permission letters are only a hint
  /// for clients; the real checks run again when they act.
  FtpEntry _entryOf(StorageRoot root, StoragePath path, StorageEntry entry) {
    return FtpEntry(
      name: entry.name,
      isDirectory: entry.isDirectory,
      size: entry.sizeBytes,
      modified: entry.modifiedAt,
      canWrite: root.capabilities.canWrite && _deps.gate.allows(_who, Permission.write, root, path),
      canDelete: root.capabilities.canWrite && _deps.gate.allows(_who, Permission.delete, root, path),
    );
  }

  Future<void> _list(String command, String? argument) async {
    final String? path = command == "MLSD" ? argument : stripListFlags(argument);
    final _Target target = await _resolve(path ?? ".");
    final List<FtpEntry> entries = await _entriesOf(target);

    final Socket? data = await _openData("Here comes the listing.");
    if (data == null) return;
    _transferring = true;
    try {
      final DateTime now = _now();
      final Iterable<String> lines = switch (command) {
        "NLST" => entries.map(nameOnlyLine),
        "MLSD" => entries.map(mlsxLine),
        _ => entries.map((FtpEntry e) => unixListLine(e, now)),
      };
      await _sendText(data, lines.map((String l) => "$l\r\n").join());
      _reply(226, "Listing sent.");
    } on Object {
      data.destroy();
      _reply(426, "The listing was interrupted.");
    } finally {
      _transferring = false;
    }
  }

  Future<void> _mlst(String? argument) async {
    final _Target target = await _resolve(argument ?? ".");
    if (target.isTop) {
      _replyLines(250, "Listing /", const <String>["type=dir;perm=el; /"], "End");
      return;
    }
    _deps.gate.require(_who, Permission.read, target.root!, target.path!);
    final StorageEntry? entry = target.isRootFolder ? null : await _deps.files.statEntry(target.ref);
    if (!target.isRootFolder && entry == null) throw const StorageFault(FaultKind.notFound);
    final String facts = target.isRootFolder
        ? mlsxLine(FtpEntry(name: target.rootName!, isDirectory: true, canWrite: target.root!.capabilities.canWrite))
        : mlsxLine(_entryOf(target.root!, target.path!, entry!));
    _replyLines(250, "Listing ${formatFtpPath(target.segments)}", <String>[facts], "End");
  }

  // ------------------------------------------------------------ transfers

  void _rest(String? argument) {
    final int? offset = int.tryParse(argument ?? "");
    if (offset == null || offset < 0) {
      _reply(501, "Give a byte position.");
      return;
    }
    _restartAt = offset;
    _reply(350, "Restarting at $offset. Now send RETR.");
  }

  Future<void> _retr(String? argument) async {
    if (argument == null) {
      _reply(501, "Say which file: RETR name.");
      return;
    }
    final int offset = _restartAt;
    _restartAt = 0;

    final _Target target = await _resolveItem(argument);
    _deps.gate.require(_who, Permission.read, target.root!, target.path!);
    final DownloadPlan plan = await _transfer.planDownload(target.root!, target.path!);
    final int size = plan.entry.sizeBytes ?? 0;
    if (offset > 0 && (!plan.canRange || offset > size)) {
      _reply(554, "That restart position isn't valid.");
      return;
    }

    final Stream<List<int>> source = offset == 0 ? plan.open() : _deps.files.openRead(target.ref, start: offset);
    final TransferMeter meter = _deps.activity.transfer(
      direction: TransferDirection.download,
      via: AccessVia.ftp,
      actor: _who.username,
      name: plan.entry.name,
      totalBytes: plan.entry.sizeBytes == null ? null : size - offset,
    );

    final Socket? data = await _openData("Opening data connection for ${plan.entry.name} ($size bytes).");
    if (data == null) {
      meter.finish(TransferState.interrupted);
      return;
    }
    _transferring = true;
    try {
      await data.addStream(meter.watchDownload(source));
      await data.flush();
      await data.close();
      _reply(226, "Transfer complete.");
    } on Object {
      data.destroy();
      meter.finish(TransferState.interrupted);
      _reply(426, "The transfer was interrupted.");
    } finally {
      _transferring = false;
    }
  }

  Future<void> _stor(String? argument) async {
    if (argument == null) {
      _reply(501, "Say which file: STOR name.");
      return;
    }
    if (_restartAt != 0) {
      _restartAt = 0;
      _reply(501, "Resuming an upload isn't supported.");
      return;
    }

    final _Target target = await _resolveItem(argument, forWrite: true);
    _deps.gate.require(_who, Permission.write, target.root!, target.path!);

    final TransferMeter meter = _deps.activity.transfer(
      direction: TransferDirection.upload,
      via: AccessVia.ftp,
      actor: _who.username,
      name: target.path!.name,
    );
    final Socket? data = await _openData("Ready to receive ${target.path!.name}.");
    if (data == null) {
      meter.finish(TransferState.interrupted);
      return;
    }
    _transferring = true;
    try {
      final Stream<List<int>> body = data.cast<List<int>>().timeout(
        _limits.dataIdleTimeout,
        onTimeout: (EventSink<List<int>> sink) {
          sink.addError(TimeoutException("The upload stalled."));
          sink.close();
        },
      );
      await meter.upload(
        body,
        (Stream<List<int>> counted) => _transfer.receive(target.root!, target.path!, counted, overwrite: true),
      );
      _reply(226, "Transfer complete.");
    } on StorageFault catch (fault) {
      data.destroy();
      _replyFault(fault);
    } on NotEnoughSpaceFailure {
      data.destroy();
      _reply(552, "There isn't enough space.");
    } on Object {
      data.destroy();
      _reply(426, "The upload was interrupted.");
    } finally {
      _transferring = false;
      unawaited(data.close().then<void>((Object? _) {}, onError: (Object _) {}));
    }
  }

  // ------------------------------------------------------- changing things

  Future<void> _delete(String? argument, {required bool folder}) async {
    if (argument == null) {
      _reply(501, "Say which one: ${folder ? "RMD" : "DELE"} name.");
      return;
    }
    final _Target target = await _resolveItem(argument);
    _deps.gate.require(_who, Permission.delete, target.root!, target.path!);
    final StorageEntry? entry = await _deps.files.statEntry(target.ref);
    if (entry == null) throw const StorageFault(FaultKind.notFound);
    if (folder != entry.isDirectory) {
      _reply(550, folder ? "That isn't a folder." : "That is a folder. Use RMD.");
      return;
    }
    final OperationBatch batch = await _deps.delete(sources: <FileRef>[target.ref]);
    if (batch.allCompleted) {
      _reply(250, "${folder ? "Folder" : "File"} moved to the Recycle Bin.");
    } else {
      _reply(550, batch.outcomes.first.userMessage ?? "It couldn't be deleted.");
    }
  }

  Future<void> _mkd(String? argument) async {
    if (argument == null) {
      _reply(501, "Say the folder's name: MKD name.");
      return;
    }
    final _Target target = await _resolveItem(argument, forWrite: true);
    _deps.gate.require(_who, Permission.write, target.root!, target.path!);
    await _transfer.requireDirectory(FileRef(root: target.root!, path: target.path!.parent), FaultKind.parentMissing);
    if (await _deps.files.statEntry(target.ref) != null) {
      _reply(550, "Something with that name already exists.");
      return;
    }
    await _deps.files.createDirectory(FileRef(root: target.root!, path: target.path!.parent), target.path!.name);
    _reply(257, "${quoteFtpPath(formatFtpPath(target.segments))} created.");
  }

  Future<void> _rnfr(String? argument) async {
    if (argument == null) {
      _reply(501, "Say which one: RNFR name.");
      return;
    }
    final _Target target = await _resolveItem(argument);
    _deps.gate.require(_who, Permission.write, target.root!, target.path!);
    if (await _deps.files.statEntry(target.ref) == null) throw const StorageFault(FaultKind.notFound);
    _renameFrom = target;
    _reply(350, "Ready for RNTO.");
  }

  Future<void> _rnto(String? argument) async {
    final _Target? from = _renameFrom;
    _renameFrom = null;
    if (from == null) {
      _reply(503, "Send RNFR first.");
      return;
    }
    if (argument == null) {
      _reply(501, "Say the new name: RNTO name.");
      return;
    }
    final _Target to = await _resolveItem(argument, forWrite: true);
    _deps.gate.require(_who, Permission.write, to.root!, to.path!);
    if (to.root!.id != from.root!.id) {
      _reply(553, "Moving between storage locations isn't supported. Copy and delete instead.");
      return;
    }

    if (to.path!.parent == from.path!.parent) {
      await _deps.files.renameSingle(from.ref, to.path!.name);
      _reply(250, "Renamed.");
      return;
    }
    if (to.path!.name != from.path!.name) {
      _reply(553, "Rename and move separately.");
      return;
    }
    final OperationBatch batch = await _deps.move(
      sources: <FileRef>[from.ref],
      destinationDirectory: FileRef(root: to.root!, path: to.path!.parent),
      conflictPolicy: ConflictPolicy.skip,
    );
    if (batch.allCompleted) {
      _reply(250, "Moved.");
    } else {
      _reply(553, batch.outcomes.first.userMessage ?? "It couldn't be moved.");
    }
  }

  Future<void> _size(String? argument) async {
    if (argument == null) {
      _reply(501, "Say which file: SIZE name.");
      return;
    }
    final _Target target = await _resolveItem(argument);
    _deps.gate.require(_who, Permission.read, target.root!, target.path!);
    final StorageEntry? entry = await _deps.files.statEntry(target.ref);
    if (entry == null || entry.isDirectory) throw const StorageFault(FaultKind.notFound);
    _reply(213, "${entry.sizeBytes ?? 0}");
  }

  Future<void> _mdtm(String? argument) async {
    if (argument == null) {
      _reply(501, "Say which file: MDTM name.");
      return;
    }
    final _Target target = await _resolveItem(argument);
    _deps.gate.require(_who, Permission.read, target.root!, target.path!);
    final StorageEntry? entry = await _deps.files.statEntry(target.ref);
    final DateTime? modified = entry?.modifiedAt;
    if (entry == null || modified == null) throw const StorageFault(FaultKind.notFound);
    _reply(213, ftpTimestamp(modified));
  }
}
