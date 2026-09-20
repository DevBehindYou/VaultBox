import "package:url_launcher/url_launcher.dart";

/// Opens an address in the phone's browser. Behind an interface so tests don't
/// need a phone.
abstract interface class UrlOpener {
  /// Whether something took the address.
  Future<bool> open(String url);
}

final class LauncherUrlOpener implements UrlOpener {
  const LauncherUrlOpener();

  @override
  Future<bool> open(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      return false;
    }
  }
}
