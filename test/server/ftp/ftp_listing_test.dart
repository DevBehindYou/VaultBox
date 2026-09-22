import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/server/ftp/ftp_listing.dart";

void main() {
  group("ftpTimestamp", () {
    test("formats as YYYYMMDDHHMMSS, always UTC", () {
      expect(ftpTimestamp(DateTime.utc(2026, 9, 20, 12, 30, 45)), "20260920123045");
    });

    test("pads single digits", () {
      expect(ftpTimestamp(DateTime.utc(2026, 1, 2, 3, 4, 5)), "20260102030405");
    });
  });

  group("unixListLine", () {
    final DateTime now = DateTime.utc(2026, 9, 20, 12, 30);

    test("a directory is 'd', a file is '-'", () {
      final String dir = unixListLine(const FtpEntry(name: "Photos", isDirectory: true), now);
      final String file = unixListLine(const FtpEntry(name: "a.txt", isDirectory: false), now);

      expect(dir, startsWith("d"));
      expect(file, startsWith("-"));
    });

    test("write permission is reflected in the letters", () {
      final String writable = unixListLine(const FtpEntry(name: "a", isDirectory: true, canWrite: true), now);
      final String readOnly = unixListLine(const FtpEntry(name: "a", isDirectory: true, canWrite: false), now);

      expect(writable, contains("rwxr-xr-x"));
      expect(readOnly, contains("r-xr-xr-x"));
    });

    test("the name is the last thing on the line", () {
      final String line = unixListLine(const FtpEntry(name: "My File.txt", isDirectory: false), now);
      expect(line, endsWith(" My File.txt"));
    });

    test("the size field is right-padded to the same width the code produces", () {
      final String line = unixListLine(const FtpEntry(name: "a.txt", isDirectory: false, size: 12345), now);
      expect(line, contains("12345".padLeft(12)));
    });

    test("a missing size is shown as 0, not blank", () {
      final String line = unixListLine(const FtpEntry(name: "a.txt", isDirectory: false), now);
      expect(line, contains("0".padLeft(12)));
    });

    test("a recent modification shows its own time, not a year", () {
      final DateTime recent = now.subtract(const Duration(hours: 3));
      final String line = unixListLine(FtpEntry(name: "a.txt", isDirectory: false, modified: recent), now);

      expect(line, contains("09:30"));
      expect(line, isNot(contains(recent.year.toString())));
    });

    test("an old modification shows a year, not a time", () {
      final DateTime old = now.subtract(const Duration(days: 400));
      final String line = unixListLine(FtpEntry(name: "a.txt", isDirectory: false, modified: old), now);

      expect(line, contains(" ${old.year}"));
      expect(old.year, isNot(now.year), reason: "the test is only meaningful if the year actually differs");
    });

    test("no modification time at all falls back to now, so it reads as recent", () {
      final String line = unixListLine(const FtpEntry(name: "a.txt", isDirectory: false), now);
      expect(line, contains("Sep 20"));
      expect(line, contains("12:30"));
    });
  });

  group("mlsxLine", () {
    test("a directory's type and permissions", () {
      final String line = mlsxLine(const FtpEntry(name: "Photos", isDirectory: true));
      expect(line, startsWith("type=dir;"));
      expect(line, contains("perm=el;"));
      expect(line, endsWith(" Photos"));
    });

    test("a writable, deletable directory gets the create/make and purge/delete letters", () {
      final String line = mlsxLine(const FtpEntry(name: "Photos", isDirectory: true, canWrite: true, canDelete: true));
      expect(line, contains("perm=elcmpd;"));
    });

    test("a directory never reports a size, even if one was (incorrectly) given", () {
      final String line = mlsxLine(const FtpEntry(name: "Photos", isDirectory: true, size: 999));
      expect(line, isNot(contains("size=")));
    });

    test("a file's type, size and permissions", () {
      final String line = mlsxLine(const FtpEntry(name: "a.txt", isDirectory: false, size: 42));
      expect(line, startsWith("type=file;"));
      expect(line, contains("size=42;"));
      expect(line, contains("perm=r;"), reason: "read-only, no write/append/rename/delete");
    });

    test("a writable, deletable file gets the write/append/rename and delete letters", () {
      final String line = mlsxLine(const FtpEntry(name: "a.txt", isDirectory: false, canWrite: true, canDelete: true));
      expect(line, contains("perm=rwafd;"));
    });

    test("a modification time is rendered as an MLSD timestamp", () {
      final String line = mlsxLine(FtpEntry(name: "a.txt", isDirectory: false, modified: DateTime.utc(2026, 9, 20, 12, 30)));
      expect(line, contains("modify=20260920123000;"));
    });

    test("no modification time means no modify= fact", () {
      final String line = mlsxLine(const FtpEntry(name: "a.txt", isDirectory: false));
      expect(line, isNot(contains("modify=")));
    });
  });

  group("nameOnlyLine", () {
    test("is just the name", () {
      expect(nameOnlyLine(const FtpEntry(name: "Photos", isDirectory: true)), "Photos");
      expect(nameOnlyLine(const FtpEntry(name: "a b c.txt", isDirectory: false)), "a b c.txt");
    });
  });
}
