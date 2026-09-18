import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/security/in_memory_session_store.dart";
import "package:vaultbox/domain/security/session.dart";
import "package:vaultbox/domain/security/session_manager.dart";

import "../helpers/fake_clock.dart";

void main() {
  late FakeClock clock;
  late InMemorySessionStore store;
  late SessionManager sessions;

  setUp(() {
    clock = FakeClock();
    store = InMemorySessionStore();
    sessions = SessionManager(store: store, clock: clock); // 30 min idle, 12 h absolute
  });

  test("issues a 256-bit url-safe token and validates it", () async {
    final IssuedSession issued = await sessions.issue(accountId: "admin");

    expect(issued.token, matches(RegExp(r"^[A-Za-z0-9_-]{43}$")));
    final Session? session = await sessions.validate(issued.token);
    expect(session, isNotNull);
    expect(session!.accountId, "admin");
  });

  test("only the hash is stored — never the token", () async {
    final IssuedSession issued = await sessions.issue(accountId: "admin");

    expect(store.storedHashes, <String>[SessionManager.hashToken(issued.token)]);
    expect(store.storedHashes, isNot(contains(issued.token)));
    expect(issued.session.tokenHash, isNot(issued.token));
  });

  test("tokens are unique", () async {
    final Set<String> tokens = <String>{
      for (int i = 0; i < 50; i++) (await sessions.issue(accountId: "admin")).token,
    };
    expect(tokens, hasLength(50));
  });

  test("unknown, empty, oversized and altered tokens are rejected", () async {
    final IssuedSession issued = await sessions.issue(accountId: "admin");

    expect(await sessions.validate("nope"), isNull);
    expect(await sessions.validate(""), isNull);
    expect(await sessions.validate("x" * 1000), isNull);
    expect(await sessions.validate("${issued.token}x"), isNull);
    expect(await sessions.validate(issued.token.substring(1)), isNull);
  });

  test("idle timeout: expires after 30 minutes of silence", () async {
    final IssuedSession issued = await sessions.issue(accountId: "admin");

    clock.advance(const Duration(minutes: 29));
    expect(await sessions.validate(issued.token), isNotNull);

    clock.advance(const Duration(minutes: 31)); // 31 min since last use
    expect(await sessions.validate(issued.token), isNull);
    expect(store.length, 0, reason: "an expired session is deleted");
  });

  test("activity slides the idle window forward", () async {
    final IssuedSession issued = await sessions.issue(accountId: "admin");

    for (int i = 0; i < 6; i++) {
      clock.advance(const Duration(minutes: 20));
      expect(await sessions.validate(issued.token), isNotNull, reason: "used every 20 min");
    }
  });

  test("absolute timeout: a constantly-used token still dies at 12 hours", () async {
    final IssuedSession issued = await sessions.issue(accountId: "admin");

    for (int i = 0; i < 35; i++) {
      clock.advance(const Duration(minutes: 20)); // 11h40 elapsed, always fresh
      expect(await sessions.validate(issued.token), isNotNull);
    }
    clock.advance(const Duration(minutes: 30)); // past 12 h
    expect(await sessions.validate(issued.token), isNull);
  });

  test("revoke logs one session out", () async {
    final IssuedSession a = await sessions.issue(accountId: "admin");
    final IssuedSession b = await sessions.issue(accountId: "admin");

    await sessions.revoke(a.token);
    expect(await sessions.validate(a.token), isNull);
    expect(await sessions.validate(b.token), isNotNull);
  });

  test("revokeAllFor logs an account out everywhere, and only that account", () async {
    final IssuedSession a1 = await sessions.issue(accountId: "admin");
    final IssuedSession a2 = await sessions.issue(accountId: "admin");
    final IssuedSession other = await sessions.issue(accountId: "guest");

    await sessions.revokeAllFor("admin");

    expect(await sessions.validate(a1.token), isNull);
    expect(await sessions.validate(a2.token), isNull);
    expect(await sessions.validate(other.token), isNotNull);
  });

  test("purgeExpired removes only expired sessions", () async {
    await sessions.issue(accountId: "old");
    clock.advance(const Duration(minutes: 45));
    final IssuedSession fresh = await sessions.issue(accountId: "new");

    expect(await sessions.purgeExpired(), 1);
    expect(store.length, 1);
    expect(await sessions.validate(fresh.token), isNotNull);
  });
}
