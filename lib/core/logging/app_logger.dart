import "package:logging/logging.dart";

/// Structured logging entry point, per `20_Coding_Standards_...md`
/// ("Use structured logger. No print() through production logic") and
/// `16_Observability_...md` (timestamp/level/component/event/requestId/
/// operationId/redacted context).
///
/// This wraps package:logging rather than inventing a bespoke logger — it
/// already gives level, timestamp and named-logger (component) for free.
/// [AppLogger.of] should be called once per class/component and held as a
/// field, mirroring `Logger('ComponentName')` convention.
abstract final class AppLogger {
  static bool _initialized = false;

  /// Call once at app startup (see `lib/app/bootstrap/bootstrap.dart`).
  static void init({Level level = Level.INFO}) {
    if (_initialized) return;
    _initialized = true;
    Logger.root.level = level;
    Logger.root.onRecord.listen((LogRecord record) {
      // In production this sink should ship to the diagnostics/support-bundle
      // pipeline (doc §16). For now it's stdout via `debugPrint`-equivalent,
      // which is acceptable for a logging *sink* (as opposed to ad-hoc
      // `print()` calls scattered through business logic, which is what the
      // lint / doc rule actually forbids).
      final StringBuffer line = StringBuffer()
        ..write(record.time.toIso8601String())
        ..write(" [")
        ..write(record.level.name)
        ..write("] ")
        ..write(record.loggerName)
        ..write(": ")
        ..write(redact(record.message));
      // ignore: avoid_print
      print(line.toString());
    });
  }

  static Logger of(String component) => Logger(component);

  /// Best-effort redaction for anything accidentally logged that looks like
  /// a secret. This is a *safety net*, not a substitute for never logging
  /// secrets in the first place (doc §12/§57: password, API token, share
  /// token, session cookie, Authorization header, Vault key, plaintext file
  /// content must never be passed to the logger at all).
  static String redact(String message) {
    return message
        .replaceAll(
          RegExp(r"(Authorization:\s*Bearer)\s+\S+", caseSensitive: false),
          r"$1 [redacted]",
        )
        .replaceAll(
          RegExp(r"(password|token|secret)\s*[:=]\s*\S+", caseSensitive: false),
          r"$1=[redacted]",
        );
  }
}
