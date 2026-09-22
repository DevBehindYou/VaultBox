import "dart:async";
import "dart:io";

import "../../domain/entities/ftp_settings.dart";
import "../network_addresses.dart";
import "ftp_deps.dart";
import "ftp_session.dart";

/// The FTP / FTPS listener.
///
/// Three modes (see [FtpMode]): explicit FTPS (the client upgrades with
/// `AUTH TLS`; logins are refused until it does), implicit FTPS (encrypted from
/// the first byte) and plain FTP. Plain FTP sends passwords in clear text, so it
/// only answers this phone and private-network addresses, and never a stranger.
/// A TLS mode with no certificate refuses to start rather than falling back.
///
/// Connection counts are capped in total and per address.
final class FtpServer {
  FtpServer({
    required FtpDeps deps,
    required FtpSettings settings,
    required DateTime Function() now,
    SecurityContext? tlsContext,
    FtpLimits limits = const FtpLimits(),
    bool privateClientsOnly = true,
  }) : _deps = deps,
       _settings = settings,
       _tls = tlsContext,
       _limits = limits,
       _now = now,
       _privateClientsOnly = privateClientsOnly;

  final FtpDeps _deps;
  final FtpSettings _settings;
  final SecurityContext? _tls;
  final FtpLimits _limits;
  final DateTime Function() _now;
  final bool _privateClientsOnly;

  final Set<FtpSession> _sessions = <FtpSession>{};
  final Map<String, int> _perAddress = <String, int>{};
  StreamSubscription<Socket>? _subscription;
  Future<void> Function()? _closeListener;

  int? _port;

  /// The bound port once started (useful when [start] was given port 0).
  int? get port => _port;

  int get connectionCount => _sessions.length;

  Future<void> start({required InternetAddress address, required int port}) async {
    if (_settings.usesTls && _tls == null) {
      throw StateError("FTPS needs a certificate.");
    }
    if (_settings.mode == FtpMode.implicitTls) {
      final SecureServerSocket server = await SecureServerSocket.bind(address, port, _tls!);
      _port = server.port;
      _closeListener = () async {
        await server.close();
      };
      _subscription = server.listen(_onConnection, onError: (Object error) {});
    } else {
      final ServerSocket server = await ServerSocket.bind(address, port);
      _port = server.port;
      _closeListener = () async {
        await server.close();
      };
      _subscription = server.listen(_onConnection, onError: (Object error) {});
    }
  }

  void _onConnection(Socket socket) {
    final String peer;
    try {
      peer = socket.remoteAddress.address;
    } on Object {
      socket.destroy();
      return;
    }

    if (!_settings.usesTls && _privateClientsOnly && !isPrivateOrLoopbackClient(socket.remoteAddress)) {
      socket.destroy();
      return;
    }
    if (_sessions.length >= _limits.maxConnections || (_perAddress[peer] ?? 0) >= _limits.maxConnectionsPerAddress) {
      try {
        socket.add("421 Too many connections. Try again later.\r\n".codeUnits);
      } on Object {
        // closing anyway
      }
      socket.destroy();
      return;
    }

    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on Object {
      // not essential
    }

    final FtpSession session = FtpSession(
      socket: socket,
      deps: _deps,
      settings: _settings,
      tls: _tls,
      limits: _limits,
      tlsActive: _settings.mode == FtpMode.implicitTls,
      now: _now,
    );
    _sessions.add(session);
    _perAddress[peer] = (_perAddress[peer] ?? 0) + 1;
    unawaited(
      session.done.whenComplete(() {
        _sessions.remove(session);
        final int left = (_perAddress[peer] ?? 1) - 1;
        if (left <= 0) {
          _perAddress.remove(peer);
        } else {
          _perAddress[peer] = left;
        }
      }),
    );
    session.start();
  }

  Future<void> stop() async {
    final StreamSubscription<Socket>? subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final Future<void> Function()? close = _closeListener;
    _closeListener = null;
    try {
      await close?.call();
    } on Object {
      // already closed
    }
    for (final FtpSession session in List<FtpSession>.of(_sessions)) {
      session.close();
    }
    _sessions.clear();
    _perAddress.clear();
    _port = null;
  }
}
