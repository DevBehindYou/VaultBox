import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/server/ftp/ftp_paths.dart";

/// The FTP tree is virtual text-only path math (see `ftp_paths.dart`'s own
/// doc comment): nothing here touches storage, so these are pure-function
/// tests of "what segments does this argument resolve to".
void main() {
  group("resolveFtpPath", () {
    test("a bare name is appended to the current folder", () {
      expect(resolveFtpPath(<String>["Phone"], "Photos"), <String>["Phone", "Photos"]);
    });

    test("a leading slash resets to the top first", () {
      expect(resolveFtpPath(<String>["Phone", "Photos"], "/"), <String>[]);
      expect(resolveFtpPath(<String>["Phone", "Photos"], "/Card"), <String>["Card"]);
    });

    test("dot segments are ignored", () {
      expect(resolveFtpPath(<String>[], "./a/./b"), <String>["a", "b"]);
      expect(resolveFtpPath(<String>["Phone"], "."), <String>["Phone"]);
    });

    test(".. walks up one level", () {
      expect(resolveFtpPath(<String>["Phone"], ".."), <String>[]);
      expect(resolveFtpPath(<String>["A", "B", "C"], "../../x"), <String>["A", "x"]);
    });

    test(".. can never climb above the top, however many are given", () {
      expect(resolveFtpPath(<String>[], ".."), <String>[]);
      expect(resolveFtpPath(<String>[], "../../../.."), <String>[]);
      expect(resolveFtpPath(<String>["Phone"], "../../../../etc"), <String>["etc"]);
      expect(resolveFtpPath(<String>["Phone", "Photos"], "../../../../../etc/passwd"), <String>["etc", "passwd"]);
    });

    test("~ alone resets to the top, like a leading slash", () {
      expect(resolveFtpPath(<String>["Phone", "Photos"], "~"), <String>[]);
    });

    test("~ inside a path is just skipped, not treated as an escape", () {
      expect(resolveFtpPath(<String>["Phone"], "~/Photos"), <String>["Phone", "Photos"]);
    });

    test("empty segments from doubled slashes collapse away", () {
      expect(resolveFtpPath(<String>[], "//Phone///Photos//"), <String>["Phone", "Photos"]);
    });

    test("spaces inside a single path segment survive untouched", () {
      expect(resolveFtpPath(<String>["Phone"], "My Documents"), <String>["Phone", "My Documents"]);
      expect(resolveFtpPath(<String>[], "/Photo Album/Summer 2026"), <String>["Photo Album", "Summer 2026"]);
    });

    test("a fully absolute path replaces the current folder rather than extending it", () {
      expect(resolveFtpPath(<String>["Card", "Old"], "/Phone/Photos"), <String>["Phone", "Photos"]);
    });
  });

  group("formatFtpPath", () {
    test("the top has no segments", () {
      expect(formatFtpPath(<String>[]), "/");
    });

    test("segments are joined with slashes", () {
      expect(formatFtpPath(<String>["Phone", "Photos"]), "/Phone/Photos");
    });
  });

  group("quoteFtpPath", () {
    test("wraps in double quotes", () {
      expect(quoteFtpPath("/Phone"), '"/Phone"');
    });

    test("doubles an embedded quote (RFC 959)", () {
      expect(quoteFtpPath('/a"b'), '"/a""b"');
    });
  });

  group("ftpArgument", () {
    test("everything after the first space is the argument", () {
      expect(ftpArgument("CWD Photos"), "Photos");
    });

    test("later spaces stay inside the argument, so names with spaces survive", () {
      expect(ftpArgument("CWD My Documents"), "My Documents");
    });

    test("no space means no argument", () {
      expect(ftpArgument("NOOP"), isNull);
    });

    test("a trailing space with nothing after it is also no argument", () {
      expect(ftpArgument("PASS "), isNull);
    });
  });

  group("stripListFlags", () {
    test("null stays null", () {
      expect(stripListFlags(null), isNull);
    });

    test("a bare flag with nothing after it is no path", () {
      expect(stripListFlags("-la"), isNull);
    });

    test("a flag followed by a path returns just the path", () {
      expect(stripListFlags("-la /Phone"), "/Phone");
    });

    test("several flags in a row are all stripped", () {
      expect(stripListFlags("-a -l Photos"), "Photos");
    });

    test("no flags at all is returned unchanged", () {
      expect(stripListFlags("Photos"), "Photos");
    });

    test("empty input is no path", () {
      expect(stripListFlags(""), isNull);
    });
  });
}
