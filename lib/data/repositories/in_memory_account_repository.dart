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
  Future<Account?> findByUsername(String username) async {
    for (final Account account in _accounts) {
      if (account.username == username) return account;
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
  Future<void> updatePasswordHash(String id, String passwordHash) async {
    final int index = _accounts.indexWhere((Account a) => a.id == id);
    if (index == -1) return;
    final Account old = _accounts[index];
    _accounts[index] = Account(
      id: old.id,
      username: old.username,
      passwordHash: passwordHash,
      createdAt: old.createdAt,
    );
  }
}
