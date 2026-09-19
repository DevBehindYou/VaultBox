import "../entities/account.dart";

abstract interface class AccountRepository {
  Future<int> count();

  /// [username] must already be normalized (`UsernamePolicy.normalize`).
  Future<Account?> findByUsername(String username);

  Future<Account?> findById(String id);

  /// Creates [account] ONLY if no account exists yet — check and insert are one
  /// atomic step, so two racing "first admin" requests can't both win. Returns
  /// `null` (and stores nothing) if an account already exists.
  Future<Account?> createFirst(Account account);

  Future<void> updatePasswordHash(String id, String passwordHash);
}
