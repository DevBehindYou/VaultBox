import "dart:io";

/// A runtime-generated self-signed certificate/key pair, or `null` when the
/// `openssl` CLI isn't on this machine's PATH. Nothing here is checked in: a
/// fresh pair is made per test run, in a temp directory that is cleaned up
/// immediately after the PEM text is read into memory.
///
/// Tests that need one should skip themselves (`markTestSkipped(...)`) when
/// [generate] returns `null`, rather than failing the whole suite over a
/// missing dev tool (docs/TASKS.md §A: "skip the test if it is missing").
final class SelfSignedCert {
  const SelfSignedCert({required this.certificatePem, required this.privateKeyPem});

  final String certificatePem;
  final String privateKeyPem;

  static bool? _available;

  /// Whether `openssl` answers `version` on this machine. Cached for the run.
  static Future<bool> isOpensslAvailable() async {
    final bool? cached = _available;
    if (cached != null) return cached;
    bool ok;
    try {
      final ProcessResult result = await Process.run("openssl", <String>["version"]);
      ok = result.exitCode == 0;
    } on Object {
      ok = false;
    }
    _available = ok;
    return ok;
  }

  /// A fresh RSA-2048 self-signed certificate for [commonName], valid for one
  /// day. `null` if `openssl` isn't available or the call failed.
  static Future<SelfSignedCert?> generate({String commonName = "localhost"}) async {
    if (!await isOpensslAvailable()) return null;

    final Directory dir = await Directory.systemTemp.createTemp("vaultbox_ftps_cert_");
    try {
      final String keyPath = "${dir.path}${Platform.pathSeparator}key.pem";
      final String certPath = "${dir.path}${Platform.pathSeparator}cert.pem";
      final ProcessResult result = await Process.run("openssl", <String>[
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        keyPath,
        "-out",
        certPath,
        "-days",
        "1",
        "-subj",
        "/CN=$commonName",
      ]);
      if (result.exitCode != 0) return null;

      final File keyFile = File(keyPath);
      final File certFile = File(certPath);
      if (!await keyFile.exists() || !await certFile.exists()) return null;

      return SelfSignedCert(
        certificatePem: await certFile.readAsString(),
        privateKeyPem: await keyFile.readAsString(),
      );
    } on Object {
      return null;
    } finally {
      try {
        await dir.delete(recursive: true);
      } on Object {
        // best effort; the OS temp directory gets cleaned up eventually anyway
      }
    }
  }
}
