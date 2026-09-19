import "../entities/access_rule.dart";
import "../entities/account.dart";
import "../entities/storage_root.dart";
import "../value_objects/storage_path.dart";
import "permission.dart";

export "permission.dart";

/// The one place that decides whether an [Account] may touch a path. Every
/// protocol front end (web API, WebDAV, shares) asks this — never re-implements
/// it — so a rule can't be enforced on one surface and forgotten on another.
abstract interface class Authorizer {
  bool allows(Account account, Permission permission, StorageRoot root, StoragePath path);
}

/// Allows everything to every enabled account. Only for tests and for the
/// period before real accounts existed; the server uses [AclAuthorizer].
final class SingleAdminAuthorizer implements Authorizer {
  const SingleAdminAuthorizer();

  @override
  bool allows(Account account, Permission permission, StorageRoot root, StoragePath path) => true;
}

/// Role + folder-grant based access.
///
///  - a disabled account can do nothing;
///  - an admin can do everything, everywhere;
///  - a member can do exactly what an [AccessRule] grants: a rule names a
///    storage root, a folder in it (`/` = the whole root) and a set of
///    permissions, and applies to that folder and everything below it;
///  - to let a member REACH a granted folder, `read` is also allowed on the
///    folders above it (so they can list down to it) — nothing else is. Listing
///    an ancestor shows only entries the member may see (callers filter with
///    [allows] per entry).
///
/// Deny by default: no rule, no access.
final class AclAuthorizer implements Authorizer {
  const AclAuthorizer();

  @override
  bool allows(Account account, Permission permission, StorageRoot root, StoragePath path) {
    if (!account.isEnabled) return false;
    if (account.isAdmin) return true;

    for (final AccessRule rule in account.rules) {
      if (rule.rootId != root.id) continue;
      final List<String>? granted = rule.segments;
      if (granted == null) continue;
      if (rule.permissions.contains(permission) && _startsWith(path.segments, granted)) return true;
      if (permission == Permission.read && _startsWith(granted, path.segments)) return true;
    }
    return false;
  }

  /// [whole] begins with every segment of [prefix].
  static bool _startsWith(List<String> whole, List<String> prefix) {
    if (prefix.length > whole.length) return false;
    for (int i = 0; i < prefix.length; i++) {
      if (whole[i] != prefix[i]) return false;
    }
    return true;
  }
}
