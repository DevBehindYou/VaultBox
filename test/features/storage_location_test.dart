import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/domain/entities/storage_root.dart";
import "package:vaultbox/domain/value_objects/storage_capabilities.dart";
import "package:vaultbox/features/storage/storage_location.dart";

void main() {
  StorageRoot root(StorageBackendType type, String uriOrPath) => StorageRoot(
    id: "r",
    displayName: "Anything",
    backendType: type,
    uriOrPath: uriOrPath,
    capabilities: const StorageCapabilities.fullLocal(),
  );

  StorageLocationInfo of(StorageBackendType type, String uriOrPath) => describeStorageRoot(root(type, uriOrPath));

  group("a folder chosen with the picker (SAF)", () {
    test("on the phone's own storage", () {
      final StorageLocationInfo info = of(
        StorageBackendType.saf,
        "content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FVaultBox",
      );

      expect(info.kind, VolumeKind.internal);
      expect(info.volumeLabel, "Internal storage");
      expect(info.path, "/storage/emulated/0/Documents/VaultBox");
    });

    test("the whole of internal storage", () {
      final StorageLocationInfo info = of(
        StorageBackendType.saf,
        "content://com.android.externalstorage.documents/tree/primary%3A",
      );

      expect(info.path, "/storage/emulated/0");
    });

    test("on a memory card or USB drive", () {
      final StorageLocationInfo info = of(
        StorageBackendType.saf,
        "content://com.android.externalstorage.documents/tree/1A2B-3C4D%3AMedia%2FShared",
      );

      expect(info.kind, VolumeKind.removable);
      expect(info.volumeLabel, "SD card or USB drive");
      expect(info.path, "/storage/1A2B-3C4D/Media/Shared");
    });

    test("a picked document below the tree still names the tree's folder", () {
      final StorageLocationInfo info = of(
        StorageBackendType.saf,
        "content://com.android.externalstorage.documents/tree/primary%3AMusic/document/primary%3AMusic%2Fa.mp3",
      );

      expect(info.path, "/storage/emulated/0/Music");
    });

    test("something that isn't a tree address is shown as it is, not guessed at", () {
      final StorageLocationInfo info = of(StorageBackendType.saf, "content://weird/thing");

      expect(info.volumeLabel, "Chosen folder");
      expect(info.path, "content://weird/thing");
    });

    test("a stray percent sign doesn't crash it", () {
      final StorageLocationInfo info = of(
        StorageBackendType.saf,
        "content://com.android.externalstorage.documents/tree/primary%3A100%",
      );

      expect(info.path, isNotEmpty);
    });
  });

  group("a filesystem path", () {
    test("under internal storage", () {
      expect(of(StorageBackendType.direct, "/storage/emulated/0/Download").kind, VolumeKind.internal);
      expect(of(StorageBackendType.direct, "/sdcard/Download").volumeLabel, "Internal storage");
    });

    test("on removable storage", () {
      final StorageLocationInfo info = of(StorageBackendType.direct, "/storage/1A2B-3C4D/Backups");

      expect(info.kind, VolumeKind.removable);
      expect(info.path, "/storage/1A2B-3C4D/Backups");
    });

    test("inside the app's own private space", () {
      final StorageLocationInfo info = of(StorageBackendType.direct, "/data/user/0/com.vaultbox.app/files/storage");

      expect(info.kind, VolumeKind.appPrivate);
      expect(info.volumeLabel, "App storage");
    });
  });

  test("testing and vault roots are labelled for what they are", () {
    expect(of(StorageBackendType.memory, "memory://x").kind, VolumeKind.memory);
    expect(of(StorageBackendType.vault, "/data/vault").volumeLabel, "Encrypted vault");
  });
}
