import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/entities/ftp_settings.dart";
import "package:vaultbox/server/tls_context.dart";

import "../../helpers/ftp_harness.dart";
import "../../helpers/self_signed_cert.dart";

/// TLS-specific FTP behaviour: explicit FTPS refuses login before `AUTH TLS`,
/// `PROT C` is refused (transfers must be encrypted), implicit FTPS is secure
/// from the first byte, and a TLS mode with no certificate refuses to start.
///
/// A real certificate is generated at runtime with the `openssl` CLI
/// (docs/TASKS.md §A); tests that need one skip themselves with a clear
/// reason when it isn't on this machine's PATH, rather than failing the run.
void main() {
  test("a TLS mode configured with no certificate refuses to start the server", () async {
    // No openssl needed for this one: it's about the missing certificate,
    // not a real handshake.
    final FtpHarness harness = FtpHarness(
      settings: const FtpSettings(enabled: true, mode: FtpMode.explicitTls),
      tls: null,
    );

    await expectLater(harness.start(), throwsA(isA<StateError>()));
  });

  group("with a real certificate", () {
    late SelfSignedCert? cert;

    setUp(() async {
      cert = await SelfSignedCert.generate();
    });

    test("explicit FTPS refuses USER before AUTH TLS, then works once upgraded", () async {
      final SelfSignedCert? c = cert;
      if (c == null) {
        markTestSkipped("openssl CLI isn't available on this machine");
        return;
      }

      final FtpHarness harness = FtpHarness(
        settings: const FtpSettings(enabled: true, mode: FtpMode.explicitTls),
        tls: buildTlsContext(certificatePem: c.certificatePem, privateKeyPem: c.privateKeyPem),
      );
      final int port = await harness.start();
      final _RawFtpClient client = await _RawFtpClient.connectPlain(port);

      final List<String> banner = await client.readReply();
      expect(_codeOf(banner), 220);

      final List<String> beforeAuth = await client.send("USER admin");
      expect(_codeOf(beforeAuth), 530, reason: "plaintext sign-in must be refused before AUTH TLS");

      final List<String> authReply = await client.send("AUTH TLS");
      expect(_codeOf(authReply), 234);

      await client.upgradeToTls(host: "localhost");

      final List<String> user = await client.send("USER admin");
      expect(_codeOf(user), 331, reason: "USER is accepted once the connection is actually secure");

      final List<String> pass = await client.send("PASS ${FtpHarness.adminPassword}");
      expect(_codeOf(pass), 230);

      final List<String> pwd = await client.send("PWD");
      expect(_codeOf(pwd), 257, reason: "ordinary commands work over the now-encrypted channel");

      await client.close();
      await harness.stop();
    });

    test("implicit FTPS is secure from the very first byte, with no explicit AUTH", () async {
      final SelfSignedCert? c = cert;
      if (c == null) {
        markTestSkipped("openssl CLI isn't available on this machine");
        return;
      }

      final FtpHarness harness = FtpHarness(
        settings: const FtpSettings(enabled: true, mode: FtpMode.implicitTls),
        tls: buildTlsContext(certificatePem: c.certificatePem, privateKeyPem: c.privateKeyPem),
      );
      final int port = await harness.start();
      final _RawFtpClient client = await _RawFtpClient.connectSecure(port, host: "localhost");

      final List<String> banner = await client.readReply();
      expect(_codeOf(banner), 220);

      final List<String> user = await client.send("USER admin");
      expect(_codeOf(user), 331, reason: "no AUTH TLS is needed: the socket was already secure on accept");

      final List<String> pass = await client.send("PASS ${FtpHarness.adminPassword}");
      expect(_codeOf(pass), 230);

      await client.close();
      await harness.stop();
    });

    test("PROT C is refused: transfers must stay encrypted once the connection is secure", () async {
      final SelfSignedCert? c = cert;
      if (c == null) {
        markTestSkipped("openssl CLI isn't available on this machine");
        return;
      }

      final FtpHarness harness = FtpHarness(
        settings: const FtpSettings(enabled: true, mode: FtpMode.implicitTls),
        tls: buildTlsContext(certificatePem: c.certificatePem, privateKeyPem: c.privateKeyPem),
      );
      final int port = await harness.start();
      final _RawFtpClient client = await _RawFtpClient.connectSecure(port, host: "localhost");

      await client.readReply(); // banner
      await client.send("USER admin");
      await client.send("PASS ${FtpHarness.adminPassword}");

      final List<String> pbsz = await client.send("PBSZ 0");
      expect(_codeOf(pbsz), 200);

      final List<String> protC = await client.send("PROT C");
      expect(_codeOf(protC), 534, reason: "unencrypted file transfers aren't allowed once the server is in a TLS mode");

      final List<String> protP = await client.send("PROT P");
      expect(_codeOf(protP), 200, reason: "PROT P is the only level this server accepts");

      await client.close();
      await harness.stop();
    });
  });
}

int _codeOf(List<String> reply) => int.parse(reply.first.substring(0, 3));

/// A minimal raw FTP client that manages its own socket subscription
/// directly (rather than through a `StreamIterator` glued straight to the
/// socket, as `FtpTestClient` does), so it can be swapped out mid-session for
/// the AUTH TLS upgrade — mirroring exactly what `FtpSession._auth` does on
/// the server side: pause the existing subscription, then hand it to
/// `SecureSocket.secure(..., subscription: ...)` rather than losing it.
final class _RawFtpClient {
  _RawFtpClient(this._socket) {
    _sub = _socket.listen(
      _onData,
      onDone: () => unawaited(_controller.close()),
      onError: (Object error) => _controller.addError(error),
    );
  }

  static Future<_RawFtpClient> connectPlain(int port) async {
    final Socket socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return _RawFtpClient(socket);
  }

  static Future<_RawFtpClient> connectSecure(int port, {required String host}) async {
    final SecureSocket socket = await SecureSocket.connect(
      host,
      port,
      onBadCertificate: (X509Certificate certificate) => true,
    );
    return _RawFtpClient(socket);
  }

  Socket _socket;
  StreamSubscription<Uint8List>? _sub;
  final List<int> _buffer = <int>[];
  final StreamController<String> _controller = StreamController<String>();
  late final StreamIterator<String> _lines = StreamIterator<String>(_controller.stream);

  void _onData(Uint8List chunk) {
    _buffer.addAll(chunk);
    while (true) {
      final int newline = _buffer.indexOf(10);
      if (newline == -1) break;
      List<int> line = _buffer.sublist(0, newline);
      _buffer.removeRange(0, newline + 1);
      if (line.isNotEmpty && line.last == 13) line = line.sublist(0, line.length - 1);
      _controller.add(utf8.decode(line));
    }
  }

  Future<List<String>> readReply() async {
    final List<String> out = <String>[];
    while (true) {
      final bool has = await _lines.moveNext().timeout(const Duration(seconds: 5));
      if (!has) break;
      out.add(_lines.current);
      final RegExpMatch? m = RegExp(r"^(\d{3})(.)").firstMatch(_lines.current);
      if (m != null && m.group(2) == " ") break;
    }
    return out;
  }

  Future<List<String>> send(String command) async {
    _socket.add(utf8.encode("$command\r\n"));
    await _socket.flush();
    return readReply();
  }

  /// Upgrades the (plain) connection to TLS in place: pause the existing
  /// subscription first and hand it to `SecureSocket.secure`, exactly the
  /// same shape as the fix in `FtpSession._auth`, so bytes already in flight
  /// when the server replies `234` are not lost.
  Future<void> upgradeToTls({required String host}) async {
    _sub?.pause();
    final SecureSocket secure = await SecureSocket.secure(
      _socket,
      host: host,
      subscription: _sub,
      onBadCertificate: (X509Certificate certificate) => true,
    );
    _socket = secure;
    _sub = _socket.listen(
      _onData,
      onDone: () => unawaited(_controller.close()),
      onError: (Object error) => _controller.addError(error),
    );
  }

  Future<void> close() async {
    await _lines.cancel();
    unawaited(_sub?.cancel());
    unawaited(_controller.close());
    _socket.destroy();
  }
}
