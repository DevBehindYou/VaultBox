import "../entities/account.dart";
import "../repositories/account_repository.dart";
import "login_throttle.dart";
import "password_hasher.dart";
import "password_policy.dart";
import "session.dart";
import "session_manager.dart";
import "username_policy.dart";

/// How a login attempt ended. Wrong username and wrong password are the SAME
/// outcome on purpose — nothing here (or in timing) says which accounts exist.
sealed class LoginOutcome {
  const LoginOutcome();
}

final class LoginSucceeded extends LoginOutcome {
  const LoginSucceeded({required this.issued, required this.account});

  final IssuedSession issued;
  final Account account;
}

final class LoginRejected extends LoginOutcome {
  const LoginRejected();
}

/// Too many recent failures for this address/account: try again after [retryAfter].
final class LoginThrottled extends LoginOutcome {
  const LoginThrottled(this.retryAfter);

  final Duration retryAfter;
}

/// Too many password checks already running (each one is deliberately heavy).
final class LoginBusy extends LoginOutcome {
  const LoginBusy();
}

/// Password login: throttle → look up → verify (constant work whether or not the
/// account exists) → issue a session.
///
/// Throttling is two-layered. The per-account key (`address|username`) slows
/// guessing one account without letting a stranger lock the real owner out from
/// another address; the per-address key slows an attacker who rotates usernames.
final class LoginService {
  LoginService({
    required AccountRepository accounts,
    required PasswordHasher hasher,
    required SessionManager sessions,
    required LoginThrottle perAccountThrottle,
    required LoginThrottle perAddressThrottle,
    this.maxConcurrentChecks = 2,
  }) : _accounts = accounts,
       _hasher = hasher,
       _sessions = sessions,
       _perAccount = perAccountThrottle,
       _perAddress = perAddressThrottle;

  final AccountRepository _accounts;
  final PasswordHasher _hasher;
  final SessionManager _sessions;
  final LoginThrottle _perAccount;
  final LoginThrottle _perAddress;

  /// Each Argon2id check needs ~19 MiB, so unlimited parallel logins would let
  /// anyone on the network exhaust the phone's memory.
  final int maxConcurrentChecks;

  int _inFlight = 0;
  Future<String>? _dummyHash;

  /// Pre-computes the decoy hash used for unknown usernames, so the first such
  /// attempt isn't measurably slower than the rest.
  Future<void> warmUp() => _decoy();

  Future<String> _decoy() => _dummyHash ??= _hasher.hash("vaultbox-decoy-password");

  Future<LoginOutcome> login({
    required String username,
    required String password,
    required String remoteAddress,
  }) async {
    final String name = UsernamePolicy.normalize(username);
    final String accountKey = "$remoteAddress|$name";

    final Duration? wait = _longest(
      _perAccount.lockedFor(accountKey),
      _perAddress.lockedFor(remoteAddress),
    );
    if (wait != null) return LoginThrottled(wait);

    // Can't possibly match anything stored: fail without spending a hash.
    if (name.isEmpty ||
        name.length > UsernamePolicy.maxLength ||
        password.isEmpty ||
        password.length > PasswordPolicy.maxLength) {
      _recordFailure(accountKey, remoteAddress);
      return const LoginRejected();
    }

    if (_inFlight >= maxConcurrentChecks) return const LoginBusy();
    _inFlight++;
    try {
      final Account? account = await _accounts.findByUsername(name);
      final String encoded = account?.passwordHash ?? await _decoy();
      final bool matches = await _hasher.verify(password, encoded);

      if (account == null || !matches) {
        _recordFailure(accountKey, remoteAddress);
        return const LoginRejected();
      }

      _perAccount.recordSuccess(accountKey);
      if (_hasher.needsRehash(account.passwordHash)) {
        await _accounts.updatePasswordHash(account.id, await _hasher.hash(password));
      }
      return LoginSucceeded(
        issued: await _sessions.issue(accountId: account.id),
        account: account,
      );
    } finally {
      _inFlight--;
    }
  }

  void _recordFailure(String accountKey, String remoteAddress) {
    _perAccount.recordFailure(accountKey);
    _perAddress.recordFailure(remoteAddress);
  }

  static Duration? _longest(Duration? a, Duration? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a >= b ? a : b;
  }
}
