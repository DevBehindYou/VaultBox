import "package:vaultbox/domain/security/password_hasher.dart";

/// Instant, deterministic hasher for tests that aren't about hashing (widget
/// tests can't wait on a real Argon2 isolate). Never use outside tests.
final class FakePasswordHasher implements PasswordHasher {
  int hashCalls = 0;

  @override
  Future<String> hash(String password) async {
    hashCalls++;
    return "fake:$password";
  }

  @override
  Future<bool> verify(String password, String encoded) async => encoded == "fake:$password";

  @override
  bool needsRehash(String encoded) => false;
}
