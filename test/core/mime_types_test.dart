import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/core/utils/mime_types.dart";

void main() {
  test("known extensions, case-insensitively", () {
    expect(MimeTypes.forName("photo.JPG"), "image/jpeg");
    expect(MimeTypes.forName("notes.txt"), "text/plain");
    expect(MimeTypes.forName("archive.tar.gz"), "application/gzip");
  });

  test("unknown, missing and hidden-file extensions fall back to octet-stream", () {
    expect(MimeTypes.forName("README"), MimeTypes.fallback);
    expect(MimeTypes.forName("data.unknownext"), MimeTypes.fallback);
    expect(MimeTypes.forName(".gitignore"), MimeTypes.fallback);
    expect(MimeTypes.forName("trailingdot."), MimeTypes.fallback);
  });

  test("only script-free types may be shown inline", () {
    for (final String type in <String>["image/png", "video/mp4", "audio/mpeg", "text/plain", "text/plain; charset=utf-8"]) {
      expect(MimeTypes.isSafeToDisplayInline(type), isTrue, reason: type);
    }
    for (final String type in <String>["text/html", "image/svg+xml", "application/xml", "application/pdf", "application/javascript", MimeTypes.fallback]) {
      expect(MimeTypes.isSafeToDisplayInline(type), isFalse, reason: type);
    }
  });
}
