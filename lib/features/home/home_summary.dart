import "../../domain/entities/activity.dart";
import "../../domain/entities/server_config.dart";
import "../../domain/entities/server_state.dart";
import "../share/share_links.dart";

/// Time since the server last started, from the history the server itself
/// writes. `null` when it isn't running or the start isn't in the history.
Duration? serverUptime(ServerState server, List<ActivityEvent> events, DateTime now) {
  if (!server.isRunning) return null;
  for (final ActivityEvent event in events) {
    // Newest first: the first start we meet is the current one.
    if (event.kind == ActivityKind.serverStarted) {
      final Duration since = now.difference(event.at);
      return since.isNegative ? Duration.zero : since;
    }
  }
  return null;
}

/// `04:28:15` — hours, minutes, seconds.
String formatUptime(Duration uptime) {
  String two(int n) => n.toString().padLeft(2, "0");
  return "${two(uptime.inHours)}:${two(uptime.inMinutes.remainder(60))}:${two(uptime.inSeconds.remainder(60))}";
}

/// The address to show first, without its trailing slash. `null` while the
/// server isn't up.
String? primaryAddress(ServerState server) {
  final String? base = shareLinkBase(server);
  if (base == null) return null;
  return base.endsWith("/") ? base.substring(0, base.length - 1) : base;
}

/// `192.168.1.41:8443` — where to point another device, or `null` when the
/// server only answers on this phone.
String? lanHostPort(ServerState server) {
  final String? address = primaryAddress(server);
  if (address == null) return null;
  final Uri? uri = Uri.tryParse(address);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.host == "127.0.0.1" || uri.host == "localhost") return null;
  return uri.hasPort ? "${uri.host}:${uri.port}" : uri.host;
}

/// One protocol in the row under the server card.
final class ProtocolStatus {
  const ProtocolStatus({required this.label, required this.port, required this.active});

  final String label;

  /// A port number, or a path such as `/dav`.
  final String port;
  final bool active;
}

/// What the server speaks and whether it is listening right now. WebDAV rides
/// on the same listeners as the web portal, under `/dav`.
List<ProtocolStatus> protocolStatuses(ServerState server, ServerConfig? config) {
  final ServerConfig settings = config ?? const ServerConfig();
  final bool running = server.isRunning;
  return <ProtocolStatus>[
    if (settings.httpsEnabled)
      ProtocolStatus(label: "HTTPS", port: "${settings.port}", active: running),
    if (settings.httpEnabled)
      ProtocolStatus(label: "HTTP", port: "${settings.httpPort}", active: running),
    ProtocolStatus(label: "WebDAV", port: "/dav", active: running),
  ];
}
