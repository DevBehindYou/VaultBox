import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/server/portal/portal_assets.dart";
import "package:vaultbox/server/portal/portal_bundle.dart";
import "package:vaultbox/server/request_router.dart";

String _source(String name) => File("assets/portal/$name").readAsStringSync().replaceAll("\r\n", "\n");

void main() {
  group("embedded bundle", () {
    test("matches assets/portal (run: python tool/embed_portal.py)", () {
      expect(portalIndexHtml, _source("index.html"));
      expect(portalCss, _source("portal.css"));
      expect(portalJs, _source("portal.js"));
    });

    test("the page has no inline script, inline style or event-handler attributes", () {
      final String html = portalIndexHtml;
      expect(RegExp(r"<script(?![^>]*\bsrc=)", caseSensitive: false).hasMatch(html), isFalse, reason: "inline <script>");
      expect(RegExp(r"<style", caseSensitive: false).hasMatch(html), isFalse, reason: "inline <style>");
      expect(RegExp(r"\sstyle\s*=", caseSensitive: false).hasMatch(html), isFalse, reason: "style attribute");
      expect(RegExp(r"\son[a-z]+\s*=", caseSensitive: false).hasMatch(html), isFalse, reason: "on* handler");
      expect(html, isNot(contains("http://")));
      expect(html, isNot(contains("https://")), reason: "nothing may load from another site");
    });

    test("the script never builds HTML from data", () {
      for (final String banned in <String>["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"]) {
        expect(portalJs, isNot(contains(banned)), reason: banned);
      }
    });

    test("the style sheet and script reach out to no other site", () {
      expect(portalCss, isNot(contains("url(http")));
      expect(portalCss, isNot(contains("@import")));
      // (The SVG namespace URI is an identifier, not a request.)
      expect(RegExp(r"""["']https?://""").hasMatch(portalJs.replaceAll("http://www.w3.org/2000/svg", "")), isFalse);
    });
  });

  group("served by the router", () {
    late HttpServer server;
    late Uri base;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(const RequestRouter(portal: PortalAssets()).serve(server));
      base = Uri(scheme: "http", host: "127.0.0.1", port: server.port);
    });
    tearDown(() => server.close(force: true));

    Future<(int, HttpHeaders, String)> get(String path, {String method = "GET"}) async {
      final HttpClient client = HttpClient();
      try {
        final HttpClientRequest request = await client.openUrl(method, base.resolve(path));
        final HttpClientResponse response = await request.close();
        return (response.statusCode, response.headers, await utf8.decoder.bind(response).join());
      } finally {
        client.close();
      }
    }

    test("/ and /index.html are the page, with a strict CSP", () async {
      for (final String path in <String>["/", "/index.html"]) {
        final (int status, HttpHeaders headers, String body) = await get(path);
        expect(status, 200, reason: path);
        expect(headers.contentType?.mimeType, "text/html");
        expect(body, portalIndexHtml);
        expect(headers.value("content-security-policy"), PortalAssets.contentSecurityPolicy);
        expect(headers.value("content-security-policy"), contains("script-src 'self'"));
        expect(headers.value("content-security-policy"), isNot(contains("unsafe-inline")));
        expect(headers.value("x-frame-options"), "DENY");
        expect(headers.value("cache-control"), "no-store");
      }
    });

    test("the script and style sheet have the right types", () async {
      final (int jsStatus, HttpHeaders jsHeaders, String js) = await get("/portal.js");
      expect(jsStatus, 200);
      expect(jsHeaders.contentType?.mimeType, "text/javascript");
      expect(js, portalJs);

      final (int cssStatus, HttpHeaders cssHeaders, String css) = await get("/portal.css");
      expect(cssStatus, 200);
      expect(cssHeaders.contentType?.mimeType, "text/css");
      expect(css, portalCss);
    });

    test("HEAD works and other methods are 405", () async {
      final (int headStatus, _, String headBody) = await get("/", method: "HEAD");
      expect(headStatus, 200);
      expect(headBody, isEmpty);

      final (int postStatus, HttpHeaders postHeaders, _) = await get("/portal.js", method: "POST");
      expect(postStatus, 405);
      expect(postHeaders.value("allow"), "GET, HEAD");
    });

    test("other paths are still a plain 404", () async {
      expect((await get("/portal.js.map")).$1, 404);
      expect((await get("/etc/passwd")).$1, 404);
    });

    test("/health/ is unaffected", () async {
      expect((await get("/health/")).$1, 200);
    });
  });
}
