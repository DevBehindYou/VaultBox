import "../../domain/entities/storage_root.dart";

/// Where a storage location lives, in words a person recognises.
enum VolumeKind {
  /// The phone's own storage.
  internal,

  /// An SD card or USB drive.
  removable,

  /// A folder private to VaultBox.
  appPrivate,

  /// Something without a real place (used by tests).
  memory,
}

final class StorageLocationInfo {
  const StorageLocationInfo({required this.kind, required this.volumeLabel, required this.path});

  final VolumeKind kind;

  /// "Internal storage", "SD card or USB drive", …
  final String volumeLabel;

  /// The folder as a path a person would type: `/storage/emulated/0/Download/Atomic-Carton`.
  final String path;
}

/// Works out the volume and folder of [root] from where it points. Pure, so it
/// can be tested without a phone.
StorageLocationInfo describeStorageRoot(StorageRoot root) {
  switch (root.backendType) {
    case StorageBackendType.memory:
      return const StorageLocationInfo(kind: VolumeKind.memory, volumeLabel: "Memory (testing)", path: "memory");
    case StorageBackendType.vault:
      return StorageLocationInfo(kind: VolumeKind.appPrivate, volumeLabel: "Encrypted vault", path: root.uriOrPath);
    case StorageBackendType.direct:
      return _fromPath(root.uriOrPath);
    case StorageBackendType.saf:
      return _fromTree(root.uriOrPath);
  }
}

StorageLocationInfo _fromPath(String path) {
  if (path.startsWith("/storage/emulated/") || path.startsWith("/sdcard")) {
    return StorageLocationInfo(kind: VolumeKind.internal, volumeLabel: "Internal storage", path: path);
  }
  if (path.startsWith("/storage/")) {
    return StorageLocationInfo(kind: VolumeKind.removable, volumeLabel: "SD card or USB drive", path: path);
  }
  return StorageLocationInfo(kind: VolumeKind.appPrivate, volumeLabel: "App storage", path: path);
}

/// `content://com.android.externalstorage.documents/tree/<volume>%3A<folder>`.
StorageLocationInfo _fromTree(String uri) {
  const String marker = "/tree/";
  final int at = uri.indexOf(marker);
  if (at == -1) return StorageLocationInfo(kind: VolumeKind.removable, volumeLabel: "Chosen folder", path: uri);

  String id = uri.substring(at + marker.length);
  final int documentAt = id.indexOf("/document/");
  if (documentAt != -1) id = id.substring(0, documentAt);
  try {
    id = Uri.decodeComponent(id);
  } on ArgumentError {
    // keep the raw text
  }

  final int colon = id.indexOf(":");
  final String volume = colon == -1 ? id : id.substring(0, colon);
  final String folder = colon == -1 ? "" : id.substring(colon + 1);
  final String tail = folder.isEmpty ? "" : "/$folder";

  if (volume == "primary") {
    return StorageLocationInfo(kind: VolumeKind.internal, volumeLabel: "Internal storage", path: "/storage/emulated/0$tail");
  }
  return StorageLocationInfo(kind: VolumeKind.removable, volumeLabel: "SD card or USB drive", path: "/storage/$volume$tail");
}
