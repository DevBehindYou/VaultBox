/// Usernames: 3–32 characters, lower-case letters, digits, `.` `_` `-`, starting
/// with a letter or digit. Case-insensitive (stored lower-case), so "Admin" and
/// "admin" are the same person and can't be used to impersonate each other.
abstract final class UsernamePolicy {
  static const int minLength = 3;
  static const int maxLength = 32;
  static final RegExp _allowed = RegExp(r"^[a-z0-9][a-z0-9._-]*$");

  static String normalize(String raw) => raw.trim().toLowerCase();

  /// `null` if [normalized] is acceptable, else a message safe to show.
  static String? validate(String normalized) {
    if (normalized.length < minLength) return "Use at least $minLength characters.";
    if (normalized.length > maxLength) return "Use at most $maxLength characters.";
    if (!_allowed.hasMatch(normalized)) {
      return "Use letters, digits, dots, dashes and underscores (start with a letter or digit).";
    }
    return null;
  }
}
