/// Password hashing contract. Never bare SHA-256: implementations must be a
/// deliberately slow, salted, memory-hard function (Argon2id — see
/// `Argon2idPasswordHasher`).
abstract interface class PasswordHasher {
  /// Returns a self-describing encoded hash (algorithm, parameters, salt and
  /// digest in one string), so parameters can be raised later without a schema
  /// change and old hashes still verify.
  Future<String> hash(String password);

  /// Constant-time check. Returns false — never throws — for a wrong password or
  /// for any malformed or implausible [encoded] value (fail closed).
  Future<bool> verify(String password, String encoded);

  /// True if [encoded] was made with weaker parameters than this hasher's
  /// current ones (or can't be parsed): re-hash after a successful login.
  bool needsRehash(String encoded);
}
