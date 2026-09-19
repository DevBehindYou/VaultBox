/// `Content-Disposition` for a download: an ASCII-safe `filename` fallback plus
/// the real name as RFC 5987 `filename*`, so any file name survives the header.
String contentDisposition(String name, {required bool inline}) {
  final String ascii = name.replaceAll(RegExp(r"[^A-Za-z0-9._ -]"), "_");
  final String encoded = Uri.encodeComponent(name).replaceAll("'", "%27");
  return "${inline ? "inline" : "attachment"}; filename=\"$ascii\"; filename*=UTF-8''$encoded";
}

/// Sent with every downloaded file: even if a browser opens it directly, a
/// hostile file can't run script as this server.
const String downloadContentSecurityPolicy = "sandbox; default-src 'none'; style-src 'unsafe-inline'";
