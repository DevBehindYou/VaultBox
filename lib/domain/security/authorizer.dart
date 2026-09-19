import "../entities/account.dart";
import "../entities/storage_root.dart";
import "../value_objects/storage_path.dart";

/// What a caller is trying to do to a path.
enum Permission {
  /// List, stat and download.
  read,

  /// Upload, create folders, rename, and be the destination of a copy/move.
  write,

  /// Delete (to the Recycle Bin) and be the source of a move.
  delete,
}

/// The one place that decides whether an [Account] may touch a path. Every
/// protocol front end (web API, WebDAV, shares) asks this — never re-implements
/// it — so a rule can't be enforced on one surface and forgotten on another.
abstract interface class Authorizer {
  bool allows(Account account, Permission permission, StorageRoot root, StoragePath path);
}

/// Every account is currently the admin (only one can exist), and the admin may
/// do everything. Replaced by the role/ACL-based authorizer when more accounts
/// exist — endpoints already ask per path, so nothing else has to change.
final class SingleAdminAuthorizer implements Authorizer {
  const SingleAdminAuthorizer();

  @override
  bool allows(Account account, Permission permission, StorageRoot root, StoragePath path) => true;
}
