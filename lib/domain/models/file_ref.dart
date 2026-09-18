import "../entities/storage_root.dart";
import "../value_objects/storage_path.dart";

/// A fully-resolved reference to one item: which root it lives in, and its
/// path within that root. Batch use cases (`CopyItems`, `MoveItems`, ...)
/// operate on lists of these rather than bare [StoragePath]s, because a
/// single batch can legitimately span two different roots (e.g. "copy from
/// SD card to internal storage").
final class FileRef {
  const FileRef({required this.root, required this.path});

  final StorageRoot root;
  final StoragePath path;

  String get name => path.name;

  @override
  bool operator ==(Object other) =>
      other is FileRef && other.root.id == root.id && other.path == path;

  @override
  int get hashCode => Object.hash(root.id, path);

  @override
  String toString() => "FileRef(${root.id}:${path.normalized})";
}
