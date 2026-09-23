import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/entities/access_rule.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/security/authorizer.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";

void main() {
  const AclAuthorizer authorizer = AclAuthorizer();
  const StorageRoot phone = StorageRoot(
    id: "r1",
    displayName: "Phone",
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://r1",
    capabilities: StorageCapabilities.fullLocal(),
  );
  const StorageRoot card = StorageRoot(
    id: "r2",
    displayName: "Card",
    backendType: StorageBackendType.memory,
    uriOrPath: "memory://r2",
    capabilities: StorageCapabilities.fullLocal(),
  );

  StoragePath p(String path, {String root = "r1"}) => StoragePath.parseDecoded(root, path);

  Account member(List<AccessRule> rules, {bool enabled = true}) => Account(
    id: "m1",
    username: "bob",
    passwordHash: "x",
    createdAt: DateTime.utc(2026),
    role: AccountRole.member,
    isEnabled: enabled,
    rules: rules,
  );

  AccessRule rule(String path, Set<Permission> permissions, {String root = "r1"}) =>
      AccessRule(id: "rule-$path", accountId: "m1", rootId: root, pathPrefix: path, permissions: permissions);

  final Account admin = Account(id: "a1", username: "admin", passwordHash: "x", createdAt: DateTime.utc(2026));

  bool can(Account account, Permission permission, String path, {StorageRoot root = phone}) =>
      authorizer.allows(account, permission, root, p(path, root: root.id));

  test("an admin may do everything, everywhere", () {
    for (final Permission permission in Permission.values) {
      expect(can(admin, permission, "/anything/at/all"), isTrue);
      expect(can(admin, permission, "/", root: card), isTrue);
    }
  });

  test("a disabled account may do nothing, even an admin", () {
    final Account off = admin.copyWith(isEnabled: false);
    for (final Permission permission in Permission.values) {
      expect(can(off, permission, "/"), isFalse);
    }
    expect(can(member(<AccessRule>[rule("/", AccessRule.everything)], enabled: false), Permission.read, "/a"), isFalse);
  });

  test("a member with no rules has no access at all", () {
    final Account nobody = member(const <AccessRule>[]);
    for (final Permission permission in Permission.values) {
      expect(can(nobody, permission, "/"), isFalse);
      expect(can(nobody, permission, "/anything"), isFalse);
    }
  });

  test("a grant covers its folder and everything below, for exactly the granted actions", () {
    final Account bob = member(<AccessRule>[rule("/Photos", AccessRule.readWrite)]);

    expect(can(bob, Permission.read, "/Photos"), isTrue);
    expect(can(bob, Permission.read, "/Photos/2026/a.jpg"), isTrue);
    expect(can(bob, Permission.write, "/Photos/2026/new.jpg"), isTrue);
    expect(can(bob, Permission.delete, "/Photos/a.jpg"), isFalse, reason: "delete wasn't granted");
  });

  test("a grant does not leak sideways: siblings and look-alike names stay closed", () {
    final Account bob = member(<AccessRule>[rule("/Photos", AccessRule.everything)]);

    expect(can(bob, Permission.read, "/Documents"), isFalse);
    expect(can(bob, Permission.read, "/Photos2"), isFalse, reason: "shares a prefix, not a folder");
    expect(can(bob, Permission.read, "/photos"), isFalse, reason: "names are case-sensitive");
    expect(can(bob, Permission.write, "/", root: phone), isFalse);
  });

  test("the folders above a grant are readable (to reach it) but never writable or deletable", () {
    final Account bob = member(<AccessRule>[rule("/Photos/2026", AccessRule.everything)]);

    expect(can(bob, Permission.read, "/"), isTrue);
    expect(can(bob, Permission.read, "/Photos"), isTrue);
    expect(can(bob, Permission.write, "/Photos"), isFalse);
    expect(can(bob, Permission.delete, "/Photos"), isFalse);
    expect(can(bob, Permission.read, "/Photos/2025"), isFalse, reason: "a sibling of the granted folder");
    expect(can(bob, Permission.read, "/Other"), isFalse);
  });

  test("a rule for the whole root ('/') grants everything in that root only", () {
    final Account bob = member(<AccessRule>[rule("/", AccessRule.readOnly)]);

    expect(can(bob, Permission.read, "/deep/down/file"), isTrue);
    expect(can(bob, Permission.write, "/deep/down/file"), isFalse);
    expect(can(bob, Permission.read, "/x", root: card), isFalse, reason: "another storage location");
  });

  test("rules add up; each root is separate", () {
    final Account bob = member(<AccessRule>[
      rule("/Photos", AccessRule.readOnly),
      rule("/Photos/Upload", AccessRule.readWrite),
      rule("/Backups", AccessRule.everything, root: "r2"),
    ]);

    expect(can(bob, Permission.write, "/Photos/Upload/x"), isTrue);
    expect(can(bob, Permission.write, "/Photos/x"), isFalse);
    expect(can(bob, Permission.delete, "/Backups/old", root: card), isTrue);
    expect(can(bob, Permission.read, "/Backups"), isFalse, reason: "that rule is for the card, not the phone");
  });

  test("a rule whose stored path is damaged grants nothing", () {
    final Account bob = member(<AccessRule>[rule("/a/../b", AccessRule.everything)]);

    expect(can(bob, Permission.read, "/b"), isFalse);
    expect(can(bob, Permission.read, "/"), isFalse);
    expect(can(bob, Permission.read, "/a"), isFalse);
  });

  test("SingleAdminAuthorizer still allows everything (tests only)", () {
    expect(const SingleAdminAuthorizer().allows(member(const <AccessRule>[]), Permission.delete, phone, p("/x")), isTrue);
  });
}
