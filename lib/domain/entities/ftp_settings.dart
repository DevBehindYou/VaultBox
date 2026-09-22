/// How the FTP server protects its connections.
enum FtpMode {
  /// FTP with TLS switched on by the client (`AUTH TLS`). Passwords and files
  /// are encrypted; anything that skips the upgrade is refused. What most
  /// current FTP apps use.
  explicitTls,

  /// The connection is encrypted from its very first byte. Older, but some
  /// scanners and cameras only speak this.
  implicitTls,

  /// Plain FTP: passwords and files cross the network in clear text.
  plain,
}

/// The FTP server's settings. Off by default; when on, the safest mode is chosen.
final class FtpSettings {
  const FtpSettings({
    this.enabled = false,
    this.mode = FtpMode.explicitTls,
    this.port = defaultPort,
    this.passiveStart = defaultPassiveStart,
    this.passiveEnd = defaultPassiveEnd,
  });

  static const int defaultPort = 2121;
  static const int defaultPassiveStart = 50000;
  static const int defaultPassiveEnd = 50050;

  final bool enabled;
  final FtpMode mode;

  /// The control port (ports below 1024 are reserved on Android).
  final int port;

  /// The range file transfers use. Firewalls and routers between the phone and
  /// a client need to allow it.
  final int passiveStart;
  final int passiveEnd;

  bool get usesTls => mode != FtpMode.plain;

  FtpSettings copyWith({bool? enabled, FtpMode? mode, int? port, int? passiveStart, int? passiveEnd}) => FtpSettings(
    enabled: enabled ?? this.enabled,
    mode: mode ?? this.mode,
    port: port ?? this.port,
    passiveStart: passiveStart ?? this.passiveStart,
    passiveEnd: passiveEnd ?? this.passiveEnd,
  );

  /// Words for a bad port, or `null` when it is fine.
  static String? validatePort(int? port) {
    if (port == null || port < 1024 || port > 65535) return "Use a number from 1024 to 65535.";
    return null;
  }

  /// Words for a bad passive range, or `null` when it is fine. At least ten
  /// ports, so a few transfers at once don't run out.
  static String? validatePassiveRange(int? start, int? end) {
    if (start == null || end == null || start < 1024 || end > 65535 || start > end) {
      return "Use two numbers from 1024 to 65535, the second not smaller than the first.";
    }
    if (end - start < 9) return "Give it at least 10 ports.";
    if (end - start > 1000) return "Keep it to 1000 ports or fewer.";
    return null;
  }

  static const String _enabledKey = "ftp.enabled";
  static const String _modeKey = "ftp.mode";
  static const String _portKey = "ftp.port";
  static const String _startKey = "ftp.pasvStart";
  static const String _endKey = "ftp.pasvEnd";

  Map<String, String> toMap() => <String, String>{
    _enabledKey: enabled.toString(),
    _modeKey: mode.name,
    _portKey: "$port",
    _startKey: "$passiveStart",
    _endKey: "$passiveEnd",
  };

  /// Reads what [toMap] wrote. Anything missing or unusable falls back to its
  /// default, so damaged settings can't start the server in a surprising mode.
  factory FtpSettings.fromMap(Map<String, String> map) {
    FtpMode mode = FtpMode.explicitTls;
    for (final FtpMode candidate in FtpMode.values) {
      if (candidate.name == map[_modeKey]) mode = candidate;
    }
    final int? port = int.tryParse(map[_portKey] ?? "");
    final int? start = int.tryParse(map[_startKey] ?? "");
    final int? end = int.tryParse(map[_endKey] ?? "");
    final bool rangeOk = validatePassiveRange(start, end) == null;
    return FtpSettings(
      enabled: map[_enabledKey] == "true",
      mode: mode,
      port: validatePort(port) == null ? port! : defaultPort,
      passiveStart: rangeOk ? start! : defaultPassiveStart,
      passiveEnd: rangeOk ? end! : defaultPassiveEnd,
    );
  }
}
