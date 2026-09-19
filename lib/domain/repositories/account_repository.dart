import "../entities/access_rule.dart";
import "../entities/account.dart";

/// Login accounts and the folder grants that belong to them. Every [Account]
/// this returns already carries its current [Account.rules].
abstract interface class AccountRepository {
  Future<int> count();

  /// How many enabled admin accounts exist (the last one can't be removed).
  Future<int> countEnabledAdmins();

  Future<List<Account>> listAll();

  /// [username] must already be normalized (`UsernamePolicy.normalize`).
  Future<Account?> findByUsername(String username);

  Future<Account?> findById(String id);

  /// Creates [account] ONLY if no account exists yet — check and insert are one
  /// atomic step, so two racing "first admin" requests can't both win. Returns
  /// `null` (and stores nothing) if an account already exists.
  Future<Account?> createFirst(Account account);

  /// Adds a further account. Returns `null` (and stores nothing) if the
  /// username is already taken.
  Future<Account?> create(Account account);

  /// Replaces the password hash and bumps [Account.credentialVersion], which
  /// ends every session the account had.
  Future<void> updatePasswordHash(String id, String passwordHash);

  /// Enables or disables an account. Disabling bumps [Account.credentialVersion].
  Future<void> setEnabled(String id, {required bool enabled});

  /// Removes the account and its rules.
  Future<void> delete(String id);

  /// Replaces ALL of the account's rules with [rules].
  Future<void> replaceRules(String accountId, List<AccessRule> rules);
}
