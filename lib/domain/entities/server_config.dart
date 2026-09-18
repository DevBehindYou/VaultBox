/// Persisted server settings. Safe defaults: loopback only, HTTPS on (8443),
/// plain HTTP off (8080).
final class ServerConfig {
  const ServerConfig({
    this.allowNetworkAccess = false,
    this.port = defaultPort,
    this.httpsEnabled = true,
    this.httpEnabled = false,
    this.httpPort = defaultHttpPort,
  });

  static const int defaultPort = 8443;
  static const int defaultHttpPort = 8080;

  /// false = reachable from this phone only; true = reachable from the local network.
  final bool allowNetworkAccess;

  /// HTTPS port.
  final int port;

  /// Encrypted. Recommended.
  final bool httpsEnabled;

  /// NOT encrypted: passwords cross the network in clear text. Explicit opt-in.
  final bool httpEnabled;
  final int httpPort;

  ServerConfig copyWith({
    bool? allowNetworkAccess,
    int? port,
    bool? httpsEnabled,
    bool? httpEnabled,
    int? httpPort,
  }) => ServerConfig(
    allowNetworkAccess: allowNetworkAccess ?? this.allowNetworkAccess,
    port: port ?? this.port,
    httpsEnabled: httpsEnabled ?? this.httpsEnabled,
    httpEnabled: httpEnabled ?? this.httpEnabled,
    httpPort: httpPort ?? this.httpPort,
  );
}
