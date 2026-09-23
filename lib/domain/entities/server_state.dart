/// Lifecycle of the server host (the Android Foreground Service + its headless
/// Dart runtime). Owned by native code (ADR-006) and mirrored to the UI.
enum ServerRunState { stopped, starting, running, failed }

final class ServerState {
  const ServerState({
    required this.run,
    this.endpoint,
    this.endpoints = const <String>[],
    this.detail,
  });

  const ServerState.stopped() : this(run: ServerRunState.stopped);

  final ServerRunState run;

  /// The primary URL the server answers on, when [run] is running.
  final String? endpoint;

  /// Every URL it answers on (HTTPS and/or HTTP).
  final List<String> endpoints;

  /// Technical failure detail, when [run] is failed. Shown only behind a
  /// "Technical details" disclosure, never as the headline.
  final String? detail;

  bool get isRunning => run == ServerRunState.running;
}
