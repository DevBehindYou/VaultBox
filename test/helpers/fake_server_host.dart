import "dart:async";

import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/domain/repositories/server_host.dart";

/// In-memory [ServerHost]: start() goes starting -> running unless told to stall.
final class FakeServerHost implements ServerHost {
  FakeServerHost([ServerState initial = const ServerState.stopped()]) : _current = initial;

  static const String endpoint = "http://127.0.0.1:41234/health/";

  ServerState _current;
  final StreamController<ServerState> _changes = StreamController<ServerState>.broadcast();

  int starts = 0;
  int stops = 0;

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
}
