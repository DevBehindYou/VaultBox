import "../../domain/entities/server_state.dart";
import "../../domain/entities/share.dart";

/// Where a share link should point: the server's own address, preferring the
/// encrypted one. `null` when the server isn't running (there is no address yet).
///
/// The server reports its addresses with a trailing slash (`https://host:8443/`).
String? shareLinkBase(ServerState server) {
  if (!server.isRunning) return null;
  // Only web addresses: the server may also list FTP ones (ftp://, ftps://).
  final List<String> urls = <String>[
    for (final String url in server.endpoints.isNotEmpty
        ? server.endpoints
        : <String>[if (server.endpoint != null) server.endpoint!])
      if (url.startsWith("http://") || url.startsWith("https://")) url,
  ];
  for (final String url in urls) {
    if (url.startsWith("https://")) return url;
  }
  return urls.isEmpty ? null : urls.first;
}

/// The address to give people: `<base>s/<token>` to download, `<base>u/<token>` to upload.
String shareUrl(String base, ShareKind kind, String token) {
  final String withSlash = base.endsWith("/") ? base : "$base/";
  return "$withSlash${kind == ShareKind.download ? "s" : "u"}/$token";
}

/// Whether [url] would send everything (including a link's password) unencrypted.
bool isUnencrypted(String url) {
  if (!url.startsWith("http://")) return false;
  final String host = Uri.tryParse(url)?.host ?? "";
  return host != "127.0.0.1" && host != "localhost";
}

/// Human wording for how long a link lasts.
String describeExpiry(DateTime? expiresAt, DateTime now) {
  if (expiresAt == null) return "No expiry";
  if (!now.isBefore(expiresAt)) return "Expired";
  final Duration left = expiresAt.difference(now);
  if (left.inDays >= 2) return "Expires in ${left.inDays} days";
  if (left.inHours >= 2) return "Expires in ${left.inHours} hours";
  if (left.inMinutes >= 2) return "Expires in ${left.inMinutes} minutes";
  return "Expires in a minute";
}

/// Short state of a link for its list row.
String describeShareState(Share share, DateTime now) {
  if (share.isExpired(now)) return "Expired";
  if (share.isUsedUp) return "Used up";
  return "Active";
}
