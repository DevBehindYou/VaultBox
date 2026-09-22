import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/server/files/root_names.dart";

StorageRoot _root(String id, String displayName) => StorageRoot(
  id: id,
  displayName: displayName,
  backendType: StorageBackendType.memory,
  uriOrPath: "memory://$id",
  capabilities: const StorageCapabilities.fullLocal(),
);

void main() {
  group("RootNames.slugify", () {
    test("letters, numbers, dots, underscores and hyphens survive as-is", () {
      expect(RootNames.slugify("Photos_2026.v2"), "Photos_2026.v2");
    });

    test("spaces become a single hyphen", () {
      expect(RootNames.slugify("Phone Storage"), "Phone-Storage");
    });

    test("runs of punctuation collapse to one hyphen and trim from the ends", () {
      expect(RootNames.slugify("SD Card (64GB)"), "SD-Card-64GB");
    });

    test("a unicode letter is kept, not stripped", () {
      expect(RootNames.slugify("Café"), "Café");
    });

    test("a name that is nothing but punctuation falls back to 'storage'", () {
      expect(RootNames.slugify(""), "storage");
      expect(RootNames.slugify("   "), "storage");
      expect(RootNames.slugify("///"), "storage");
    });
  });

  group("RootNames.of", () {
    test("one root gets its own slug", () {
      final RootNames names = RootNames.of(<StorageRoot>[_root("r1", "Phone")]);

      expect(names.nameOf("r1"), "Phone");
      expect(names.byName("Phone")?.id, "r1");
    });

    test("byName is case-insensitive", () {
      final RootNames names = RootNames.of(<StorageRoot>[_root("r1", "Phone")]);

      expect(names.byName("PHONE")?.id, "r1");
      expect(names.byName("phone")?.id, "r1");
    });

    test("an unknown name or id resolves to null", () {
      final RootNames names = RootNames.of(<StorageRoot>[_root("r1", "Phone")]);

      expect(names.byName("Nope"), isNull);
      expect(names.nameOf("nope"), isNull);
    });

    test("two roots with the exact same display name get -2, -3, ... in list order", () {
      final RootNames names = RootNames.of(<StorageRoot>[_root("r1", "Phone"), _root("r2", "Phone"), _root("r3", "Phone")]);

      expect(names.nameOf("r1"), "Phone");
      expect(names.nameOf("r2"), "Phone-2");
      expect(names.nameOf("r3"), "Phone-3");
      expect(names.byName("Phone")?.id, "r1");
      expect(names.byName("Phone-2")?.id, "r2");
      expect(names.byName("Phone-3")?.id, "r3");
    });

    test("a collision is detected case-insensitively even though the slug keeps its own case", () {
      final RootNames names = RootNames.of(<StorageRoot>[_root("r1", "SD Card"), _root("r2", "sd card")]);

      expect(names.nameOf("r1"), "SD-Card");
      expect(names.nameOf("r2"), "sd-card-2", reason: "the base slug 'sd-card' collides with 'SD-Card' case-insensitively");
      expect(names.byName("sd-card")?.id, "r1");
      expect(names.byName("SD-CARD-2")?.id, "r2");
    });

    test("an empty list of roots is fine", () {
      final RootNames names = RootNames.of(<StorageRoot>[]);

      expect(names.byName("anything"), isNull);
      expect(names.nameOf("r1"), isNull);
    });
  });
}
