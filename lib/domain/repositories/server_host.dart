import "../entities/server_config.dart";
import "../entities/server_state.dart";

/// Starts, stops, configures and observes the server host. The real
/// implementation talks to the Android Foreground Service (`PigeonServerHost`);
/// tests use a fake.
abstract interface class ServerHost {
  /// Emits the current state first, then every change.
  Stream<ServerState> watch();

  /// Asks the service to start. Returns once the request is made — progress
  /// arrives through [watch] (starting -> running | failed).
  Future<void> start();

  Future<void> stop();

  Future<ServerConfig> config();

  /// Persists settings. They take effect the next time the server starts.
  Future<void> saveConfig(ServerConfig config);

  /// SHA-256 fingerprint of the server's TLS certificate (colon-separated hex),
  /// for a person to compare against their browser's certificate warning.
  /// Creates the certificate on first use.
  Future<String> tlsFingerprint();
}
