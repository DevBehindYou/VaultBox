import "dart:convert";
import "dart:math";

import "package:crypto/crypto.dart";

import "../repositories/clock.dart";

/// What a download ticket lets its holder fetch: one file, as one account.
final class DownloadTicket {
  const DownloadTicket({
    required this.accountId,
    required this.sessionHash,
    required this.rootId,
    required this.path,
    required this.expiresAt,
  });

  final String accountId;

  /// Which login session asked for it — logging out revokes its tickets.
  final String sessionHash;
  final String rootId;

  /// The file's path within the root, as a wire string (re-validated on use).
  final String path;
  final DateTime expiresAt;
}

/// Short-lived, read-only links for the browser portal.
///
/// A browser can't attach an `Authorization` header to a plain download link, an
/// `<img>` or a `<video>`; and fetching a whole file into memory to hand it over
/// doesn't work for big files. So a logged-in page asks for a ticket for ONE
/// file and uses `/d/<ticket>` as the link. A ticket:
///  - is 256 bits from a CSPRNG (only its hash is kept here);
///  - opens exactly that one file, read-only — it is never the session token;
///  - expires after [lifetime] and dies with the session that requested it;
///  - is re-checked against the [Authorizer] every time it is used.
///
/// Held in memory only, and bounded ([maxTickets]) so it can't grow without limit.
final class DownloadTicketService {
  DownloadTicketService({
    required Clock clock,
    this.lifetime = const Duration(minutes: 15),
    this.maxTickets = 5000,
    Random? random,
  }) : _clock = clock,
       _random = random ?? Random.secure();

  final Clock _clock;
  final Random _random;
  final Duration lifetime;
  final int maxTickets;

  /// Insertion-ordered, so the oldest ticket is first (evicted when full).
  final Map<String, DownloadTicket> _tickets = <String, DownloadTicket>{};

  int get length => _tickets.length;

  String issue({
    required String accountId,
    required String sessionHash,
    required String rootId,
    required String path,
  }) {
    final String token = base64Url
        .encode(List<int>.generate(32, (_) => _random.nextInt(256)))
        .replaceAll("=", "");
    _tickets[_hash(token)] = DownloadTicket(
      accountId: accountId,
      sessionHash: sessionHash,
      rootId: rootId,
      path: path,
      expiresAt: _clock.now().add(lifetime),
    );
    if (_tickets.length > maxTickets) _tickets.remove(_tickets.keys.first);
    return token;
  }

  /// The ticket for [token] if it exists and hasn't expired.
  DownloadTicket? resolve(String token) {
    if (token.isEmpty || token.length > 128) return null;
    final String key = _hash(token);
    final DownloadTicket? ticket = _tickets[key];
    if (ticket == null) return null;
    if (!_clock.now().isBefore(ticket.expiresAt)) {
      _tickets.remove(key);
      return null;
    }
    return ticket;
  }

  /// Revokes everything a session asked for (logout, or a session that ended).
  void revokeSession(String sessionHash) {
    _tickets.removeWhere((String _, DownloadTicket t) => t.sessionHash == sessionHash);
  }

  /// Drops expired tickets; returns how many.
  int purgeExpired() {
    final DateTime now = _clock.now();
    final int before = _tickets.length;
    _tickets.removeWhere((String _, DownloadTicket t) => !now.isBefore(t.expiresAt));
    return before - _tickets.length;
  }

  static String _hash(String token) => sha256.convert(utf8.encode(token)).toString();
}
