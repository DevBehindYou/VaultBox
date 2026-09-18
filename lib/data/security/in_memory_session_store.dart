import "../../domain/security/session.dart";

/// In-memory [SessionStore]. Nothing is persisted, by design (see [SessionStore]).
final class InMemorySessionStore implements SessionStore {
  final Map<String, Session> _sessions = <String, Session>{};

  /// Number of stored sessions (tests, diagnostics).
  int get length => _sessions.length;

  /// The stored hashes — lets tests prove no plaintext token is kept.
  Iterable<String> get storedHashes => _sessions.keys;

  @override
  Future<void> put(Session session) async => _sessions[session.tokenHash] = session;

  @override
  Future<Session?> get(String tokenHash) async => _sessions[tokenHash];

  @override
  Future<void> delete(String tokenHash) async => _sessions.remove(tokenHash);

  @override
  Future<void> deleteForAccount(String accountId) async {
    _sessions.removeWhere((String _, Session s) => s.accountId == accountId);
  }

  @override
  Future<int> deleteWhere(bool Function(Session session) test) async {
    final int before = _sessions.length;
    _sessions.removeWhere((String _, Session s) => test(s));
    return before - _sessions.length;
  }
}
