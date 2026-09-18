/// Rules for choosing an admin/user password. Length beats complexity rules
/// (NIST 800-63B): a long passphrase is accepted, "aaaaaaaaaaaa" is not.
abstract final class PasswordPolicy {
  static const int minLength = 12;
  static const int maxLength = 128;

  /// Returns `null` if [password] is acceptable, otherwise a short message safe
  /// to show the person. [username], if given, must not appear in the password.
  static String? validate(String password, {String? username}) {
    if (password.length < minLength) return "Use at least $minLength characters.";
    if (password.length > maxLength) return "Use at most $maxLength characters.";
    if (password.codeUnits.any((int c) => c < 0x20 || c == 0x7F)) {
      return "Remove control characters.";
    }
    if (password.trim().isEmpty) return "The password can't be only spaces.";
    if (password.split("").toSet().length < 5) return "Use a more varied password.";
    final String name = (username ?? "").trim().toLowerCase();
    if (name.length >= 3 && password.toLowerCase().contains(name)) {
      return "Don't include your username in the password.";
    }
    return null;
  }
}
