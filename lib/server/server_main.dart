import "dart:io";
import "dart:ui";

import "package:flutter/widgets.dart";

import "../core/logging/app_logger.dart";
import "../domain/entities/ftp_settings.dart";
import "../platform/pigeon/storage_api.g.dart";
import "api/vault_api.dart";
import "ftp/ftp_server.dart";
import "http_listener.dart";
import "https_listener.dart";
import "network_addresses.dart";
import "portal/portal_assets.dart";
import "request_router.dart";
import "server_services.dart";
import "tls_context.dart";

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
/// STATUS: HTTPS health check verified on a device; HTTP listener and the
/// login/roots/entries API are new and untested on a device.
@pragma("vm:entry-point")
Future<void> serverMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  AppLogger.init();

  final ServerRuntimeApi runtime = ServerRuntimeApi();
  await runtime.reportState(ServerStateMessage(state: ServerRunStateMessage.starting));

  ServerServices? services;
  HttpsListener? https;
  HttpListener? http;
  FtpServer? ftp;
  try {
    final ServerConfigMessage config = await runtime.getConfig();
    final bool network = config.allowNetworkAccess ?? false;
    final String host = network ? (await lanAddress() ?? "0.0.0.0") : "127.0.0.1";
    final List<String> endpoints = <String>[];
    services = await ServerServices.create();
    final VaultApi api = services.api;

    if (config.httpsEnabled ?? true) {
      final TlsIdentityMessage identity = await runtime.getTlsIdentity();
      // Private-network and loopback clients only, like plain HTTP: the
      // listener binds 0.0.0.0, which includes a mobile-data address.
      https = HttpsListener(
        router: RequestRouter(privateClientsOnly: true, api: api, portal: const PortalAssets(), dav: services.dav),
      );
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
      http = HttpListener(
        router: RequestRouter(
          secure: false,
          privateClientsOnly: true,
          api: api,
          portal: const PortalAssets(),
          dav: services.dav,
        ),
      );
      await http.start(allowNetworkAccess: network, port: config.httpPort ?? 8080);
      endpoints.add("http://$host:${http.port}/");
    }

    // FTP / FTPS, if the person switched it on in the app. It rides on the same
    // certificate as HTTPS, so there is one fingerprint to check.
    final FtpSettings ftpSettings = await services.loadFtpSettings();
    if (ftpSettings.enabled) {
      SecurityContext? tls;
      if (ftpSettings.usesTls) {
        final TlsIdentityMessage identity = await runtime.getTlsIdentity();
        tls = buildTlsContext(certificatePem: identity.certificatePem!, privateKeyPem: identity.privateKeyPem!);
      }
      ftp = services.buildFtpServer(ftpSettings, tls: tls);
      await ftp.start(
        address: network ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
        port: ftpSettings.port,
      );
      endpoints.add("${ftpSettings.mode == FtpMode.implicitTls ? "ftps" : "ftp"}://$host:${ftp.port}/");
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
    await ftp?.stop();
    services?.dispose();
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
