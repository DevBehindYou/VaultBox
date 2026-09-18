/// Persisted server settings. Safe defaults: loopback only, port 8443.
final class ServerConfig {
  const ServerConfig({this.allowNetworkAccess = false, this.port = defaultPort});

  static const int defaultPort = 8443;

  /// false = reachable from this phone only; true = reachable from the local network.
  final bool allowNetworkAccess;
  final int port;

  ServerConfig copyWith({bool? allowNetworkAccess, int? port}) => ServerConfig(
    allowNetworkAccess: allowNetworkAccess ?? this.allowNetworkAccess,
    port: port ?? this.port,
  );
}
