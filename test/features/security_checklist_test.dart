import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/entities/server_config.dart";
import "package:vaultbox/domain/entities/share.dart";
import "package:vaultbox/features/settings/security_checklist.dart";

void main() {
  final DateTime now = DateTime.utc(2026, 9, 20, 12);

  Share link(String id, {String? password, DateTime? expires}) => Share(
    id: id,
    kind: ShareKind.download,
    rootId: "r",
    path: "/x",
    isDirectory: false,
    createdBy: "a",
    createdAt: now,
    tokenHash: "h-$id",
    passwordHash: password,
    expiresAt: expires,
  );

  List<SecurityItem> check({
    ServerConfig config = const ServerConfig(),
    bool adminExists = true,
    List<Share> shares = const <Share>[],
  }) => buildSecurityChecklist(config: config, adminExists: adminExists, shares: shares, now: now);

  SecurityItem item(List<SecurityItem> items, String title) => items.singleWhere((SecurityItem i) => i.title == title);

  test("a default, set-up phone has every protection in place", () {
    final List<SecurityItem> items = check();

    expect(items.every((SecurityItem i) => i.isGood), isTrue);
    expect(items.map((SecurityItem i) => i.title), <String>[
      "Encryption",
      "Admin sign-in",
      "Network reach",
      "Guess protection",
      "No anonymous access",
      "Links",
    ]);
  });

  group("encryption", () {
    test("HTTPS only is good", () {
      expect(item(check(), "Encryption").isGood, isTrue);
    });

    test("plain HTTP is a notice, even next to HTTPS", () {
      final SecurityItem both = item(check(config: const ServerConfig(httpEnabled: true)), "Encryption");
      final SecurityItem onlyHttp = item(check(config: const ServerConfig(httpsEnabled: false, httpEnabled: true)), "Encryption");

      expect(both.level, CheckLevel.notice);
      expect(both.detail, contains("Plain HTTP is on"));
      expect(onlyHttp.level, CheckLevel.notice);
    });

    test("nothing switched on can't be called good", () {
      final SecurityItem none = item(check(config: const ServerConfig(httpsEnabled: false)), "Encryption");

      expect(none.level, CheckLevel.notice);
    });
  });

  test("no admin account is a notice", () {
    final SecurityItem admin = item(check(adminExists: false), "Admin sign-in");

    expect(admin.level, CheckLevel.notice);
    expect(admin.detail, contains("nobody can sign in"));
  });

  test("network reach is described either way, and is never a warning by itself", () {
    final SecurityItem local = item(check(), "Network reach");
    final SecurityItem lan = item(check(config: const ServerConfig(allowNetworkAccess: true)), "Network reach");

    expect(local.detail, "Only this phone can reach the server.");
    expect(lan.detail, contains("never opened to the internet"));
    expect(local.isGood && lan.isGood, isTrue);
  });

  group("links", () {
    test("an active link with no password is a notice that counts them", () {
      expect(item(check(shares: <Share>[link("a")]), "Links").detail, startsWith("1 active link has no password"));
      expect(
        item(check(shares: <Share>[link("a"), link("b")]), "Links").detail,
        startsWith("2 active links have no password"),
      );
    });

    test("password-protected, expired and used-up links don't count", () {
      final List<Share> shares = <Share>[
        link("protected", password: r"$argon2id$x"),
        link("expired", expires: now.subtract(const Duration(days: 1))),
      ];

      expect(item(check(shares: shares), "Links").isGood, isTrue);
    });
  });
}
