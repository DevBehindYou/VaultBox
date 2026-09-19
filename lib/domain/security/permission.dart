/// What a caller is trying to do to a path.
enum Permission {
  /// List, stat and download.
  read,

  /// Upload, create folders, rename, and be the destination of a copy/move.
  write,

  /// Delete (to the Recycle Bin) and be the source of a move.
  delete,
}
