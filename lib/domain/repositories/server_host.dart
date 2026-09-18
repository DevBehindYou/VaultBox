import "../entities/server_state.dart";

/// Starts, stops and observes the server host. The real implementation talks to
/// the Android Foreground Service (`PigeonServerHost`); tests use a fake.
abstract interface class ServerHost {
  /// Emits the current state first, then every change.
  Stream<ServerState> watch();

  /// Asks the service to start. Returns once the request is made — progress
  /// arrives through [watch] (starting -> running | failed).
  Future<void> start();

  Future<void> stop();
}
