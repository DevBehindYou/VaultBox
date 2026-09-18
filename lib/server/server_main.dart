import "dart:io";
import "dart:ui";

import "package:flutter/widgets.dart";

import "../platform/pigeon/storage_api.g.dart";
import "http_listener.dart";
import "https_listener.dart";
import "network_addresses.dart";
import "request_router.dart";

/// Entrypoint of the service's HEADLESS Flutter engine
/// (`ServerForegroundService` runs it by name: library
/// `package:vaultbox/server/server_main.dart`, function `serverMain`).
///
/// It runs in its own engine/isolate — separate from the UI — so the server
/// keeps running when the Activity is gone. It asks native for the settings and
/// the TLS identity, starts the enabled listeners (HTTPS and/or plain HTTP), and
/// reports state through [ServerRuntimeApi]; native pushes that to whichever UI
/// is attached and updates the notification. The engine being destroyed
/// (service stop) ends this isolate, which closes the listeners.
///
/// STATUS: HTTPS verified on a device; the HTTP listener is new.
@pragma("vm:entry-point")
Future<void> serverMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final ServerRuntimeApi runtime = ServerRuntimeApi();
  await runtime.reportState(ServerStateMessage(state: ServerRunStateMessage.starting));

  HttpsListener? https;
  HttpListener? http;
  try {
    final ServerConfigMessage config = await runtime.getConfig();
    final bool network = config.allowNetworkAccess ?? false;
    final String host = network ? (await lanAddress() ?? "0.0.0.0") : "127.0.0.1";
    final List<String> endpoints = <String>[];

    if (config.httpsEnabled ?? true) {
      final TlsIdentityMessage identity = await runtime.getTlsIdentity();
      https = HttpsListener(router: const RequestRouter());
      await https.start(
        certificatePem: identity.certificatePem!,
        privateKeyPem: identity.privateKeyPem!,
        allowNetworkAccess: network,
        port: config.port ?? 8443,
      );
      endpoints.add("https://$host:${https.port}/");
    }

    if (config.httpEnabled ?? false) {
      // Unencrypted, opt-in, and private-network clients only.
      http = HttpListener(router: const RequestRouter(secure: false, privateClientsOnly: true));
      await http.start(allowNetworkAccess: network, port: config.httpPort ?? 8080);
      endpoints.add("http://$host:${http.port}/");
    }

    await runtime.reportState(
      ServerStateMessage(
        state: ServerRunStateMessage.running,
        endpoint: endpoints.isEmpty ? null : endpoints.first,
        endpoints: endpoints,
      ),
    );
  } on Object catch (error) {
    // A partial start is a failed start: don't leave one listener up.
    await https?.stop();
    await http?.stop();
    await runtime.reportState(
      ServerStateMessage(
        state: ServerRunStateMessage.failed,
        detail: error is SocketException
            ? "Couldn't listen: ${error.osError?.message ?? error.message}"
            : "Couldn't start: $error",
      ),
    );
  }
}
