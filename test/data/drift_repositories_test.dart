import "dart:async";

import "package:drift/drift.dart" show Value;
import "package:drift/native.dart";
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/data/db/app_database.dart";
import "package:vaultbox/data/repositories/drift_account_repository.dart";
import "package:vaultbox/data/repositories/drift_recycle_bin_repository.dart";
import "package:vaultbox/data/repositories/drift_share_repository.dart";
import "package:vaultbox/data/repositories/drift_storage_root_repository.dart";
import "package:vaultbox/domain/entities/access_rule.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/recycle_item.dart";
import "package:vaultbox/domain/entities/share.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/security/permission.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";

/// Runs the Drift repositories against `NativeDatabase.memory()` — a real
/// sqlite engine, in memory, per test (doc §59: exercise the real
/// persistence code path, just not against the real device file). This is
/// the test that actually proves the fix for the gap flagged in
/// docs/IMPLEMENTATION_PLAN.md §H: a root or a recycle entry written here
/// must come back identical after being read through the same round-trip a
/// process restart would force it through (row → entity → row).
///
/// `flutter test` runs these on the host machine, not a device, so
/// `NativeDatabase` needs a resolvable libsqlite3 on that host. This is
/// usually present out of the box on macOS; on Linux it may need
/// `libsqlite3-dev` (or equivalent) installed. If this file fails to even
/// load the library rather than failing an assertion, that's the symptom —
/// not a bug in the repository code itself.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  group("DriftStorageRootRepository", () {
    late DriftStorageRootRepository repo;
    setUp(() => repo = DriftStorageRootRepository(db));

    const StorageRoot root = StorageRoot(
      id: "root-1",
      displayName: "This phone",
      backendType: StorageBackendType.direct,
      uriOrPath: "/data/user/0/com.vaultbox.app/files",
      capabilities: StorageCapabilities.fullLocal(),
      isDefault: true,
      freeBytes: 125200000000,
      totalBytes: 228000000000,
    );

    test("round-trips every field, including nullable byte counts", () async {
      await repo.addRoot(root);
      final StorageRoot? loaded = await repo.getRoot("root-1");

      expect(loaded, isNotNull);
      expect(loaded!.displayName, "This phone");
      expect(loaded.backendType, StorageBackendType.direct);
      expect(loaded.uriOrPath, root.uriOrPath);
      expect(loaded.isDefault, isTrue);
      expect(loaded.freeBytes, 125200000000);
      expect(loaded.totalBytes, 228000000000);
    });

    test("a SAF root round-trips its root document id and gets SAF capabilities", () async {
      await repo.addRoot(
        const StorageRoot(
          id: "saf-1",
          displayName: "SD card",
          backendType: StorageBackendType.saf,
          uriOrPath: "content://com.android.externalstorage.documents/tree/1234-ABCD%3A",
          rootDocumentId: "1234-ABCD:",
          capabilities: StorageCapabilities.saf(),
        ),
      );

      final StorageRoot? loaded = await repo.getRoot("saf-1");
      expect(loaded, isNotNull);
      expect(loaded!.rootDocumentId, "1234-ABCD:");
      expect(loaded.backendType, StorageBackendType.saf);
      expect(loaded.capabilities.canMoveWithinBackend, isFalse);
      expect(loaded.capabilities.supportsAtomicReplace, isFalse);
    });

    test("a non-SAF root has no root document id and full local capabilities", () async {
      await repo.addRoot(root);
      final StorageRoot? loaded = await repo.getRoot("root-1");
      expect(loaded!.rootDocumentId, isNull);
      expect(loaded.capabilities.canMoveWithinBackend, isTrue);
    });

    test("getRoot returns null for an id that was never added", () async {
      expect(await repo.getRoot("nope"), isNull);
    });

    test("setDefault clears every other root's flag", () async {
      await repo.addRoot(root);
      await repo.addRoot(
        const StorageRoot(
          id: "root-2",
          displayName: "SD card",
          backendType: StorageBackendType.direct,
          uriOrPath: "/storage/sdcard1",
          capabilities: StorageCapabilities.fullLocal(),
        ),
      );

      await repo.setDefault("root-2");

      final List<StorageRoot> all = await repo.listRoots();
      final Map<String, bool> defaults = <String, bool>{
        for (final StorageRoot r in all) r.id: r.isDefault,
      };
      expect(defaults, <String, bool>{"root-1": false, "root-2": true});
    });

    test("removeRoot deletes it", () async {
      await repo.addRoot(root);
      await repo.removeRoot("root-1");
      expect(await repo.getRoot("root-1"), isNull);
    });

    test("watchRoots emits on every mutation", () async {
      final List<int> counts = <int>[];
      final StreamSubscription<List<StorageRoot>> sub = repo.watchRoots().listen(
        (List<StorageRoot> roots) => counts.add(roots.length),
      );

      await pumpEventQueue();
      await repo.addRoot(root);
      await pumpEventQueue();
      await repo.removeRoot("root-1");
      await pumpEventQueue();

      await sub.cancel();
      expect(counts, <int>[0, 1, 0]);
    });
  });

  group("DriftRecycleBinRepository", () {
    late DriftRecycleBinRepository repo;
    setUp(() => repo = DriftRecycleBinRepository(db));

    final RecycleItem item = RecycleItem(
      id: "recycle-1",
      storageRootId: "root-1",
      recyclePath: StoragePath.parse("root-1", ".vaultbox/recycle/recycle-1__photo.jpg"),
      originalPath: StoragePath.parse("root-1", "DCIM/photo.jpg"),
      originalName: "photo.jpg",
      deletedAt: DateTime.utc(2026, 9, 16, 12, 0),
      purgeAfter: DateTime.utc(2026, 10, 16, 12, 0),
      sizeBytes: 4200000,
    );

    test("round-trips paths through StoragePath.parse correctly", () async {
      await repo.add(item);
      final RecycleItem? loaded = await repo.get("recycle-1");

      expect(loaded, isNotNull);
      expect(loaded!.recyclePath.normalized, "/.vaultbox/recycle/recycle-1__photo.jpg");
      expect(loaded.originalPath.normalized, "/DCIM/photo.jpg");
      expect(loaded.originalName, "photo.jpg");
      // Drift hands back local DateTimes; DateTime == also compares isUtc, so compare the instant.
      expect(loaded.deletedAt.isAtSameMomentAs(item.deletedAt), isTrue);
      expect(loaded.purgeAfter!.isAtSameMomentAs(item.purgeAfter!), isTrue);
      expect(loaded.sizeBytes, 4200000);
    });

    test("listItems only returns items for the requested root, newest first", () async {
      await repo.add(item);
      await repo.add(
        RecycleItem(
          id: "recycle-2",
          storageRootId: "root-1",
          recyclePath: StoragePath.parse("root-1", ".vaultbox/recycle/recycle-2__note.txt"),
          originalPath: StoragePath.parse("root-1", "note.txt"),
          originalName: "note.txt",
          deletedAt: DateTime.utc(2026, 9, 17),
        ),
      );
      await repo.add(
        RecycleItem(
          id: "recycle-3",
          storageRootId: "root-2",
          recyclePath: StoragePath.parse("root-2", ".vaultbox/recycle/recycle-3__x.txt"),
          originalPath: StoragePath.parse("root-2", "x.txt"),
          originalName: "x.txt",
          deletedAt: DateTime.utc(2026, 9, 17),
        ),
      );

      final List<RecycleItem> items = await repo.listItems("root-1");
      expect(items.map((RecycleItem i) => i.id).toList(), <String>["recycle-2", "recycle-1"]);
    });

    test("remove deletes the metadata row", () async {
      await repo.add(item);
      await repo.remove("recycle-1");
      expect(await repo.get("recycle-1"), isNull);
    });
  });

  group("DriftAccountRepository", () {
    late DriftAccountRepository repo;
    setUp(() => repo = DriftAccountRepository(db));

    Account account(String id, String name) =>
        Account(id: id, username: name, passwordHash: r"$argon2id$stub", createdAt: DateTime.utc(2026, 9, 19));

    test("createFirst stores the first account and refuses every later one", () async {
      expect(await repo.count(), 0);
      expect(await repo.createFirst(account("a1", "admin")), isNotNull);
      expect(await repo.createFirst(account("a2", "other")), isNull);
      expect(await repo.count(), 1);
      expect(await repo.findByUsername("other"), isNull, reason: "the refused account was not stored");
    });

    test("findByUsername round-trips every field", () async {
      await repo.createFirst(account("a1", "admin"));
      final Account? loaded = await repo.findByUsername("admin");

      expect(loaded, isNotNull);
      expect(loaded!.id, "a1");
      expect(loaded.passwordHash, r"$argon2id$stub");
      expect(loaded.createdAt.isAtSameMomentAs(DateTime.utc(2026, 9, 19)), isTrue);
      expect(await repo.findByUsername("nobody"), isNull);
    });

    test("findById returns the account, or null for an unknown id", () async {
      await repo.createFirst(account("a1", "admin"));

      expect((await repo.findById("a1"))?.username, "admin");
      expect(await repo.findById("nope"), isNull);
    });

    Account member(String id, String name, {bool enabled = true}) => Account(
      id: id,
      username: name,
      passwordHash: r"$argon2id$stub",
      createdAt: DateTime.utc(2026, 9, 20),
      role: AccountRole.member,
      isEnabled: enabled,
    );

    test("a new account defaults to an enabled admin at version 0", () async {
      await repo.createFirst(account("a1", "admin"));
      final Account loaded = (await repo.findById("a1"))!;

      expect(loaded.role, AccountRole.admin);
      expect(loaded.isEnabled, isTrue);
      expect(loaded.credentialVersion, 0);
      expect(loaded.rules, isEmpty);
    });

    test("revokeSessions bumps the version, and touches nothing else", () async {
      await repo.createFirst(account("a1", "admin"));
      await repo.create(member("m1", "bob"));

      await repo.revokeSessions("m1");
      await repo.revokeSessions("m1");
      await repo.revokeSessions("nobody"); // unknown ids are ignored

      final Account bob = (await repo.findById("m1"))!;
      expect(bob.credentialVersion, 2);
      expect(bob.passwordHash, r"$argon2id$stub");
      expect(bob.isEnabled, isTrue);
      expect((await repo.findById("a1"))!.credentialVersion, 0, reason: "other accounts are unaffected");
    });

    test("create adds members, refuses a taken username, and listAll starts with the oldest", () async {
      await repo.createFirst(account("a1", "admin"));
      expect(await repo.create(member("m1", "bob")), isNotNull);
      expect(await repo.create(member("m2", "bob")), isNull, reason: "username taken");
      expect(await repo.create(member("m3", "carol")), isNotNull);

      final List<Account> all = await repo.listAll();
      expect(all.first.username, "admin", reason: "oldest first");
      expect(all.skip(1).map((Account a) => a.username).toSet(), <String>{"bob", "carol"});
      expect(all[1].role, AccountRole.member);
      expect(await repo.count(), 3);
    });

    test("countEnabledAdmins counts only enabled admins", () async {
      await repo.createFirst(account("a1", "admin"));
      await repo.create(member("m1", "bob"));
      expect(await repo.countEnabledAdmins(), 1);

      await repo.setEnabled("a1", enabled: false);
      expect(await repo.countEnabledAdmins(), 0);
    });

    test("a password change bumps the credential version; disabling bumps it, enabling doesn't", () async {
      await repo.createFirst(account("a1", "admin"));
      await repo.create(member("m1", "bob"));

      await repo.updatePasswordHash("m1", r"$argon2id$new");
      expect((await repo.findById("m1"))!.credentialVersion, 1);
      expect((await repo.findById("m1"))!.passwordHash, r"$argon2id$new");

      await repo.setEnabled("m1", enabled: false);
      expect((await repo.findById("m1"))!.isEnabled, isFalse);
      expect((await repo.findById("m1"))!.credentialVersion, 2);

      await repo.setEnabled("m1", enabled: false);
      expect((await repo.findById("m1"))!.credentialVersion, 2, reason: "no change, no bump");

      await repo.setEnabled("m1", enabled: true);
      expect((await repo.findById("m1"))!.isEnabled, isTrue);
      expect((await repo.findById("m1"))!.credentialVersion, 2);
    });

    test("changes to unknown ids do nothing", () async {
      await repo.updatePasswordHash("nobody", "x");
      await repo.setEnabled("nobody", enabled: false);
      await repo.delete("nobody");
      expect(await repo.count(), 0);
    });

    test("rules round-trip and come back with every read path", () async {
      await repo.createFirst(account("a1", "admin"));
      await repo.create(member("m1", "bob"));
      await repo.replaceRules("m1", const <AccessRule>[
        AccessRule(id: "r1", accountId: "m1", rootId: "root-1", pathPrefix: "/Photos", permissions: AccessRule.readWrite),
        AccessRule(id: "r2", accountId: "m1", rootId: "root-2", pathPrefix: "/", permissions: AccessRule.readOnly),
      ]);

      for (final Account loaded in <Account?>[
        await repo.findById("m1"),
        await repo.findByUsername("bob"),
        (await repo.listAll()).firstWhere((Account a) => a.id == "m1"),
      ].whereType<Account>()) {
        expect(loaded.rules, hasLength(2));
        final AccessRule photos = loaded.rules.firstWhere((AccessRule r) => r.id == "r1");
        expect(photos.rootId, "root-1");
        expect(photos.pathPrefix, "/Photos");
        expect(photos.permissions, <Permission>{Permission.read, Permission.write});
      }
      expect((await repo.findById("a1"))!.rules, isEmpty, reason: "rules belong to one account");
    });

    test("replaceRules replaces everything, and an empty list clears them", () async {
      await repo.createFirst(account("a1", "admin"));
      await repo.create(member("m1", "bob"));
      await repo.replaceRules("m1", const <AccessRule>[
        AccessRule(id: "r1", accountId: "m1", rootId: "root-1", pathPrefix: "/A", permissions: AccessRule.readOnly),
      ]);
      await repo.replaceRules("m1", const <AccessRule>[
        AccessRule(id: "r2", accountId: "m1", rootId: "root-1", pathPrefix: "/B", permissions: AccessRule.everything),
      ]);

      final List<AccessRule> rules = (await repo.findById("m1"))!.rules;
      expect(rules.map((AccessRule r) => r.pathPrefix), <String>["/B"]);
      expect(rules.single.permissions, AccessRule.everything);

      await repo.replaceRules("m1", const <AccessRule>[]);
      expect((await repo.findById("m1"))!.rules, isEmpty);
    });

    test("deleting an account removes its rules and nobody else's", () async {
      await repo.createFirst(account("a1", "admin"));
      await repo.create(member("m1", "bob"));
      await repo.create(member("m2", "carol"));
      await repo.replaceRules("m1", const <AccessRule>[
        AccessRule(id: "r1", accountId: "m1", rootId: "root-1", pathPrefix: "/A", permissions: AccessRule.readOnly),
      ]);
      await repo.replaceRules("m2", const <AccessRule>[
        AccessRule(id: "r2", accountId: "m2", rootId: "root-1", pathPrefix: "/B", permissions: AccessRule.readOnly),
      ]);

      await repo.delete("m1");

      expect(await repo.findById("m1"), isNull);
      expect((await repo.findById("m2"))!.rules.single.id, "r2");
      expect(await db.select(db.accessRules).get(), hasLength(1), reason: "no orphaned rule left behind");
    });

    test("an unknown stored role reads back as the least-privileged one", () async {
      await repo.createFirst(account("a1", "admin"));
      await (db.update(db.accounts)..where((Accounts t) => t.id.equals("a1"))).write(const AccountsCompanion(role: Value<String>("superuser")));

      expect((await repo.findById("a1"))!.role, AccountRole.member);
    });

    test("updatePasswordHash replaces only the hash", () async {
      await repo.createFirst(account("a1", "admin"));
      await repo.updatePasswordHash("a1", r"$argon2id$upgraded");

      final Account? loaded = await repo.findByUsername("admin");
      expect(loaded!.passwordHash, r"$argon2id$upgraded");
      expect(loaded.username, "admin");
    });
  });

  group("DriftShareRepository", () {
    late DriftShareRepository repo;
    setUp(() => repo = DriftShareRepository(db));

    Share share(String id, {String? hash, DateTime? created, DateTime? expires, int? maxUses, int used = 0, String createdBy = "a1", ShareKind kind = ShareKind.download}) => Share(
      id: id,
      kind: kind,
      rootId: "root-1",
      path: "/Docs/$id",
      isDirectory: kind == ShareKind.upload,
      createdBy: createdBy,
      createdAt: created ?? DateTime.utc(2026, 9, 19),
      tokenHash: hash ?? "hash-$id",
      label: "label $id",
      expiresAt: expires,
      passwordHash: r"$argon2id$pw",
      maxUses: maxUses,
      useCount: used,
      maxFileBytes: kind == ShareKind.upload ? 5000 : null,
    );

    test("every field round-trips, found by id and by token hash", () async {
      await repo.add(share("s1", expires: DateTime.utc(2026, 10, 1), maxUses: 3, used: 1, kind: ShareKind.upload));

      for (final Share loaded in <Share?>[await repo.get("s1"), await repo.findByTokenHash("hash-s1")].whereType<Share>()) {
        expect(loaded.id, "s1");
        expect(loaded.kind, ShareKind.upload);
        expect(loaded.rootId, "root-1");
        expect(loaded.path, "/Docs/s1");
        expect(loaded.isDirectory, isTrue);
        expect(loaded.createdBy, "a1");
        expect(loaded.label, "label s1");
        expect(loaded.expiresAt!.isAtSameMomentAs(DateTime.utc(2026, 10, 1)), isTrue);
        expect(loaded.passwordHash, r"$argon2id$pw");
        expect(loaded.maxUses, 3);
        expect(loaded.useCount, 1);
        expect(loaded.maxFileBytes, 5000);
      }
      expect(await repo.get("nope"), isNull);
      expect(await repo.findByTokenHash("nope"), isNull);
    });

    test("optional fields stay null", () async {
      await repo.add(
        Share(
          id: "plain",
          kind: ShareKind.download,
          rootId: "root-1",
          path: "/x",
          isDirectory: false,
          createdBy: "a1",
          createdAt: DateTime.utc(2026),
          tokenHash: "h",
        ),
      );
      final Share loaded = (await repo.get("plain"))!;
      expect(loaded.label, isNull);
      expect(loaded.expiresAt, isNull);
      expect(loaded.passwordHash, isNull);
      expect(loaded.maxUses, isNull);
      expect(loaded.maxFileBytes, isNull);
      expect(loaded.hasPassword, isFalse);
    });

    test("two links can't share a token hash", () async {
      await repo.add(share("s1", hash: "same"));
      await expectLater(repo.add(share("s2", hash: "same")), throwsA(anything));
      expect((await repo.list()), hasLength(1));
    });

    test("list is newest first; delete and deleteByCreator remove what they should", () async {
      await repo.add(share("old", created: DateTime.utc(2026, 1, 1)));
      await repo.add(share("new", created: DateTime.utc(2026, 6, 1), createdBy: "m1"));
      await repo.add(share("mid", created: DateTime.utc(2026, 3, 1), createdBy: "m1"));
      expect((await repo.list()).map((Share s) => s.id), <String>["new", "mid", "old"]);

      await repo.delete("old");
      expect((await repo.list()).map((Share s) => s.id), <String>["new", "mid"]);

      await repo.deleteByCreator("m1");
      expect(await repo.list(), isEmpty);
    });

    test("tryUse counts while the link is active and stops at the limit", () async {
      await repo.add(share("s1", maxUses: 2));
      final DateTime now = DateTime.utc(2026, 9, 20);

      expect(await repo.tryUse("s1", now), isTrue);
      expect(await repo.tryUse("s1", now), isTrue);
      expect(await repo.tryUse("s1", now), isFalse, reason: "the limit is 2");
      expect((await repo.get("s1"))!.useCount, 2);
    });

    test("tryUse refuses an expired link and unknown ids, and counts without a limit", () async {
      await repo.add(share("timed", expires: DateTime.utc(2026, 9, 20)));
      expect(await repo.tryUse("timed", DateTime.utc(2026, 9, 21)), isFalse);
      expect(await repo.tryUse("nope", DateTime.utc(2026, 9, 21)), isFalse);

      await repo.add(share("free"));
      for (int i = 0; i < 5; i++) {
        expect(await repo.tryUse("free", DateTime.utc(2026, 9, 20)), isTrue);
      }
      expect((await repo.get("free"))!.useCount, 5);
    });

    test("racing tryUse calls can't take the last use twice", () async {
      await repo.add(share("s1", maxUses: 1));
      final List<bool> results = await Future.wait(<Future<bool>>[
        repo.tryUse("s1", DateTime.utc(2026, 9, 20)),
        repo.tryUse("s1", DateTime.utc(2026, 9, 20)),
        repo.tryUse("s1", DateTime.utc(2026, 9, 20)),
      ]);
      expect(results.where((bool ok) => ok), hasLength(1));
      expect((await repo.get("s1"))!.useCount, 1);
    });
  });
}
