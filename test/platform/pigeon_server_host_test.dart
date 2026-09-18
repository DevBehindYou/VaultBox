import "dart:async";

import "package:flutter/services.dart" show PlatformException;
import "package:flutter_test/flutter_test.dart";
import "package:vaultbox/core/errors/app_failure.dart";
import "package:vaultbox/domain/entities/server_state.dart";
import "package:vaultbox/platform/adapters/pigeon_server_host.dart";
import "package:vaultbox/platform/pigeon/storage_api.g.dart";

final class FakeControlApi extends ServerControlApi {
  ServerStateMessage snapshot = ServerStateMessage(state: ServerRunStateMessage.stopped);
  int starts = 0;
  int stops = 0;
  PlatformException? failWith;

  /// When set, getState() waits on it (simulates a slow native read).
  Completer<void>? gate;

  void _maybeFail() {
    final PlatformException? failure = failWith;
    if (failure != null) throw failure;
  }

  @override
  Future<void> start() async {
    _maybeFail();
    starts++;
  }

  @override
  Future<void> stop() async {
    _maybeFail();
    stops++;
  }

  @override
  Future<ServerStateMessage> getState() async {
    _maybeFail();
    await gate?.future;
    return snapshot;
  }
}

void main() {
  late FakeControlApi api;
  late PigeonServerHost host;

  setUp(() {
    api = FakeControlApi();
    host = PigeonServerHost(api: api, listen: false);
  });

  test("first emission is the native snapshot", () async {
    api.snapshot = ServerStateMessage(
      state: ServerRunStateMessage.running,
      endpoint: "http://127.0.0.1:1/health/",
    );

    final ServerState first = await host.watch().first;
    expect(first.run, ServerRunState.running);
    expect(first.endpoint, "http://127.0.0.1:1/health/");
  });

  test("pushed changes follow the snapshot, mapped", () async {
    final List<ServerState> seen = <ServerState>[];
    final StreamSubscription<ServerState> sub = host.watch().listen(seen.add);
    await pumpEventQueue();

    host.onStateChanged(ServerStateMessage(state: ServerRunStateMessage.starting));
    host.onStateChanged(
      ServerStateMessage(state: ServerRunStateMessage.failed, detail: "port busy"),
    );
    await pumpEventQueue();
    await sub.cancel();

    expect(seen.map((ServerState s) => s.run), <ServerRunState>[
      ServerRunState.stopped,
      ServerRunState.starting,
      ServerRunState.failed,
    ]);
    expect(seen.last.detail, "port busy");
  });

  test("a push that lands before a slow snapshot wins (snapshot is dropped)", () async {
    api.gate = Completer<void>();
    final List<ServerState> seen = <ServerState>[];
    final StreamSubscription<ServerState> sub = host.watch().listen(seen.add);
    await pumpEventQueue();

    host.onStateChanged(ServerStateMessage(state: ServerRunStateMessage.running));
    api.gate!.complete(); // the older "stopped" snapshot now arrives
    await pumpEventQueue();
    await sub.cancel();

    expect(seen.map((ServerState s) => s.run), <ServerRunState>[ServerRunState.running]);
  });

  test("a missing state maps to stopped", () async {
    api.snapshot = ServerStateMessage();
    expect((await host.watch().first).run, ServerRunState.stopped);
  });

  test("start and stop call native", () async {
    await host.start();
    await host.stop();
    expect(api.starts, 1);
    expect(api.stops, 1);
  });

  test("a native error becomes UnexpectedFailure with the detail", () async {
    api.failWith = PlatformException(code: "boom", message: "service refused");
    await expectLater(
      host.start(),
      throwsA(
        isA<UnexpectedFailure>().having(
          (UnexpectedFailure f) => f.debugDetail,
          "debugDetail",
          contains("boom"),
        ),
      ),
    );
  });
}
