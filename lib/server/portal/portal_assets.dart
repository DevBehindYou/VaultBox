import "dart:convert";

import "portal_bundle.dart";

/// One static file of the web portal.
final class PortalAsset {
  const PortalAsset(this.bytes, this.contentType);

  final List<int> bytes;
  final String contentType;
}

/// The browser portal: one HTML page, one stylesheet, one script — all served
/// from the phone itself, so it works with no internet and loads nothing from
/// anyone else. The page talks to the same `/api/v1` as any other client.
///
/// The source lives in `assets/portal/` and is embedded by
/// `tool/embed_portal.py` (a test keeps the two in step).
final class PortalAssets {
  const PortalAssets();

  /// Strict: only this server's own script and style, no inline anything, no
  /// framing, no form posts. `img-src` allows `data:`/`blob:` for previews.
  static const String contentSecurityPolicy =
      "default-src 'none'; script-src 'self'; style-src 'self'; "
      "img-src 'self' data: blob:; media-src 'self'; connect-src 'self'; "
      "base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

  static final PortalAsset _index = PortalAsset(utf8.encode(portalIndexHtml), "text/html; charset=utf-8");
  static final PortalAsset _css = PortalAsset(utf8.encode(portalCss), "text/css; charset=utf-8");
  static final PortalAsset _js = PortalAsset(utf8.encode(portalJs), "text/javascript; charset=utf-8");
  static final PortalAsset _publicPage = PortalAsset(utf8.encode(portalPublicHtml), "text/html; charset=utf-8");
  static final PortalAsset _publicJs = PortalAsset(utf8.encode(portalPublicJs), "text/javascript; charset=utf-8");

  /// The asset for an exact URL path, or `null`.
  PortalAsset? lookup(String path) {
    // Share links: /s/<token> (download) and /u/<token> (upload) are one page
    // that reads its token from the address; the token itself is never in a file.
    if (RegExp(r"^/[su]/[A-Za-z0-9_-]{1,128}/?$").hasMatch(path)) return _publicPage;
    return switch (path) {
      "/" || "/index.html" => _index,
      "/portal.css" => _css,
      "/portal.js" => _js,
      "/public.js" => _publicJs,
      _ => null,
    };
  }
}
