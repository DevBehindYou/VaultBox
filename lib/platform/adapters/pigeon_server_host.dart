import "dart:async";

import "package:flutter/services.dart" show PlatformException;

import "../../core/errors/app_failure.dart";
import "../../domain/entities/server_state.dart";
import "../../domain/repositories/server_host.dart";
import "../pigeon/storage_api.g.dart";

/// [ServerHost] over the Pigeon server-control contract (UI engine side).
///
/// It both CALLS native (`start`/`stop`/`getState`) and is CALLED by native
/// ([onStateChanged] — the service pushes every state change). Set [listen] to
/// false in tests, which drive [onStateChanged] directly instead of registering
/// a platform handler.
///
/// STATUS: compiles and is unit-tested against fakes; never talked to the real
/// service on a device.
final class PigeonServerHost implements ServerHost, ServerStateListener {
  PigeonServerHost({ServerControlApi? api, bool listen = true})
    : _api = api ?? ServerControlApi() {
    if (listen) ServerStateListener.setUp(this);
  }

  final ServerControlApi _api;
  // App-lifetime singleton: lives until the process ends, so it is never closed.
  // ignore: close_sinks
  final StreamController<ServerState> _changes = StreamController<ServerState>.broadcast();

  @override
  void onStateChanged(ServerStateMessage state) => _changes.add(_toState(state));

  @override
  Stream<ServerState> watch() {
    late final StreamController<ServerState> out;
    StreamSubscription<ServerState>? subscription;

    out = StreamController<ServerState>(
      onListen: () async {
        // Subscribe BEFORE reading the snapshot, and drop the snapshot if a push
        // already arrived meanwhile: the push is newer than what we asked for.
        bool pushed = false;
        subscription = _changes.stream.listen((ServerState state) {
          pushed = true;
          out.add(state);
        });
        try {
          final ServerState snapshot = _toState(await _guard(_api.getState));
          if (!pushed && !out.isClosed) out.add(snapshot);
        } on Object catch (error, trace) {
          if (!out.isClosed) out.addError(error, trace);
        }
      },
      onCancel: () async => subscription?.cancel(),
    );
    return out.stream;
  }

  @override
  Future<void> start() => _guard(_api.start);

  @override
  Future<void> stop() => _guard(_api.stop);

  ServerState _toState(ServerStateMessage message) {
    return ServerState(
      run: switch (message.state) {
        ServerRunStateMessage.starting => ServerRunState.starting,
        ServerRunStateMessage.running => ServerRunState.running,
        ServerRunStateMessage.failed => ServerRunState.failed,
        ServerRunStateMessage.stopped || null => ServerRunState.stopped,
      },
      endpoint: message.endpoint,
      detail: message.detail,
    );
  }

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (error) {
      throw UnexpectedFailure(debugDetail: "${error.code}: ${error.message}");
    }
  }
}
