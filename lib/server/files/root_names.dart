import "../../domain/entities/storage_root.dart";

/// The name each storage location goes by inside a protocol's folder tree
/// (WebDAV's `/dav/<name>/…`, FTP's `/<name>/…`): its display name made safe
/// for a path, with `-2`, `-3`… added when two locations would share one.
final class RootNames {
  RootNames._(this.bySlug, this.slugById);

  factory RootNames.of(List<StorageRoot> roots) {
    final Map<String, StorageRoot> bySlug = <String, StorageRoot>{};
    final Map<String, String> slugById = <String, String>{};
    for (final StorageRoot root in roots) {
      final String base = slugify(root.displayName);
      String slug = base;
      int n = 2;
      while (bySlug.containsKey(slug.toLowerCase())) {
        slug = "$base-${n++}";
      }
      bySlug[slug.toLowerCase()] = root;
      slugById[root.id] = slug;
    }
    return RootNames._(bySlug, slugById);
  }

  /// Locations by lower-cased name.
  final Map<String, StorageRoot> bySlug;

  /// The name (with its original capitalisation) by location id.
  final Map<String, String> slugById;

  /// The location called [name] (in any capitalisation), or `null`.
  StorageRoot? byName(String name) => bySlug[name.toLowerCase()];

  /// What [rootId] is called, or `null`.
  String? nameOf(String rootId) => slugById[rootId];

  static String slugify(String name) {
    final String cleaned = name
        .replaceAll(RegExp(r"[^\p{L}\p{N}._-]+", unicode: true), "-")
        .replaceAll(RegExp(r"^-+|-+$"), "");
    return cleaned.isEmpty ? "storage" : cleaned;
  }
}
