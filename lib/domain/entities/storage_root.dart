import "../value_objects/storage_capabilities.dart";

enum StorageBackendType { direct, saf, memory, vault }

/// A configured storage root (doc §06 `storage_roots` table — this is the
/// in-memory domain shape; `data/db/app_database.dart` defines the persisted
/// Drift row and a repository maps between the two).
final class StorageRoot {
  const StorageRoot({
    required this.id,
    required this.displayName,
    required this.backendType,
    required this.uriOrPath,
    required this.capabilities,
    this.isDefault = false,
    this.isEnabled = true,
    this.isRemovable = false,
    this.isAvailable = true,
    this.freeBytes,
    this.totalBytes,
    this.rootDocumentId,
  });

  final String id;
  final String displayName;
  final StorageBackendType backendType;

  /// `content://...` URI for SAF roots, or an absolute filesystem path for
  /// direct-path roots. Never exposed to remote clients directly — protocol
  /// handlers only ever see [id] + a [StoragePath] built against it (doc §21
  /// "Storage roots": clients receive `id`/`name`/`available`/`writable`/
  /// `freeBytes`, never the raw URI or path).
  final String uriOrPath;

  final StorageCapabilities capabilities;
  final bool isDefault;
  final bool isEnabled;

  /// True for SD card / USB roots that can physically disappear — surfaces
  /// `StorageDisconnectedFailure` handling (doc §11 "Storage disconnect").
  final bool isRemovable;

  /// Live reachability, distinct from [isEnabled] (user choice) — set false
  /// when a removable root's last health check failed.
  final bool isAvailable;

  final int? freeBytes;
  final int? totalBytes;

  /// SAF only: the tree's top-level document id (`DocumentsContract
  /// .getTreeDocumentId`), where path resolution starts. Null for every other
  /// backend type.
  final String? rootDocumentId;

  StorageRoot copyWith({
    bool? isDefault,
    bool? isEnabled,
    bool? isAvailable,
    int? freeBytes,
    int? totalBytes,
  }) {
    return StorageRoot(
      id: id,
      displayName: displayName,
      backendType: backendType,
      uriOrPath: uriOrPath,
      capabilities: capabilities,
      isDefault: isDefault ?? this.isDefault,
      isEnabled: isEnabled ?? this.isEnabled,
      isRemovable: isRemovable,
      isAvailable: isAvailable ?? this.isAvailable,
      freeBytes: freeBytes ?? this.freeBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      rootDocumentId: rootDocumentId,
    );
  }
}
