import "dart:convert";
import "dart:math";

import "package:crypto/crypto.dart";

import "../../domain/entities/account.dart";
import "../../domain/repositories/account_repository.dart";
import "../../domain/repositories/clock.dart";
import "../../domain/security/login_service.dart";
import "../api/api_types.dart";

sealed class DavAuthResult {
  const DavAuthResult();
}

final class DavAllowed extends DavAuthResult {
  const DavAllowed(this.account);

  final Account account;
}

/// No or wrong credentials: answer 401 with a Basic challenge.
final class DavUnauthorized extends DavAuthResult {
  const DavUnauthorized();
}

final class DavThrottled extends DavAuthResult {
  const DavThrottled(this.retryAfter);

  final Duration retryAfter;
}

final class DavBusy extends DavAuthResult {
  const DavBusy();
}

/// HTTP Basic authentication for WebDAV clients (Windows, macOS, Linux and
/// Android clients all speak it; none of them can use a bearer token).
///
/// Basic sends the password with every request, but Argon2id takes a noticeable
/// amount of time and memory by design, so it can't run per request. A right
/// answer is therefore remembered for [cacheFor] as an entry keyed by a
/// SHA-256 of (per-run random salt, username, password): the password itself is
/// never stored, the entry only says "this exact pair was verified", and it
/// dies with the process or after [cacheFor] — a changed password takes effect
/// within that window (or at once via [clear]). Wrong guesses always go through
/// the throttled, constant-work [LoginService.checkCredentials].
final class DavAuthenticator {
  DavAuthenticator({
    required LoginService login,
    required AccountRepository accounts,
    required Clock clock,
    this.cacheFor = const Duration(minutes: 5),
    this.maxEntries = 200,
    Random? random,
  }) : _login = login,
       _accounts = accounts,
       _clock = clock,
       _salt = _newSalt(random ?? Random.secure());

  final LoginService _login;
  final AccountRepository _accounts;
  final Clock _clock;
  final Duration cacheFor;
  final int maxEntries;
  final List<int> _salt;

  /// Insertion-ordered: the oldest entry is first.
  final Map<String, _Verified> _verified = <String, _Verified>{};

  static List<int> _newSalt(Random random) => List<int>.generate(32, (_) => random.nextInt(256));

  /// Forgets every remembered login (after a password change or account removal).
  void clear() => _verified.clear();

  Future<DavAuthResult> authenticate(ApiRequest request) async {
    final ({String username, String password})? credentials = _basicCredentials(request.header("authorization"));
    if (credentials == null) return const DavUnauthorized();

    final String key = _keyFor(credentials.username, credentials.password);
    final DateTime now = _clock.now();
    final _Verified? remembered = _verified[key];
    if (remembered != null) {
      if (now.isBefore(remembered.until)) {
        final Account? account = await _accounts.findById(remembered.accountId);
        if (account != null && account.isEnabled && account.credentialVersion == remembered.credentialVersion) {
          return DavAllowed(account);
        }
      }
      _verified.remove(key);
    }

    final CredentialCheck check = await _login.checkCredentials(
      username: credentials.username,
      password: credentials.password,
      remoteAddress: request.remoteAddress,
    );
    switch (check) {
      case CredentialsValid(:final Account account):
        _verified[key] = _Verified(account.id, now.add(cacheFor), account.credentialVersion);
        if (_verified.length > maxEntries) _verified.remove(_verified.keys.first);
        return DavAllowed(account);
      case CredentialsRejected():
        return const DavUnauthorized();
      case CredentialsThrottled(:final Duration retryAfter):
        return DavThrottled(retryAfter);
      case CredentialsBusy():
        return const DavBusy();
    }
  }

  String _keyFor(String username, String password) {
    final List<int> bytes = <int>[..._salt, ...utf8.encode(username), 0, ...utf8.encode(password)];
    return sha256.convert(bytes).toString();
  }

  /// `Authorization: Basic base64(user:password)`; anything else -> null.
  static ({String username, String password})? _basicCredentials(String? header) {
    if (header == null || header.length > 2048) return null;
    final int space = header.indexOf(" ");
    if (space < 0 || header.substring(0, space).toLowerCase() != "basic") return null;
    final String decoded;
    try {
      decoded = utf8.decode(base64.decode(base64.normalize(header.substring(space + 1).trim())));
    } on FormatException {
      return null;
    }
    final int colon = decoded.indexOf(":");
    if (colon < 0) return null;
    return (username: decoded.substring(0, colon), password: decoded.substring(colon + 1));
  }
}

final class _Verified {
  const _Verified(this.accountId, this.until, this.credentialVersion);

  final String accountId;
  final DateTime until;
  final int credentialVersion;
}
