/// Folder paths as an FTP client writes them, worked out against the folder it
/// is currently in.
///
/// The tree is virtual: `/` lists the storage locations, `/Phone/Photos` is a
/// folder inside one of them. Nothing here touches storage; it only turns text
/// into a list of names, and it can never go above `/` however many `..` it is
/// given.
List<String> resolveFtpPath(List<String> currentFolder, String argument) {
  final List<String> segments = argument.startsWith("/") || argument == "~"
      ? <String>[]
      : List<String>.of(currentFolder);
  for (final String part in argument.split("/")) {
    if (part.isEmpty || part == "." || part == "~") continue;
    if (part == "..") {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }
    segments.add(part);
  }
  return segments;
}

/// `/Phone/Photos` (and `/` for the top).
String formatFtpPath(List<String> segments) => "/${segments.join("/")}";

/// A path inside a 257 reply: it goes between double quotes, and a quote inside
/// it is doubled (RFC 959).
String quoteFtpPath(String path) => '"${path.replaceAll('"', '""')}"';

/// What follows a command word: `CWD  my folder` -> ` my folder` kept as typed
/// after exactly one separating space, so names with spaces survive.
///
/// `null` when nothing follows.
String? ftpArgument(String line) {
  final int space = line.indexOf(" ");
  if (space == -1) return null;
  final String rest = line.substring(space + 1);
  return rest.isEmpty ? null : rest;
}

/// Splits `LIST -la some folder` into its option flags and the path. Most FTP
/// clients send `-a`/`-l` flags with LIST; they mean nothing here.
String? stripListFlags(String? argument) {
  if (argument == null) return null;
  String rest = argument;
  while (rest.startsWith("-")) {
    final int space = rest.indexOf(" ");
    if (space == -1) return null;
    rest = rest.substring(space + 1);
  }
  return rest.isEmpty ? null : rest;
}
