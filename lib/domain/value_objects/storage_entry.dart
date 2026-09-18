import "storage_path.dart";

enum StorageEntryType { file, directory }

/// One row in a directory listing. Deliberately minimal — doc §11 "Metadata"
/// distinguishes required listing fields (name/type/path/size-if-available/
/// modified/MIME/root) from optional enrichment (thumbnail/hash/media
/// metadata) that must never block first paint (NFR-PERF-001). Thumbnails and
/// hashes are fetched separately by `ThumbnailRepository` / `HashService`
/// (Phase 1 follow-up / Phase 6), not carried on every [StorageEntry].
final class StorageEntry {
  const StorageEntry({
    required this.path,
    required this.type,
    this.sizeBytes,
    this.modifiedAt,
    this.mimeType,
  });

  final StoragePath path;
  final StorageEntryType type;

  /// Null when the backend can't cheaply report size during enumeration
  /// (e.g. some SAF providers) — UI must handle a missing size gracefully,
  /// never assume 0.
  final int? sizeBytes;
  final DateTime? modifiedAt;
  final String? mimeType;

  String get name => path.name;
  bool get isDirectory => type == StorageEntryType.directory;
  bool get isFile => type == StorageEntryType.file;
}

/// Metadata for a single resolved path — richer than [StorageEntry] since
/// it's fetched on demand (file details sheet, pre-operation checks) rather
/// than for every row in a large directory.
final class StorageStat {
  const StorageStat({
    required this.path,
    required this.type,
    required this.exists,
    this.sizeBytes,
    this.modifiedAt,
    this.mimeType,
  });

  final StoragePath path;
  final StorageEntryType type;
  final bool exists;
  final int? sizeBytes;
  final DateTime? modifiedAt;
  final String? mimeType;
}
