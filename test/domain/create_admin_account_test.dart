import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/repositories/id_generator.dart";
import "package:vaultbox/domain/security/username_policy.dart";
import "package:vaultbox/domain/usecases/create_admin_account.dart";

import "../helpers/fake_clock.dart";
import "../helpers/fake_password_hasher.dart";

final class _Ids implements IdGenerator {
  int _n = 0;
  @override
  String newId() => "acct-${_n++}";
}

void main() {
  const String goodPassword = "correct horse battery";

  late InMemoryAccountRepository accounts;
  late FakePasswordHasher hasher;
  late FakeClock clock;
  late CreateAdminAccount create;

  setUp(() {
    accounts = InMemoryAccountRepository();
    hasher = FakePasswordHasher();
    clock = FakeClock();
    create = CreateAdminAccount(accounts, hasher, _Ids(), clock);
  });

  test("creates the account: normalized name, HASHED password, timestamp", () async {
    final Account account = await create(username: "  Admin.User ", password: goodPassword);

    expect(account.username, "admin.user");
    expect(account.passwordHash, isNot(goodPassword), reason: "the password itself is never stored");
    expect(account.passwordHash, "fake:$goodPassword");
    expect(account.createdAt, clock.current);
    expect(await accounts.count(), 1);
    expect((await accounts.findByUsername("admin.user"))?.id, account.id);
  });

  test("a bad username is rejected before any hashing", () async {
    for (final String bad in <String>["ab", "x" * 40, "-leading", "has space", "emoji😀name"]) {
      await expectLater(
        create(username: bad, password: goodPassword),
        throwsA(isA<ValidationFailure>()),
        reason: bad,
      );
    }
    expect(hasher.hashCalls, 0, reason: "cheap validation first — no Argon2 for input we'd reject");
    expect(await accounts.count(), 0);
  });

  test("a weak password is rejected before any hashing", () async {
    for (final String weak in <String>["short", "aaaaaaaaaaaaaaaa", "my-admin-password-x"]) {
      await expectLater(
        create(username: "admin", password: weak),
        throwsA(isA<ValidationFailure>()),
        reason: weak,
      );
    }
    expect(hasher.hashCalls, 0);
    expect(await accounts.count(), 0);
  });

  test("only one admin can ever be created this way", () async {
    await create(username: "admin", password: goodPassword);

    await expectLater(
      create(username: "second", password: goodPassword),
      throwsA(
        isA<ValidationFailure>().having((ValidationFailure f) => f.message, "message", contains("already exists")),
      ),
    );
    expect(await accounts.count(), 1);
  });

  test("two racing first-admin requests: exactly one wins", () async {
    Future<Object> attempt(String name) async {
      try {
        return await create(username: name, password: goodPassword);
      } on ValidationFailure catch (failure) {
        return failure;
      }
    }

    final List<Object> results = await Future.wait(<Future<Object>>[attempt("first"), attempt("second")]);

    expect(results.whereType<Account>(), hasLength(1));
    expect(results.whereType<ValidationFailure>(), hasLength(1));
    expect(await accounts.count(), 1);
  });

  group("UsernamePolicy", () {
    test("normalizes case and whitespace", () {
      expect(UsernamePolicy.normalize("  MiXeD  "), "mixed");
    });

    test("accepts sensible names", () {
      for (final String ok in <String>["admin", "a.b-c_d", "user123", "0day"]) {
        expect(UsernamePolicy.validate(ok), isNull, reason: ok);
      }
    });
  });
}
