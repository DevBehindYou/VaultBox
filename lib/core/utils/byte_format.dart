/// Human-readable byte formatting for storage meters, file rows and transfer
/// speed/throughput readouts (Aurora Glass telemetry style — see
/// `aurora_typography.dart` doc comment: these values should be rendered in
/// [AuroraFonts.mono] with tabular figures wherever they update live).
abstract final class ByteFormat {
  static const List<String> _units = <String>["B", "KB", "MB", "GB", "TB", "PB"];

  /// e.g. `1536` -> `1.5 KB`, `102800000000` -> `102.8 GB`.
  static String format(int bytes, {int decimals = 1}) {
    if (bytes <= 0) return "0 B";
    double value = bytes.toDouble();
    int unitIndex = 0;
    while (value >= 1024 && unitIndex < _units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    final String formatted = unitIndex == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(decimals);
    return "$formatted ${_units[unitIndex]}";
  }

  /// Transfer speed, e.g. `format(14_800_000)` -> `14.8 MB/s`.
  static String formatRate(double bytesPerSecond, {int decimals = 1}) {
    return "${format(bytesPerSecond.round(), decimals: decimals)}/s";
  }

  /// Compact ETA formatting for transfer rows — e.g. `Duration(seconds: 45)`
  /// -> `45s`, `Duration(minutes: 3, seconds: 5)` -> `3m 05s`.
  static String formatEta(Duration eta) {
    if (eta.inHours > 0) {
      final int minutes = eta.inMinutes.remainder(60);
      return "${eta.inHours}h ${minutes.toString().padLeft(2, '0')}m";
    }
    if (eta.inMinutes > 0) {
      final int seconds = eta.inSeconds.remainder(60);
      return "${eta.inMinutes}m ${seconds.toString().padLeft(2, '0')}s";
    }
    return "${eta.inSeconds}s";
  }
}
