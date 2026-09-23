import "package:drift/drift.dart";

import "../../domain/entities/access_rule.dart";
import "../../domain/entities/account.dart";
import "../../domain/repositories/account_repository.dart";
import "../../domain/security/permission.dart";
import "../db/app_database.dart";

final class DriftAccountRepository implements AccountRepository {
  const DriftAccountRepository(this._db);

  final AppDatabase _db;

  @override
  Future<int> count() async => (await _db.select(_db.accounts).get()).length;

  @override
  Future<int> countEnabledAdmins() async {
    final List<AccountRow> rows = await (_db.select(_db.accounts)
          ..where((Accounts t) => t.role.equals(AccountRole.admin.name) & t.isEnabled.equals(true)))
        .get();
    return rows.length;
  }

  @override
  Future<List<Account>> listAll() async {
    final List<AccountRow> rows = await (_db.select(_db.accounts)
          ..orderBy(<OrderClauseGenerator<Accounts>>[(Accounts t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    final Map<String, List<AccessRule>> rules = await _rulesByAccount();
    return <Account>[for (final AccountRow row in rows) _toEntity(row, rules[row.id] ?? const <AccessRule>[])];
  }

  @override
  Future<Account?> findByUsername(String username) async {
    final AccountRow? row = await (_db.select(
      _db.accounts,
    )..where((Accounts t) => t.username.equals(username))).getSingleOrNull();
    return row == null ? null : _hydrate(row);
  }

  @override
  Future<Account?> findById(String id) async {
    final AccountRow? row = await (_db.select(
      _db.accounts,
    )..where((Accounts t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _hydrate(row);
  }

  @override
  Future<Account?> createFirst(Account account) {
    return _db.transaction(() async {
      if ((await _db.select(_db.accounts).get()).isNotEmpty) return null;
      await _insert(account);
      return account;
    });
  }

  @override
  Future<Account?> create(Account account) {
    return _db.transaction(() async {
      final AccountRow? taken = await (_db.select(
        _db.accounts,
      )..where((Accounts t) => t.username.equals(account.username))).getSingleOrNull();
      if (taken != null) return null;
      await _insert(account);
      return account;
    });
  }

  Future<void> _insert(Account account) async {
    await _db.into(_db.accounts).insert(
      AccountsCompanion.insert(
        id: account.id,
        username: account.username,
        passwordHash: account.passwordHash,
        createdAt: account.createdAt,
        role: Value<String>(account.role.name),
        isEnabled: Value<bool>(account.isEnabled),
        credentialVersion: Value<int>(account.credentialVersion),
      ),
    );
  }

  @override
  Future<void> updatePasswordHash(String id, String passwordHash) async {
    await _db.transaction(() async {
      final AccountRow? row = await (_db.select(_db.accounts)..where((Accounts t) => t.id.equals(id))).getSingleOrNull();
      if (row == null) return;
      await (_db.update(_db.accounts)..where((Accounts t) => t.id.equals(id))).write(
        AccountsCompanion(
          passwordHash: Value<String>(passwordHash),
          credentialVersion: Value<int>(row.credentialVersion + 1),
        ),
      );
    });
  }

  @override
  Future<void> revokeSessions(String id) async {
    await _db.transaction(() async {
      final AccountRow? row = await (_db.select(_db.accounts)..where((Accounts t) => t.id.equals(id))).getSingleOrNull();
      if (row == null) return;
      await (_db.update(_db.accounts)..where((Accounts t) => t.id.equals(id))).write(
        AccountsCompanion(credentialVersion: Value<int>(row.credentialVersion + 1)),
      );
    });
  }

  @override
  Future<void> setEnabled(String id, {required bool enabled}) async {
    await _db.transaction(() async {
      final AccountRow? row = await (_db.select(_db.accounts)..where((Accounts t) => t.id.equals(id))).getSingleOrNull();
      if (row == null || row.isEnabled == enabled) return;
      await (_db.update(_db.accounts)..where((Accounts t) => t.id.equals(id))).write(
        AccountsCompanion(
          isEnabled: Value<bool>(enabled),
          credentialVersion: Value<int>(enabled ? row.credentialVersion : row.credentialVersion + 1),
        ),
      );
    });
  }

  @override
  Future<void> delete(String id) async {
    await _db.transaction(() async {
      await (_db.delete(_db.accessRules)..where((AccessRules t) => t.accountId.equals(id))).go();
      await (_db.delete(_db.accounts)..where((Accounts t) => t.id.equals(id))).go();
    });
  }

  @override
  Future<void> replaceRules(String accountId, List<AccessRule> rules) async {
    await _db.transaction(() async {
      await (_db.delete(_db.accessRules)..where((AccessRules t) => t.accountId.equals(accountId))).go();
      for (final AccessRule rule in rules) {
        await _db.into(_db.accessRules).insert(
          AccessRulesCompanion.insert(
            id: rule.id,
            accountId: accountId,
            rootId: rule.rootId,
            pathPrefix: rule.pathPrefix,
            permissions: (rule.permissions.map((Permission p) => p.name).toList()..sort()).join(","),
          ),
        );
      }
    });
  }

  Future<Account> _hydrate(AccountRow row) async {
    final List<AccessRuleRow> rules = await (_db.select(
      _db.accessRules,
    )..where((AccessRules t) => t.accountId.equals(row.id))).get();
    return _toEntity(row, <AccessRule>[for (final AccessRuleRow r in rules) _ruleOf(r)]);
  }

  Future<Map<String, List<AccessRule>>> _rulesByAccount() async {
    final List<AccessRuleRow> rows = await _db.select(_db.accessRules).get();
    final Map<String, List<AccessRule>> out = <String, List<AccessRule>>{};
    for (final AccessRuleRow row in rows) {
      out.putIfAbsent(row.accountId, () => <AccessRule>[]).add(_ruleOf(row));
    }
    return out;
  }

  static AccessRule _ruleOf(AccessRuleRow row) => AccessRule(
    id: row.id,
    accountId: row.accountId,
    rootId: row.rootId,
    pathPrefix: row.pathPrefix,
    permissions: <Permission>{
      for (final String name in row.permissions.split(","))
        for (final Permission p in Permission.values)
          if (p.name == name) p,
    },
  );

  static Account _toEntity(AccountRow row, List<AccessRule> rules) => Account(
    id: row.id,
    username: row.username,
    passwordHash: row.passwordHash,
    createdAt: row.createdAt,
    role: AccountRole.values.firstWhere((AccountRole r) => r.name == row.role, orElse: () => AccountRole.member),
    isEnabled: row.isEnabled,
    credentialVersion: row.credentialVersion,
    rules: rules,
  );
}
