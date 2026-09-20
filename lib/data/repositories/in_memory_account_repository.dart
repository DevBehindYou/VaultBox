import "../../domain/entities/access_rule.dart";
import "../../domain/entities/account.dart";
import "../../domain/repositories/account_repository.dart";

/// Test fake for [AccountRepository] — same contract as the Drift one, no database.
final class InMemoryAccountRepository implements AccountRepository {
  InMemoryAccountRepository([List<Account> initial = const <Account>[]]) {
    _accounts.addAll(initial);
  }

  final List<Account> _accounts = <Account>[];

  @override
  Future<int> count() async => _accounts.length;

  @override
  Future<int> countEnabledAdmins() async =>
      _accounts.where((Account a) => a.isAdmin && a.isEnabled).length;

  @override
  Future<List<Account>> listAll() async => List<Account>.of(_accounts);

  @override
  Future<Account?> findByUsername(String username) async {
    for (final Account account in _accounts) {
      if (account.username == username) return account;
    }
    return null;
  }

  @override
  Future<Account?> findById(String id) async {
    for (final Account account in _accounts) {
      if (account.id == id) return account;
    }
    return null;
  }

  @override
  Future<Account?> createFirst(Account account) async {
    if (_accounts.isNotEmpty) return null;
    _accounts.add(account);
    return account;
  }

  @override
  Future<Account?> create(Account account) async {
    if (_accounts.any((Account a) => a.username == account.username)) return null;
    _accounts.add(account);
    return account;
  }

  @override
  Future<void> updatePasswordHash(String id, String passwordHash) async {
    _replace(id, (Account old) => old.copyWith(passwordHash: passwordHash, credentialVersion: old.credentialVersion + 1));
  }

  @override
  Future<void> revokeSessions(String id) async {
    _replace(id, (Account old) => old.copyWith(credentialVersion: old.credentialVersion + 1));
  }

  @override
  Future<void> setEnabled(String id, {required bool enabled}) async {
    _replace(id, (Account old) {
      if (old.isEnabled == enabled) return old;
      return old.copyWith(isEnabled: enabled, credentialVersion: enabled ? old.credentialVersion : old.credentialVersion + 1);
    });
  }

  @override
  Future<void> delete(String id) async {
    _accounts.removeWhere((Account a) => a.id == id);
  }

  @override
  Future<void> replaceRules(String accountId, List<AccessRule> rules) async {
    _replace(accountId, (Account old) => old.copyWith(rules: List<AccessRule>.unmodifiable(rules)));
  }

  void _replace(String id, Account Function(Account old) change) {
    final int index = _accounts.indexWhere((Account a) => a.id == id);
    if (index == -1) return;
    _accounts[index] = change(_accounts[index]);
  }
}
