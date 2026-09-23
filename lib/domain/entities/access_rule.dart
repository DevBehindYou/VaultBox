import "../security/permission.dart";
import "../value_objects/storage_path.dart";

/// "This member may do [permissions] in [pathPrefix] (and below) of [rootId]."
///
/// [pathPrefix] is a normalized folder path: `/` for the whole root, `/Photos`
/// or `/Photos/2026` for a folder. Rules only ever grant; there is no deny rule.
final class AccessRule {
  const AccessRule({
    required this.id,
    required this.accountId,
    required this.rootId,
    required this.pathPrefix,
    required this.permissions,
  });

  final String id;
  final String accountId;
  final String rootId;
  final String pathPrefix;
  final Set<Permission> permissions;

  /// The prefix as path segments, or `null` if the stored value doesn't parse.
  /// It went through [StoragePath] validation when written, so `null` means a
  /// damaged database; such a rule grants nothing.
  List<String>? get segments {
    try {
      return StoragePath.parseDecoded(rootId, pathPrefix).segments;
    } on Object {
      return null;
    }
  }

  static const Set<Permission> readOnly = <Permission>{Permission.read};
  static const Set<Permission> readWrite = <Permission>{Permission.read, Permission.write};
  static const Set<Permission> everything = <Permission>{Permission.read, Permission.write, Permission.delete};
}
