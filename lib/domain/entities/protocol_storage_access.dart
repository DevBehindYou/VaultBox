/// Which protocol is asking [StorageGate] for a root or a listing — the unit
/// [ProtocolStorageAccess] restricts independently, one set of allowed roots
/// per protocol (kickoff: "each protocol its own card, and in there we can
/// set up whether to show, access the external or internal storage").
enum ProtocolKind {
  /// The browser portal over HTTPS.
  webPortalHttps,

  /// The browser portal over plain, unencrypted HTTP.
  plainHttp,
  webdav,
  ftp,

  /// A previously-created share/upload link. Never restricted by this
  /// mechanism: a link was already scoped to one root+path the moment it was
  /// made (`PublicEndpoints`), so hiding a root from, say, WebDAV must not
  /// retroactively break a link someone already has.
  shareLink,
}

/// Per-protocol storage-root visibility, persisted as a handful of keys in
/// the app's generic key-value settings store (same store [FtpSettings]
/// uses — no schema migration needed for this).
///
/// A `null` set for a protocol means **unrestricted**: every enabled root is
/// visible to it, which is the default and matches every installation that
/// existed before this feature — nobody's server surface change unless they
/// open the new "Storage access" section and choose something. An empty
/// (non-null) set means the person deliberately unchecked every root: that
/// protocol serves nothing.
final class ProtocolStorageAccess {
  const ProtocolStorageAccess({
    this.webPortalHttpsRootIds,
    this.plainHttpRootIds,
    this.webdavRootIds,
    this.ftpRootIds,
  });

  final Set<String>? webPortalHttpsRootIds;
  final Set<String>? plainHttpRootIds;
  final Set<String>? webdavRootIds;
  final Set<String>? ftpRootIds;

  /// The configured set for [protocol], or `null` for [ProtocolKind.shareLink]
  /// (which has no card and is never restricted — see the class doc).
  Set<String>? forProtocol(ProtocolKind protocol) => switch (protocol) {
    ProtocolKind.webPortalHttps => webPortalHttpsRootIds,
    ProtocolKind.plainHttp => plainHttpRootIds,
    ProtocolKind.webdav => webdavRootIds,
    ProtocolKind.ftp => ftpRootIds,
    ProtocolKind.shareLink => null,
  };

  ProtocolStorageAccess withProtocol(ProtocolKind protocol, Set<String>? rootIds) {
    return ProtocolStorageAccess(
      webPortalHttpsRootIds: protocol == ProtocolKind.webPortalHttps ? rootIds : webPortalHttpsRootIds,
      plainHttpRootIds: protocol == ProtocolKind.plainHttp ? rootIds : plainHttpRootIds,
      webdavRootIds: protocol == ProtocolKind.webdav ? rootIds : webdavRootIds,
      ftpRootIds: protocol == ProtocolKind.ftp ? rootIds : ftpRootIds,
    );
  }

  static const String _keyWebPortalHttps = "protocol_access_web_portal_https";
  static const String _keyPlainHttp = "protocol_access_plain_http";
  static const String _keyWebdav = "protocol_access_webdav";
  static const String _keyFtp = "protocol_access_ftp";

  /// Marks "unrestricted" as a real, written value — not just an absent key —
  /// because [SettingsRepository] has no delete: `writeAll` only ever upserts.
  /// Without this sentinel, turning a restriction back off could never be
  /// told apart, on the next read, from having never restricted it (the key
  /// from the earlier restriction would still be sitting in the store).
  static const String _unrestricted = "*";

  factory ProtocolStorageAccess.fromMap(Map<String, String> map) {
    return ProtocolStorageAccess(
      webPortalHttpsRootIds: _decode(map[_keyWebPortalHttps]),
      plainHttpRootIds: _decode(map[_keyPlainHttp]),
      webdavRootIds: _decode(map[_keyWebdav]),
      ftpRootIds: _decode(map[_keyFtp]),
    );
  }

  Map<String, String> toMap() => <String, String>{
    _keyWebPortalHttps: _encode(webPortalHttpsRootIds),
    _keyPlainHttp: _encode(plainHttpRootIds),
    _keyWebdav: _encode(webdavRootIds),
    _keyFtp: _encode(ftpRootIds),
  };

  static String _encode(Set<String>? ids) => ids == null ? _unrestricted : ids.join(",");

  /// `null` (key absent — nobody has ever touched this install's settings)
  /// or the literal `"*"` (touched, then explicitly set back to
  /// unrestricted) both mean unrestricted. `""` means deliberately zero
  /// roots. Anything else is that comma-joined id set.
  static Set<String>? _decode(String? raw) {
    if (raw == null || raw == _unrestricted) return null;
    if (raw.isEmpty) return const <String>{};
    return raw.split(",").toSet();
  }
}
