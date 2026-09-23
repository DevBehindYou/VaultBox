import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/domain/entities/share.dart";
import "package:vaultbox/features/share/share_links.dart";

void main() {
  group("shareLinkBase", () {
    test("nothing until the server runs", () {
      expect(shareLinkBase(const ServerState.stopped()), isNull);
      expect(shareLinkBase(const ServerState(run: ServerRunState.starting, endpoint: "https://a/")), isNull);
      expect(shareLinkBase(const ServerState(run: ServerRunState.failed)), isNull);
    });

    test("prefers the encrypted address, whatever the order", () {
      expect(
        shareLinkBase(
          const ServerState(
            run: ServerRunState.running,
            endpoint: "http://192.168.1.5:8080/",
            endpoints: <String>["http://192.168.1.5:8080/", "https://192.168.1.5:8443/"],
          ),
        ),
        "https://192.168.1.5:8443/",
      );
    });

    test("falls back to plain HTTP when that is all there is, or the single endpoint", () {
      expect(
        shareLinkBase(const ServerState(run: ServerRunState.running, endpoints: <String>["http://192.168.1.5:8080/"])),
        "http://192.168.1.5:8080/",
      );
      expect(
        shareLinkBase(const ServerState(run: ServerRunState.running, endpoint: "https://x:1/")),
        "https://x:1/",
      );
      expect(shareLinkBase(const ServerState(run: ServerRunState.running)), isNull);
    });
  });

  test("shareUrl builds /s/ for downloads and /u/ for uploads, with or without a trailing slash", () {
    expect(shareUrl("https://h:8443/", ShareKind.download, "TOKEN"), "https://h:8443/s/TOKEN");
    expect(shareUrl("https://h:8443", ShareKind.upload, "TOKEN"), "https://h:8443/u/TOKEN");
  });

  test("isUnencrypted flags plain HTTP except on this phone", () {
    expect(isUnencrypted("http://192.168.1.5:8080/s/x"), isTrue);
    expect(isUnencrypted("https://192.168.1.5:8443/s/x"), isFalse);
    expect(isUnencrypted("http://127.0.0.1:8080/"), isFalse);
    expect(isUnencrypted("http://localhost:8080/"), isFalse);
    expect(isUnencrypted("…/s/x"), isFalse);
  });

  test("describeExpiry speaks in the largest sensible unit", () {
    final DateTime now = DateTime.utc(2026, 9, 20, 12);
    expect(describeExpiry(null, now), "No expiry");
    expect(describeExpiry(now, now), "Expired");
    expect(describeExpiry(now.subtract(const Duration(days: 1)), now), "Expired");
    expect(describeExpiry(now.add(const Duration(days: 7)), now), "Expires in 7 days");
    expect(describeExpiry(now.add(const Duration(hours: 5)), now), "Expires in 5 hours");
    expect(describeExpiry(now.add(const Duration(minutes: 20)), now), "Expires in 20 minutes");
    expect(describeExpiry(now.add(const Duration(seconds: 30)), now), "Expires in a minute");
  });

  test("describeShareState names why a link isn't active", () {
    final DateTime now = DateTime.utc(2026, 9, 20, 12);
    Share share({DateTime? expires, int? max, int used = 0}) => Share(
      id: "s",
      kind: ShareKind.download,
      rootId: "r",
      path: "/x",
      isDirectory: false,
      createdBy: "a",
      createdAt: now,
      tokenHash: "h",
      expiresAt: expires,
      maxUses: max,
      useCount: used,
    );

    expect(describeShareState(share(), now), "Active");
    expect(describeShareState(share(expires: now.subtract(const Duration(hours: 1))), now), "Expired");
    expect(describeShareState(share(max: 2, used: 2), now), "Used up");
  });
}
