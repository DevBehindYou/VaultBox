import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/data/repositories/in_memory_account_repository.dart";
import "package:vaultbox/data/repositories/in_memory_share_repository.dart";
import "package:vaultbox/domain/entities/access_rule.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/share.dart";
import "package:vaultbox/domain/repositories/id_generator.dart";
import "package:vaultbox/domain/security/permission.dart";
import "package:vaultbox/domain/usecases/manage_accounts.dart";

import "../helpers/fake_clock.dart";
import "../helpers/fake_password_hasher.dart";

final class _SequentialIds implements IdGenerator {
  int _next = 0;

  @override
  String newId() => "id${_next++}";
}

void main() {
  late InMemoryAccountRepository accounts;
  late InMemoryShareRepository shares;
  late FakePasswordHasher hasher;
  late _SequentialIds ids;
  late FakeClock clock;

  const String goodPassword = "correct horse battery";

  final Account admin = Account(id: "a1", username: "admin", passwordHash: "fake:x", createdAt: DateTime.utc(2026));

  setUp(() {
    accounts = InMemoryAccountRepository(<Account>[admin]);
    shares = InMemoryShareRepository();
    hasher = FakePasswordHasher();
    ids = _SequentialIds();
    clock = FakeClock();
  });

  Future<Account> addBob() => CreateUserAccount(accounts, hasher, ids, clock)(username: "Bob", password: goodPassword);

  Matcher validationFailure([String? text]) => throwsA(
    isA<ValidationFailure>().having(
      (ValidationFailure f) => f.message,
      "message",
      text == null ? isNotEmpty : contains(text),
    ),
  );

  group("CreateUserAccount", () {
    test("adds a MEMBER with a hashed password and a normalised name", () async {
      final Account bob = await addBob();

      expect(bob.username, "bob");
      expect(bob.role, AccountRole.member);
      expect(bob.isEnabled, isTrue);
      expect(bob.passwordHash, "fake:$goodPassword");
      expect(bob.passwordHash, isNot(goodPassword));
      expect(bob.rules, isEmpty);
      expect((await accounts.findByUsername("bob"))?.id, bob.id);
    });

    test("bad usernames and weak passwords are refused before any hashing", () async {
      final CreateUserAccount create = CreateUserAccount(accounts, hasher, ids, clock);

      await expectLater(create(username: "x", password: goodPassword), validationFailure());
      await expectLater(create(username: "bob", password: "short"), validationFailure());
      await expectLater(create(username: "bob", password: "bob is the password!"), validationFailure("username"));
      expect(hasher.hashCalls, 0);
      expect(await accounts.count(), 1);
    });

    test("a taken username is refused, whatever its case", () async {
      await addBob();
      final CreateUserAccount create = CreateUserAccount(accounts, hasher, ids, clock);

      await expectLater(create(username: "BOB", password: goodPassword), validationFailure("taken"));
      await expectLater(create(username: "admin", password: goodPassword), validationFailure("taken"));
      expect(await accounts.count(), 2);
    });
  });

  group("ChangePassword", () {
    test("replaces the hash and ends existing sessions (version bump)", () async {
      final Account bob = await addBob();
      expect(bob.credentialVersion, 0);

      await ChangePassword(accounts, hasher)(accountId: bob.id, newPassword: "another long passphrase");

      final Account after = (await accounts.findById(bob.id))!;
      expect(after.passwordHash, "fake:another long passphrase");
      expect(after.credentialVersion, 1);
    });

    test("the policy applies, and unknown accounts are refused", () async {
      final Account bob = await addBob();
      final ChangePassword change = ChangePassword(accounts, hasher);

      await expectLater(change(accountId: bob.id, newPassword: "short"), validationFailure());
      await expectLater(change(accountId: bob.id, newPassword: "bob is the password!"), validationFailure("username"));
      await expectLater(change(accountId: "ghost", newPassword: goodPassword), validationFailure("no longer exists"));
      expect((await accounts.findById(bob.id))!.credentialVersion, 0);
    });
  });

  group("SetAccountEnabled", () {
    test("disabling ends sessions; enabling doesn't need to", () async {
      final Account bob = await addBob();
      final SetAccountEnabled toggle = SetAccountEnabled(accounts);

      await toggle(accountId: bob.id, enabled: false);
      Account now = (await accounts.findById(bob.id))!;
      expect(now.isEnabled, isFalse);
      expect(now.credentialVersion, 1);

      await toggle(accountId: bob.id, enabled: true);
      now = (await accounts.findById(bob.id))!;
      expect(now.isEnabled, isTrue);
      expect(now.credentialVersion, 1, reason: "old sessions stay dead, but nothing new is invalidated");
    });

    test("the only enabled admin can't be turned off", () async {
      await expectLater(SetAccountEnabled(accounts)(accountId: "a1", enabled: false), validationFailure("only admin"));
      expect((await accounts.findById("a1"))!.isEnabled, isTrue);
    });
  });

  group("DeleteAccount", () {
    test("removes the account and the links it made", () async {
      final Account bob = await addBob();
      await shares.add(
        Share(
          id: "s1",
          kind: ShareKind.download,
          rootId: "r1",
          path: "/x",
          isDirectory: false,
          createdBy: bob.id,
          createdAt: clock.now(),
          tokenHash: "h1",
        ),
      );
      await shares.add(
        Share(
          id: "s2",
          kind: ShareKind.download,
          rootId: "r1",
          path: "/y",
          isDirectory: false,
          createdBy: "a1",
          createdAt: clock.now(),
          tokenHash: "h2",
        ),
      );

      await DeleteAccount(accounts, shares)(accountId: bob.id);

      expect(await accounts.findById(bob.id), isNull);
      expect((await shares.list()).map((Share s) => s.id), <String>["s2"]);
    });

    test("the only admin can't be removed; unknown ids are ignored", () async {
      await expectLater(DeleteAccount(accounts, shares)(accountId: "a1"), validationFailure("only admin"));
      await DeleteAccount(accounts, shares)(accountId: "ghost");
      expect(await accounts.count(), 1);
    });

    test("a second admin may be removed while another remains", () async {
      await accounts.create(
        Account(id: "a2", username: "boss2", passwordHash: "x", createdAt: clock.now()),
      );
      await DeleteAccount(accounts, shares)(accountId: "a2");
      expect(await accounts.countEnabledAdmins(), 1);
    });
  });

  group("SetAccessRules", () {
    Future<Account> bob() => addBob();
    AccessGrantInput grant(String path, Set<Permission> permissions, {String root = "r1"}) =>
        AccessGrantInput(rootId: root, path: path, permissions: permissions);

    test("stores normalised rules that carry the account and root", () async {
      final Account b = await bob();

      await SetAccessRules(accounts, ids)(
        accountId: b.id,
        grants: <AccessGrantInput>[
          grant("Photos//2026/", AccessRule.readWrite),
          grant("/", AccessRule.readOnly, root: "r2"),
        ],
      );

      final List<AccessRule> rules = (await accounts.findById(b.id))!.rules;
      expect(rules.map((AccessRule r) => r.pathPrefix), <String>["/Photos/2026", "/"]);
      expect(rules.map((AccessRule r) => r.rootId), <String>["r1", "r2"]);
      expect(rules.every((AccessRule r) => r.accountId == b.id), isTrue);
      expect(rules.first.permissions, AccessRule.readWrite);
    });

    test("replaces everything that was there", () async {
      final Account b = await bob();
      final SetAccessRules set = SetAccessRules(accounts, ids);
      await set(accountId: b.id, grants: <AccessGrantInput>[grant("/A", AccessRule.readOnly)]);
      await set(accountId: b.id, grants: <AccessGrantInput>[grant("/B", AccessRule.readOnly)]);

      expect((await accounts.findById(b.id))!.rules.map((AccessRule r) => r.pathPrefix), <String>["/B"]);
      await set(accountId: b.id, grants: const <AccessGrantInput>[]);
      expect((await accounts.findById(b.id))!.rules, isEmpty);
    });

    test("refuses grants without view access, empty grants, duplicates and unsafe paths", () async {
      final Account b = await bob();
      final SetAccessRules set = SetAccessRules(accounts, ids);

      await expectLater(set(accountId: b.id, grants: <AccessGrantInput>[grant("/A", const <Permission>{})]), validationFailure());
      await expectLater(
        set(accountId: b.id, grants: <AccessGrantInput>[grant("/A", const <Permission>{Permission.write})]),
        validationFailure("view"),
      );
      await expectLater(
        set(accountId: b.id, grants: <AccessGrantInput>[grant("/A", AccessRule.readOnly), grant("A/", AccessRule.readWrite)]),
        validationFailure("twice"),
      );
      await expectLater(set(accountId: b.id, grants: <AccessGrantInput>[grant("/a/../b", AccessRule.readOnly)]), validationFailure("allowed"));
      await expectLater(set(accountId: b.id, grants: <AccessGrantInput>[grant("/.vaultbox", AccessRule.readOnly)]), validationFailure("own"));
      expect((await accounts.findById(b.id))!.rules, isEmpty, reason: "nothing half-applied");
    });

    test("admins need no rules and unknown accounts are refused", () async {
      await expectLater(
        SetAccessRules(accounts, ids)(accountId: "a1", grants: <AccessGrantInput>[grant("/A", AccessRule.readOnly)]),
        validationFailure("Admins"),
      );
      await expectLater(
        SetAccessRules(accounts, ids)(accountId: "ghost", grants: <AccessGrantInput>[grant("/A", AccessRule.readOnly)]),
        validationFailure("no longer exists"),
      );
    });
  });
}
