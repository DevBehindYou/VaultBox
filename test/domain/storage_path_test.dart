import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/domain/value_objects/storage_path.dart";

/// Path traversal is a security boundary (doc §42), so these are the highest
/// -value tests in the project: a regression here is a remote file-disclosure
/// bug, not a cosmetic one.
void main() {
  const String root = "root-1";

  group("StoragePath.parse — normalization", () {
    test("collapses redundant separators and dot segments", () {
      final StoragePath path = StoragePath.parse(root, "//a///b/./c/");
      expect(path.segments, <String>["a", "b", "c"]);
      expect(path.normalized, "/a/b/c");
    });

    test("root path has no segments", () {
      final StoragePath path = StoragePath.root(root);
      expect(path.isRoot, isTrue);
      expect(path.normalized, "/");
    });

    test("parent walks up one level and stops at root", () {
      final StoragePath path = StoragePath.parse(root, "a/b/c");
      expect(path.parent.normalized, "/a/b");
      expect(path.parent.parent.parent.isRoot, isTrue);
      expect(path.parent.parent.parent.parent.isRoot, isTrue);
    });

    test("equality is by root plus segments, not identity", () {
      expect(StoragePath.parse(root, "a/b"), equals(StoragePath.parse(root, "/a/b/")));
      expect(StoragePath.parse(root, "a/b"), isNot(equals(StoragePath.parse("other", "a/b"))));
    });
  });

  group("StoragePath.parse — traversal rejection", () {
    test("rejects plain .. segments", () {
      expect(
        () => StoragePath.parse(root, "a/../../etc/passwd"),
        throwsA(isA<PathTraversalRejectedFailure>()),
      );
    });

    test("rejects percent-encoded traversal", () {
      expect(
        () => StoragePath.parse(root, "a/%2e%2e/secret"),
        throwsA(isA<PathTraversalRejectedFailure>()),
      );
    });

    test("rejects double-encoded traversal", () {
      expect(
        () => StoragePath.parse(root, "%252e%252e/secret"),
        throwsA(isA<PathTraversalRejectedFailure>()),
      );
    });

    test("rejects backslash separator escape", () {
      expect(
        () => StoragePath.parse(root, r"a\..\..\windows"),
        throwsA(isA<PathTraversalRejectedFailure>()),
      );
    });

    test("rejects absolute Android-style paths", () {
      expect(
        () => StoragePath.parse(root, "//storage/emulated/0"),
        returnsNormally,
        reason: "leading slashes are stripped, not treated as absolute escape",
      );
      expect(
        () => StoragePath.parse(root, "C:/Windows"),
        throwsA(isA<PathTraversalRejectedFailure>()),
      );
    });

    test("rejects control characters in a segment", () {
      expect(
        () => StoragePath.parse(root, "a/\u0000evil"),
        throwsA(isA<PathTraversalRejectedFailure>()),
      );
    });

    test("child() re-validates its argument", () {
      final StoragePath base = StoragePath.parse(root, "a");
      expect(() => base.child(".."), throwsA(isA<PathTraversalRejectedFailure>()));
      expect(() => base.child("b/c"), throwsA(isA<PathTraversalRejectedFailure>()));
      expect(base.child("b").normalized, "/a/b");
    });
  });

  group("StoragePath.isDescendantOfOrEqualTo", () {
    test("true for the same path", () {
      final StoragePath a = StoragePath.parse(root, "photos");
      expect(a.isDescendantOfOrEqualTo(a), isTrue);
    });

    test("true for a path nested underneath", () {
      final StoragePath child = StoragePath.parse(root, "photos/2026/trip");
      final StoragePath parent = StoragePath.parse(root, "photos");
      expect(child.isDescendantOfOrEqualTo(parent), isTrue);
    });

    test("false for a sibling that merely shares a name prefix", () {
      // "photos-backup" must not be treated as inside "photos".
      final StoragePath sibling = StoragePath.parse(root, "photos-backup/x");
      final StoragePath parent = StoragePath.parse(root, "photos");
      expect(sibling.isDescendantOfOrEqualTo(parent), isFalse);
    });

    test("false across different roots", () {
      final StoragePath a = StoragePath.parse(root, "photos/x");
      final StoragePath b = StoragePath.parse("other-root", "photos");
      expect(a.isDescendantOfOrEqualTo(b), isFalse);
    });

    test("false when checking a parent against its child (direction matters)", () {
      final StoragePath parent = StoragePath.parse(root, "photos");
      final StoragePath child = StoragePath.parse(root, "photos/2026");
      expect(parent.isDescendantOfOrEqualTo(child), isFalse);
    });
  });
}
