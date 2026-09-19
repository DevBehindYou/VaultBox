import "package:drift/drift.dart";

import "../../domain/entities/account.dart";
import "../../domain/repositories/account_repository.dart";
import "../db/app_database.dart";

final class DriftAccountRepository implements AccountRepository {
  const DriftAccountRepository(this._db);

  final AppDatabase _db;

  @override
  Future<int> count() async => (await _db.select(_db.accounts).get()).length;

  @override
  Future<Account?> findByUsername(String username) async {
    final AccountRow? row = await (_db.select(
      _db.accounts,
    )..where((Accounts t) => t.username.equals(username))).getSingleOrNull();
    return row == null ? null : _toEntity(row);
  }

  @override
  Future<Account?> findById(String id) async {
    final AccountRow? row = await (_db.select(
      _db.accounts,
    )..where((Accounts t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toEntity(row);
  }

  @override
  Future<Account?> createFirst(Account account) {
    return _db.transaction(() async {
      if ((await _db.select(_db.accounts).get()).isNotEmpty) return null;
      await _db.into(_db.accounts).insert(
        AccountsCompanion.insert(
          id: account.id,
          username: account.username,
          passwordHash: account.passwordHash,
          createdAt: account.createdAt,
        ),
      );
      return account;
    });
  }

  @override
  Future<void> updatePasswordHash(String id, String passwordHash) async {
    await (_db.update(_db.accounts)..where((Accounts t) => t.id.equals(id))).write(
      AccountsCompanion(passwordHash: Value<String>(passwordHash)),
    );
  }

  Account _toEntity(AccountRow row) => Account(
    id: row.id,
    username: row.username,
    passwordHash: row.passwordHash,
    createdAt: row.createdAt,
  );
}
