import "dart:convert";
import "dart:math";

import "package:crypto/crypto.dart";

import "../repositories/clock.dart";
import "session.dart";

/// Issues and validates login sessions.
///
/// - Tokens are 256 bits from a CSPRNG (base64url, 43 chars). Only their SHA-256
///   is stored, so a leaked store can't be replayed as credentials.
/// - Two clocks: an IDLE timeout (slides forward on every valid use) and an
///   ABSOLUTE timeout (never extended) — an active attacker with a stolen token
///   still gets cut off.
/// - Time comes from [Clock] so expiry is deterministic in tests.
final class SessionManager {
  SessionManager({
    required SessionStore store,
    required Clock clock,
    this.idleTimeout = const Duration(minutes: 30),
    this.absoluteTimeout = const Duration(hours: 12),
    Random? random,
  }) : _store = store,
       _clock = clock,
       _random = random ?? Random.secure();

  final SessionStore _store;
  final Clock _clock;
  final Random _random;
  final Duration idleTimeout;
  final Duration absoluteTimeout;

  Future<IssuedSession> issue({required String accountId, int credentialVersion = 0}) async {
    final String token = _newToken();
    final DateTime now = _clock.now();
    final Session session = Session(
      tokenHash: hashToken(token),
      accountId: accountId,
      createdAt: now,
      lastSeenAt: now,
      credentialVersion: credentialVersion,
    );
    await _store.put(session);
    return IssuedSession(token: token, session: session);
  }

  /// Returns the (refreshed) session for a valid [token], else `null`. An
  /// expired session is deleted on the way out.
  Future<Session?> validate(String token) async {
    if (token.isEmpty || token.length > 256) return null;
    final String hash = hashToken(token);
    final Session? session = await _store.get(hash);
    if (session == null) return null;

    final DateTime now = _clock.now();
    if (_isExpired(session, now)) {
      await _store.delete(hash);
      return null;
    }
    final Session refreshed = session.touched(now);
    await _store.put(refreshed);
    return refreshed;
  }

  Future<void> revoke(String token) => _store.delete(hashToken(token));

  /// Logs an account out everywhere (e.g. after a password change).
  Future<void> revokeAllFor(String accountId) => _store.deleteForAccount(accountId);

  /// Drops every expired session; returns how many.
  Future<int> purgeExpired() {
    final DateTime now = _clock.now();
    return _store.deleteWhere((Session s) => _isExpired(s, now));
  }

  bool _isExpired(Session session, DateTime now) {
    return !now.isBefore(session.lastSeenAt.add(idleTimeout)) ||
        !now.isBefore(session.createdAt.add(absoluteTimeout));
  }

  String _newToken() {
    final List<int> bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll("=", "");
  }

  /// Hex SHA-256 of a token — the only form ever stored.
  static String hashToken(String token) => sha256.convert(utf8.encode(token)).toString();
}
