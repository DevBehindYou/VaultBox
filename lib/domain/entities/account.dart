import "access_rule.dart";

enum AccountRole {
  /// Everything, everywhere. The first account is always an admin.
  admin,

  /// Only what its [AccessRule]s grant.
  member,
}

/// A person who can log in to the server. Only a password HASH is stored
/// ([passwordHash], PHC-encoded Argon2id) — never the password.
final class Account {
  const Account({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.createdAt,
    this.role = AccountRole.admin,
    this.isEnabled = true,
    this.credentialVersion = 0,
    this.rules = const <AccessRule>[],
  });

  final String id;

  /// Lower-case, already validated (see `UsernamePolicy`).
  final String username;
  final String passwordHash;
  final DateTime createdAt;
  final AccountRole role;

  /// A disabled account can't log in and its open sessions stop working.
  final bool isEnabled;

  /// Bumped whenever the password changes or the account is disabled. A session
  /// remembers the value it was opened with, so changing it ends every session
  /// (in any process) without the two sides having to talk to each other.
  final int credentialVersion;

  /// What a [AccountRole.member] may touch. Empty for admins (they need none).
  final List<AccessRule> rules;

  bool get isAdmin => role == AccountRole.admin;

  Account copyWith({
    String? passwordHash,
    AccountRole? role,
    bool? isEnabled,
    int? credentialVersion,
    List<AccessRule>? rules,
  }) => Account(
    id: id,
    username: username,
    passwordHash: passwordHash ?? this.passwordHash,
    createdAt: createdAt,
    role: role ?? this.role,
    isEnabled: isEnabled ?? this.isEnabled,
    credentialVersion: credentialVersion ?? this.credentialVersion,
    rules: rules ?? this.rules,
  );
}
