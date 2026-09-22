import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/server/tls_context.dart";

import "../helpers/self_signed_cert.dart";

/// [buildTlsContext] is only two lines, but a wrong argument order or a
/// mangled PEM string would silently produce a [SecurityContext] nothing can
/// actually use, so this checks the happy path actually binds a TLS socket,
/// not just that the call "didn't throw".
void main() {
  test("a real certificate and key build a SecurityContext that a TLS socket can bind with", () async {
    final SelfSignedCert? cert = await SelfSignedCert.generate();
    if (cert == null) {
      markTestSkipped("openssl CLI isn't available on this machine");
      return;
    }

    final SecurityContext context = buildTlsContext(
      certificatePem: cert.certificatePem,
      privateKeyPem: cert.privateKeyPem,
    );

    final SecureServerSocket server = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context);
    await server.close();
  });

  test("HTTPS and FTPS share one identity: the same PEM pair builds two independent, equally usable contexts", () async {
    final SelfSignedCert? cert = await SelfSignedCert.generate();
    if (cert == null) {
      markTestSkipped("openssl CLI isn't available on this machine");
      return;
    }

    final SecurityContext https = buildTlsContext(certificatePem: cert.certificatePem, privateKeyPem: cert.privateKeyPem);
    final SecurityContext ftps = buildTlsContext(certificatePem: cert.certificatePem, privateKeyPem: cert.privateKeyPem);

    final SecureServerSocket a = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, https);
    final SecureServerSocket b = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, ftps);
    await a.close();
    await b.close();
  });

  test("a garbage certificate is rejected rather than silently accepted", () {
    expect(
      () => buildTlsContext(certificatePem: "not a certificate", privateKeyPem: "not a key"),
      throwsA(anything),
    );
  });

  test("a certificate with no matching private key is rejected", () async {
    final SelfSignedCert? cert = await SelfSignedCert.generate();
    if (cert == null) {
      markTestSkipped("openssl CLI isn't available on this machine");
      return;
    }

    expect(
      () => buildTlsContext(certificatePem: cert.certificatePem, privateKeyPem: "not a key"),
      throwsA(anything),
    );
  });
}
