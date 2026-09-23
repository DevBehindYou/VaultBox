import "dart:async";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/data/security/in_memory_session_store.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/security/login_service.dart";
import "package:vaultbox/domain/security/login_throttle.dart";
import "package:vaultbox/domain/security/password_hasher.dart";
import "package:vaultbox/domain/security/session_manager.dart";

import "../helpers/fake_clock.dart";

/// A hasher that counts work, can report "old parameters", and can be held open.
final class _CountingHasher implements PasswordHasher {
  int hashCalls = 0;
  int verifyCalls = 0;
  bool rehashNeeded = false;
  Completer<void>? gate;

  @override
  Future<String> hash(String password) async {
    hashCalls++;
    return "fake:$password";
  }

  @override
  Future<bool> verify(String password, String encoded) async {
    verifyCalls++;
    await gate?.future;
    return encoded == "fake:$password";
  }

  @override
  bool needsRehash(String encoded) => rehashNeeded;
}

void main() {
  const String goodPassword = "correct horse battery";

  late FakeClock clock;
  late _CountingHasher hasher;
  late InMemoryAccountRepository accounts;
  late InMemorySessionStore store;
  late SessionManager sessions;
  late LoginService service;

  setUp(() {
    clock = FakeClock();
    hasher = _CountingHasher();
    accounts = InMemoryAccountRepository(<Account>[
      Account(id: "a1", username: "admin", passwordHash: "fake:$goodPassword", createdAt: clock.now()),
    ]);
    store = InMemorySessionStore();
    sessions = SessionManager(store: store, clock: clock);
    service = LoginService(
      accounts: accounts,
      hasher: hasher,
      sessions: sessions,
      perAccountThrottle: LoginThrottle(clock: clock),
      perAddressThrottle: LoginThrottle(clock: clock, freeAttempts: 20),
    );
  });

  Future<LoginOutcome> attempt({
    String username = "admin",
    String password = goodPassword,
    String address = "192.168.1.10",
  }) => service.login(username: username, password: password, remoteAddress: address);

  test("the right password issues a session that validates", () async {
    final LoginOutcome outcome = await attempt();

    expect(outcome, isA<LoginSucceeded>());
    final LoginSucceeded ok = outcome as LoginSucceeded;
    expect(ok.account.username, "admin");
    expect((await sessions.validate(ok.issued.token))?.accountId, "a1");
    expect(store.storedHashes, isNot(contains(ok.issued.token)), reason: "only the hash is stored");
  });

  test("the username is trimmed and case-insensitive", () async {
    expect(await attempt(username: "  ADMIN "), isA<LoginSucceeded>());
  });

  test("a wrong password and an unknown user look exactly the same", () async {
    final LoginOutcome wrongPassword = await attempt(password: "not the password");
    final LoginOutcome unknownUser = await attempt(username: "nobody");

    expect(wrongPassword, isA<LoginRejected>());
    expect(unknownUser, isA<LoginRejected>());
  });

  test("an unknown user still costs a password check (no timing tell)", () async {
    await service.warmUp();
    hasher.verifyCalls = 0;

    await attempt(username: "nobody");

    expect(hasher.verifyCalls, 1);
  });

  test("the decoy password can't be used to log in as a missing user", () async {
    expect(await attempt(username: "nobody", password: "vaultbox-decoy-password"), isA<LoginRejected>());
  });

  test("input that can't match anything is refused without hashing", () async {
    hasher.verifyCalls = 0;

    expect(await attempt(password: ""), isA<LoginRejected>());
    expect(await attempt(password: "x" * 129), isA<LoginRejected>());
    expect(await attempt(username: ""), isA<LoginRejected>());
    expect(await attempt(username: "u" * 33), isA<LoginRejected>());

    expect(hasher.verifyCalls, 0);
  });

  test("five failures lock that account+address, even for the right password", () async {
    for (int i = 0; i < 5; i++) {
      expect(await attempt(password: "wrong $i"), isA<LoginRejected>());
    }

    final LoginOutcome locked = await attempt();
    expect(locked, isA<LoginThrottled>());
    expect((locked as LoginThrottled).retryAfter, const Duration(seconds: 30));

    clock.advance(const Duration(seconds: 31));
    expect(await attempt(), isA<LoginSucceeded>());
  });

  test("locking one address doesn't lock the owner out from another", () async {
    for (int i = 0; i < 5; i++) {
      await attempt(password: "wrong $i", address: "192.168.1.66");
    }
    expect(await attempt(address: "192.168.1.66"), isA<LoginThrottled>());

    expect(await attempt(address: "192.168.1.10"), isA<LoginSucceeded>());
  });

  test("rotating usernames from one address is caught by the per-address limit", () async {
    for (int i = 0; i < 20; i++) {
      expect(await attempt(username: "guess$i", password: "wrong", address: "10.0.0.9"), isA<LoginRejected>());
    }

    expect(await attempt(username: "yet.another", address: "10.0.0.9"), isA<LoginThrottled>());
    expect(await attempt(address: "10.0.0.9"), isA<LoginThrottled>(), reason: "even the real account");
  });

  test("a success clears the account's failure count", () async {
    for (int i = 0; i < 4; i++) {
      await attempt(password: "wrong $i");
    }
    expect(await attempt(), isA<LoginSucceeded>());

    for (int i = 0; i < 4; i++) {
      expect(await attempt(password: "wrong again $i"), isA<LoginRejected>());
    }
  });

  test("too many checks at once are turned away, not queued", () async {
    hasher.gate = Completer<void>();
    final Future<LoginOutcome> first = attempt(address: "10.0.0.1");
    final Future<LoginOutcome> second = attempt(address: "10.0.0.2");
    await pumpEventQueue();

    expect(await attempt(address: "10.0.0.3"), isA<LoginBusy>());

    hasher.gate!.complete();
    expect(await first, isA<LoginSucceeded>());
    expect(await second, isA<LoginSucceeded>());
    expect(await attempt(address: "10.0.0.3"), isA<LoginSucceeded>(), reason: "capacity is released");
  });

  test("a hash made with old parameters is upgraded on a good login", () async {
    hasher.rehashNeeded = true;
    hasher.hashCalls = 0;

    expect(await attempt(), isA<LoginSucceeded>());

    expect(hasher.hashCalls, 1);
    expect((await accounts.findById("a1"))?.passwordHash, "fake:$goodPassword");
  });
}
