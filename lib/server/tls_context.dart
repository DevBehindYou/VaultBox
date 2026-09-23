import "dart:convert";
import "dart:io";

/// The server's TLS identity as a [SecurityContext], shared by every listener
/// that speaks TLS (HTTPS and FTPS) so they present the same certificate and
/// people can check one fingerprint.
SecurityContext buildTlsContext({required String certificatePem, required String privateKeyPem}) {
  return SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certificatePem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));
}
