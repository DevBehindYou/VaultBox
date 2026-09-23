import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/data/services/memory_storage_backend.dart";
import "package:vaultbox/domain/entities/access_rule.dart";
import "package:vaultbox/domain/entities/account.dart";
import "package:vaultbox/domain/entities/share.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/security/authorizer.dart";
import "package:vaultbox/domain/security/share_tokens.dart";
import "package:vaultbox/domain/usecases/create_share.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";

import "../helpers/api_harness.dart";

void main() {
  late ApiHarness h;

  final Account bob = Account(
    id: "m1",
    username: "bob",
    passwordHash: "x",
    createdAt: DateTime.utc(2026),
    role: AccountRole.member,
    rules: const <AccessRule>[
      AccessRule(id: "r", accountId: "m1", rootId: "r1", pathPrefix: "/Photos", permissions: AccessRule.readOnly),
      AccessRule(id: "w", accountId: "m1", rootId: "r1", pathPrefix: "/Inbox", permissions: AccessRule.readWrite),
    ],
  );

  Matcher refused([String? text]) => throwsA(
    isA<ValidationFailure>().having((ValidationFailure f) => f.message, "message", text == null ? isNotEmpty : contains(text)),
  );

  setUp(() {
    final MemoryStorageBackend backend = MemoryStorageBackend(id: "r1")
      ..seedFile("/readme.txt", utf8.encode("hi"))
      ..seedFile("/Photos/a.jpg", utf8.encode("a"))
      ..seedDirectory("/Inbox")
      ..seedFile("/Docs/secret.txt", utf8.encode("s"))
      ..seedFile("/.vaultbox/recycle/x", utf8.encode("bin"));
    h = ApiHarness(
      backend: backend,
      authorizer: const AclAuthorizer(),
      roots: <StorageRoot>[
        ApiHarness.root(),
        ApiHarness.root(id: "ro", name: "Card", capabilities: const StorageCapabilities.readOnly()),
        ApiHarness.root(id: "off", name: "Off", enabled: false),
      ],
      extraAccounts: <Account>[bob],
    );
  });

  test("a download link for a file: only the token's HASH is stored", () async {
    final CreatedShare made = await h.makeShare(path: "/readme.txt");

    expect(made.token.length, 43);
    expect(made.share.tokenHash, ShareTokens.hash(made.token));
    expect(made.share.tokenHash, isNot(made.token));
    expect(made.share.kind, ShareKind.download);
    expect(made.share.isDirectory, isFalse);
    expect(made.share.path, "/readme.txt");
    expect(made.share.createdBy, "a1");
    expect((await h.shareRepository.findByTokenHash(ShareTokens.hash(made.token)))?.id, made.share.id);
    expect(jsonEncode((await h.shareRepository.list()).map((Share s) => s.tokenHash).toList()), isNot(contains(made.token)));
  });

  test("tokens are unpredictable and always look valid", () async {
    final Set<String> tokens = <String>{for (int i = 0; i < 30; i++) ShareTokens.generate()};
    expect(tokens, hasLength(30));
    expect(tokens.every(ShareTokens.looksValid), isTrue);
    expect(ShareTokens.looksValid("short"), isFalse);
    expect(ShareTokens.looksValid("${"a" * 42}!"), isFalse);
  });

  test("folders and the whole storage can be shared", () async {
    expect((await h.makeShare(path: "/Photos")).share.isDirectory, isTrue);
    final CreatedShare whole = await h.makeShare(path: "/");
    expect(whole.share.path, "/");
    expect(whole.share.isDirectory, isTrue);
  });

  test("expiry, limits, label and password are recorded; the password is hashed", () async {
    final CreatedShare made = await h.makeShare(
      path: "/readme.txt",
      lifetime: const Duration(days: 7),
      maxUses: 3,
      password: "hunter22",
    );

    expect(made.share.expiresAt, h.clock.now().add(const Duration(days: 7)));
    expect(made.share.maxUses, 3);
    expect(made.share.hasPassword, isTrue);
    expect(made.share.passwordHash, "fake:hunter22");
    expect(made.share.useCount, 0);
  });

  test("an upload link needs an existing, writable folder", () async {
    final CreatedShare made = await h.makeShare(path: "/Inbox", kind: ShareKind.upload, maxFileBytes: 1000, maxUses: 5);
    expect(made.share.kind, ShareKind.upload);
    expect(made.share.maxFileBytes, 1000);

    await expectLater(h.makeShare(path: "/readme.txt", kind: ShareKind.upload), refused("folder"));
    await expectLater(h.makeShare(path: "/nope", kind: ShareKind.upload), refused("doesn't exist"));
    await expectLater(h.makeShare(path: "/", rootId: "ro", kind: ShareKind.upload), refused("read-only"));
  });

  test("things that can't be shared", () async {
    await expectLater(h.makeShare(path: "/missing.txt"), refused("doesn't exist"));
    await expectLater(h.makeShare(path: "/.vaultbox/recycle/x"), refused("own folder"));
    await expectLater(h.makeShare(path: "/a/../b"), refused("isn't allowed"));
    await expectLater(h.makeShare(path: "/readme.txt", rootId: "nope"), refused("isn't available"));
    await expectLater(h.makeShare(path: "/", rootId: "off"), refused("isn't available"));
    expect(await h.shareRepository.list(), isEmpty, reason: "nothing half-made");
  });

  test("bad limits are refused before any password hashing", () async {
    final int before = h.hasher.hashCalls;

    await expectLater(h.makeShare(path: "/readme.txt", lifetime: const Duration(seconds: 5)), refused("expiry"));
    await expectLater(h.makeShare(path: "/readme.txt", lifetime: const Duration(days: 4000)), refused("expiry"));
    await expectLater(h.makeShare(path: "/readme.txt", maxUses: 0), refused("limit"));
    await expectLater(h.makeShare(path: "/readme.txt", password: "abc"), refused("password"));
    await expectLater(h.makeShare(path: "/readme.txt", password: "x" * 200), refused("password"));
    await expectLater(h.makeShare(path: "/readme.txt", maxFileBytes: 10), refused("size"), reason: "only upload links have a file size limit");
    await expectLater(h.makeShare(path: "/Inbox", kind: ShareKind.upload, maxFileBytes: 0), refused("size"));

    expect(h.hasher.hashCalls, before);
  });

  test("the maker must be allowed to do what the link does", () async {
    // Bob can read /Photos but not /Docs, and can write only to /Inbox.
    await expectLater(h.makeShare(creator: bob, path: "/Photos/a.jpg"), completion(isA<CreatedShare>()));
    await expectLater(h.makeShare(creator: bob, path: "/Docs/secret.txt"), refused("access"));
    await expectLater(h.makeShare(creator: bob, path: "/readme.txt"), refused("access"));
    await expectLater(h.makeShare(creator: bob, path: "/Photos", kind: ShareKind.upload), refused("access"));
    await expectLater(h.makeShare(creator: bob, path: "/Inbox", kind: ShareKind.upload), completion(isA<CreatedShare>()));
  });

  test("a disabled maker can't make links", () async {
    final Account off = bob.copyWith(isEnabled: false);
    await expectLater(h.makeShare(creator: off, path: "/Photos/a.jpg"), refused("access"));
  });

  test("Share knows when it is spent", () {
    final Share share = Share(
      id: "s",
      kind: ShareKind.download,
      rootId: "r1",
      path: "/x",
      isDirectory: false,
      createdBy: "a1",
      createdAt: DateTime.utc(2026),
      tokenHash: "h",
      expiresAt: DateTime.utc(2026, 1, 2),
      maxUses: 2,
      useCount: 1,
    );

    expect(share.isActive(DateTime.utc(2026, 1, 1)), isTrue);
    expect(share.isExpired(DateTime.utc(2026, 1, 2)), isTrue, reason: "expires AT the deadline");
    expect(share.copyWith(useCount: 2).isUsedUp, isTrue);
    expect(share.copyWith(useCount: 2).isActive(DateTime.utc(2026, 1, 1)), isFalse);
  });
}
