import "dart:async";

import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/domain/entities/server_config.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/domain/repositories/server_host.dart";

/// In-memory [ServerHost]: start() goes starting -> running unless told to stall.
final class FakeServerHost implements ServerHost {
  FakeServerHost([ServerState initial = const ServerState.stopped()]) : _current = initial;

  static const String endpoint = "https://127.0.0.1:8443/";
  static const String fingerprint = "AB:CD:EF:01:23:45:67:89";

  ServerState _current;
  final StreamController<ServerState> _changes = StreamController<ServerState>.broadcast();

  int starts = 0;
  int stops = 0;

  /// Last config saved via [saveConfig] (starts as the safe defaults).
  ServerConfig savedConfig = const ServerConfig();

  /// When set, start() throws it.
  AppFailure? failStart;

  /// When true, start() stops at "starting" (never reaches running).
  bool holdInStarting = false;

  void emit(ServerState state) {
    _current = state;
    _changes.add(state);
  }

  @override
  Stream<ServerState> watch() async* {
    yield _current;
    yield* _changes.stream;
  }

  @override
  Future<void> start() async {
    starts++;
    final AppFailure? failure = failStart;
    if (failure != null) throw failure;
    emit(const ServerState(run: ServerRunState.starting));
    if (!holdInStarting) {
      emit(const ServerState(run: ServerRunState.running, endpoint: endpoint));
    }
  }

  @override
  Future<void> stop() async {
    stops++;
    emit(const ServerState.stopped());
  }

  @override
  Future<ServerConfig> config() async => savedConfig;

  @override
  Future<void> saveConfig(ServerConfig config) async => savedConfig = config;

  @override
  Future<String> tlsFingerprint() async => fingerprint;
}
