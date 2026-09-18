/// A person who can log in to the server. Only a password HASH is stored
/// ([passwordHash], PHC-encoded Argon2id) — never the password.
final class Account {
  const Account({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.createdAt,
  });

  final String id;

  /// Lower-case, already validated (see `UsernamePolicy`).
  final String username;
  final String passwordHash;
  final DateTime createdAt;
}
