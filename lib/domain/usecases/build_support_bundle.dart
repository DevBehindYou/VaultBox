import "../entities/activity.dart";
import "../entities/diagnostic.dart";
import "../entities/server_config.dart";
import "../entities/server_state.dart";

/// The text a person can send along with a bug report.
///
/// It is safe to share by construction: it names no person, address, file,
/// folder, storage location or link, and holds no password or token — only
/// versions, settings, counts and the outcome of each health check. (Events are
/// listed by kind and time; their sentences, which can name people and
/// addresses, are left out.)
String buildSupportBundle({
  required DateTime now,
  required String appVersion,
  required ServerState server,
  required ServerConfig config,
  required List<DiagnosticCheck> checks,
  required List<ActivityEvent> events,
  required List<TransferRecord> transfers,
  int maxEvents = 50,
}) {
  final StringBuffer out = StringBuffer()
    ..writeln("Atomic Carton support bundle")
    ..writeln("Made: ${now.toUtc().toIso8601String()}")
    ..writeln("App version: $appVersion")
    ..writeln()
    ..writeln("Server")
    ..writeln("  State: ${server.run.name}");
  if (server.detail != null) out.writeln("  Detail: ${server.detail}");
  final int addresses = server.endpoints.isNotEmpty ? server.endpoints.length : (server.endpoint == null ? 0 : 1);
  out
    ..writeln("  Addresses: $addresses")
    ..writeln("  Network access: ${config.allowNetworkAccess ? "on" : "off"}")
    ..writeln("  HTTPS: ${config.httpsEnabled ? "on (port ${config.port})" : "off"}")
    ..writeln("  HTTP: ${config.httpEnabled ? "on (port ${config.httpPort})" : "off"}")
    ..writeln()
    ..writeln("Checks");
  for (final DiagnosticCheck check in checks) {
    out.writeln("  [${_label(check.status)}] ${check.title}: ${check.detail}");
  }

  int count(TransferState state) => transfers.where((TransferRecord t) => t.state == state).length;
  out
    ..writeln()
    ..writeln("Transfers (most recent ${transfers.length})")
    ..writeln("  Completed: ${count(TransferState.completed)}")
    ..writeln("  Failed: ${count(TransferState.failed)}")
    ..writeln("  Interrupted: ${count(TransferState.interrupted)}")
    ..writeln("  Running: ${count(TransferState.running)}")
    ..writeln()
    ..writeln("Recent events (newest first; wording left out on purpose)");
  for (final ActivityEvent event in events.take(maxEvents)) {
    out.writeln("  ${event.at.toUtc().toIso8601String()}  ${event.severity.name}  ${event.kind.name}");
  }
  return out.toString();
}

String _label(DiagnosticStatus status) => switch (status) {
  DiagnosticStatus.ok => "OK",
  DiagnosticStatus.warning => "WARNING",
  DiagnosticStatus.problem => "PROBLEM",
};
