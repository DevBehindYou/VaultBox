/// A logged-in session. Only the SHA-256 of the token is ever stored ([tokenHash]);
/// the token itself exists in memory just long enough to hand to the client.
final class Session {
  const Session({
    required this.tokenHash,
    required this.accountId,
    required this.createdAt,
    required this.lastSeenAt,
    this.credentialVersion = 0,
  });

  final String tokenHash;
  final String accountId;
  final DateTime createdAt;

  /// Refreshed on every valid request (drives the idle timeout).
  final DateTime lastSeenAt;

  /// The account's `credentialVersion` when this session was opened. If the
  /// account's value has moved on (password changed, account disabled) the
  /// session is dead.
  final int credentialVersion;

  Session touched(DateTime now) => Session(
    tokenHash: tokenHash,
    accountId: accountId,
    createdAt: createdAt,
    lastSeenAt: now,
    credentialVersion: credentialVersion,
  );
}

/// What login returns: the plaintext [token] (shown once, never stored) plus the
/// stored [session] record.
final class IssuedSession {
  const IssuedSession({required this.token, required this.session});

  final String token;
  final Session session;
}

/// Where sessions live. The in-memory implementation is deliberate for now: a
/// service restart simply logs everyone out, and no token material touches disk.
abstract interface class SessionStore {
  Future<void> put(Session session);
  Future<Session?> get(String tokenHash);
  Future<void> delete(String tokenHash);
  Future<void> deleteForAccount(String accountId);
  Future<int> deleteWhere(bool Function(Session session) test);
}
