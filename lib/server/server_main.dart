import "dart:io";
import "dart:ui";

import "package:flutter/widgets.dart";

import "../platform/pigeon/storage_api.g.dart";
import "https_listener.dart";
import "request_router.dart";

/// Entrypoint of the service's HEADLESS Flutter engine
/// (`ServerForegroundService` runs it by name: library
/// `package:vaultbox/server/server_main.dart`, function `serverMain`).
///
/// It runs in its own engine/isolate — separate from the UI — so the server
/// keeps running when the Activity is gone. It asks native for the settings and
/// the TLS identity, starts the HTTPS listener, and reports state through
/// [ServerRuntimeApi]; native pushes that to whichever UI is attached and
/// updates the notification. The engine being destroyed (service stop) ends
/// this isolate, which closes the listener.
///
/// STATUS: compiles; TLS + settings paths never executed on a device yet.
@pragma("vm:entry-point")
Future<void> serverMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final ServerRuntimeApi runtime = ServerRuntimeApi();
  await runtime.reportState(ServerStateMessage(state: ServerRunStateMessage.starting));

  try {
    final ServerConfigMessage config = await runtime.getConfig();
    final TlsIdentityMessage identity = await runtime.getTlsIdentity();
    final bool network = config.allowNetworkAccess ?? false;
    final int port = config.port ?? 8443;

    final HttpsListener listener = HttpsListener(router: RequestRouter());
    await listener.start(
      certificatePem: identity.certificatePem!,
      privateKeyPem: identity.privateKeyPem!,
      allowNetworkAccess: network,
      port: port,
    );

    final String host = network ? (await _lanAddress() ?? "0.0.0.0") : "127.0.0.1";
    await runtime.reportState(
      ServerStateMessage(
        state: ServerRunStateMessage.running,
        endpoint: "https://$host:${listener.port}/",
      ),
    );
  } on SocketException catch (error) {
    await runtime.reportState(
      ServerStateMessage(
        state: ServerRunStateMessage.failed,
        detail: "Couldn't listen: ${error.osError?.message ?? error.message}",
      ),
    );
  } on Object catch (error) {
    await runtime.reportState(
      ServerStateMessage(state: ServerRunStateMessage.failed, detail: "Couldn't start: $error"),
    );
  }
}

/// The phone's private-network IPv4 address (what other devices would type).
Future<String?> _lanAddress() async {
  final List<NetworkInterface> interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  for (final NetworkInterface interface in interfaces) {
    for (final InternetAddress address in interface.addresses) {
      if (isPrivateIPv4(address.address)) return address.address;
    }
  }
  return null;
}

/// RFC 1918 ranges: 10/8, 172.16/12, 192.168/16.
bool isPrivateIPv4(String address) {
  final List<int?> parts = address.split(".").map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((int? p) => p == null)) return false;
  final int a = parts[0]!;
  final int b = parts[1]!;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}
