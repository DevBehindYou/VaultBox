import "dart:convert";
import "dart:math";

import "package:crypto/crypto.dart";

/// Secrets for share links.
///
/// A token is 256 bits from a CSPRNG (43 URL-safe characters). Only its SHA-256
/// is ever stored, so a copy of the database can't be turned into working links.
abstract final class ShareTokens {
  static String generate([Random? random]) {
    final Random rng = random ?? Random.secure();
    final List<int> bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll("=", "");
  }

  static String hash(String token) => sha256.convert(utf8.encode(token)).toString();

  /// Cheap sanity check before touching storage with a client-supplied token.
  static bool looksValid(String token) => token.length == 43 && RegExp(r"^[A-Za-z0-9_-]+$").hasMatch(token);
}
