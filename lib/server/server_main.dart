import "dart:ui";

import "package:flutter/widgets.dart";

import "../platform/pigeon/storage_api.g.dart";
import "loopback_health_server.dart";

/// Entrypoint of the service's HEADLESS Flutter engine
/// (`ServerForegroundService` runs it by name: library
/// `package:vaultbox/server/server_main.dart`, function `serverMain`).
///
/// It runs in its own engine/isolate — separate from the UI — so the server
/// keeps running when the Activity is gone. It reports state to native through
/// [ServerRuntimeApi]; native pushes that to whichever UI is attached and
/// updates the notification. The engine being destroyed (service stop) ends
/// this isolate, which closes the listener.
///
/// STATUS: compiles; never executed on a device.
@pragma("vm:entry-point")
Future<void> serverMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final ServerRuntimeApi runtime = ServerRuntimeApi();
  await runtime.reportState(ServerStateMessage(state: ServerRunStateMessage.starting));

  final LoopbackHealthServer server = LoopbackHealthServer();
  try {
    final Uri endpoint = await server.start();
    await runtime.reportState(
      ServerStateMessage(state: ServerRunStateMessage.running, endpoint: endpoint.toString()),
    );
  } on Object catch (error) {
    await runtime.reportState(
      ServerStateMessage(
        state: ServerRunStateMessage.failed,
        detail: "Couldn't open the local listener: $error",
      ),
    );
  }
}
