import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";

import "../../../app/providers.dart";
import "../../../core/design/aurora_components.dart";
import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../core/errors/app_failure.dart";
import "../../../domain/entities/server_config.dart";
import "../../../domain/entities/server_state.dart";
import "../../../domain/repositories/server_host.dart";
import "../../home/home_summary.dart";
import "webdav_guide_sheet.dart";

/// Protocols & Network: which ways in are switched on, on which ports, and who
/// on the network may use them. Settings are read when the server starts, so
/// they lock while it runs (each row says so).
class ProtocolsScreen extends ConsumerWidget {
  const ProtocolsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ServerState server = ref.watch(serverStateProvider).value ?? const ServerState.stopped();
    final ServerConfig? config = ref.watch(serverConfigProvider).value;
    final bool canChange = server.run == ServerRunState.stopped || server.run == ServerRunState.failed;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AuroraSpacing.marginCompact,
          AuroraSpacing.sm,
          AuroraSpacing.marginCompact,
          AuroraSpacing.dockScrollClearance,
        ),
        children: <Widget>[
          const AuroraSubHeader(
            title: "Protocols & Network",
            subtitle: "How other devices connect, and who may.",
          ),
          _ServiceCard(server: server),
          const AuroraSectionHeader(title: "Ways in"),
          if (config == null)
            const Center(child: CircularProgressIndicator())
          else ...<Widget>[
            _WebPortalCard(config: config, server: server, canChange: canChange),
            const SizedBox(height: AuroraSpacing.md),
            _HttpCard(config: config, canChange: canChange),
            const SizedBox(height: AuroraSpacing.md),
            _WebDavCard(config: config, server: server),
            const AuroraSectionHeader(title: "Network"),
            _NetworkCard(config: config, canChange: canChange),
          ],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ service

class _ServiceCard extends ConsumerWidget {
  const _ServiceCard({required this.server});

  final ServerState server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool running = server.run == ServerRunState.running;
    final bool busy = server.run == ServerRunState.starting;
    final String? lan = lanHostPort(server);

    return AuroraCard(
      child: Row(
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.mdAll),
            child: Icon(Icons.dns_outlined, color: context.scheme.primary),
          ),
          const SizedBox(width: AuroraSpacing.sm + 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text("Server service", style: context.brand(20)),
                Text(
                  switch (server.run) {
                    ServerRunState.running => lan == null ? "Running · this phone only" : "Running · $lan",
                    ServerRunState.starting => "Starting…",
                    ServerRunState.failed => "Couldn't start",
                    ServerRunState.stopped => "Off",
                  },
                  style: context.mono(size: 11),
                ),
              ],
            ),
          ),
          Switch(
            value: running || busy,
            onChanged: busy
                ? null
                : (bool on) async {
                    try {
                      final ServerHost host = ref.read(serverHostProvider);
                      if (on) {
                        await host.start();
                      } else {
                        await host.stop();
                      }
                    } on AppFailure catch (failure) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure.message)));
                    }
                  },
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------- web portal

class _WebPortalCard extends ConsumerWidget {
  const _WebPortalCard({required this.config, required this.server, required this.canChange});

  final ServerConfig config;
  final ServerState server;
  final bool canChange;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _ProtocolCard(
      icon: Icons.language,
      title: "Web Portal",
      tag: "HTTPS",
      description: "The browser page for your files. Encrypted with a certificate VaultBox made itself.",
      enabled: config.httpsEnabled,
      onToggle: canChange ? (bool on) => unawaited(_save(context, ref, config.copyWith(httpsEnabled: on))) : null,
      lockedNote: canChange ? null : "Stop the server to change this.",
      port: config.port,
      onChangePort: canChange ? () => unawaited(_changePort(context, ref, config, https: true)) : null,
      status: server.isRunning && config.httpsEnabled ? "Listening" : (config.httpsEnabled ? "Ready" : "Off"),
      footer: TextButton.icon(
        onPressed: () => context.go("/settings/security"),
        icon: const Icon(Icons.verified_user_outlined, size: 16),
        label: const Text("Certificate and security"),
      ),
    );
  }
}

class _HttpCard extends ConsumerWidget {
  const _HttpCard({required this.config, required this.canChange});

  final ServerConfig config;
  final bool canChange;

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool on) async {
    if (on) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text("Turn on unencrypted HTTP?"),
          content: const Text(
            "With HTTP, your password and your files travel across the network in plain text. Anyone on the "
            "same Wi-Fi who is listening can read them. Only use it on a network you fully trust, and keep "
            "HTTPS on for everything else. HTTP only accepts devices on private networks.",
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text("Cancel")),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text("Turn on HTTP")),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    await _save(context, ref, config.copyWith(httpEnabled: on));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _ProtocolCard(
      icon: Icons.no_encryption_outlined,
      title: "Plain HTTP",
      tag: "HTTP",
      description: "Opens in any browser without a certificate warning, but is not encrypted. Trusted networks only.",
      enabled: config.httpEnabled,
      onToggle: canChange ? (bool on) => unawaited(_toggle(context, ref, on)) : null,
      lockedNote: canChange ? null : "Stop the server to change this.",
      port: config.httpPort,
      onChangePort: canChange ? () => unawaited(_changePort(context, ref, config, https: false)) : null,
      status: config.httpEnabled ? "Insecure · unencrypted" : "Off",
      warn: config.httpEnabled,
    );
  }
}

// ------------------------------------------------------------------ WebDAV

class _WebDavCard extends ConsumerWidget {
  const _WebDavCard({required this.config, required this.server});

  final ServerConfig config;
  final ServerState server;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? base = primaryAddress(server);
    final String shown = base == null
        ? "${config.httpsEnabled ? "https" : "http"}://<phone address>:${config.httpsEnabled ? config.port : config.httpPort}/dav/"
        : "$base/dav/";

    return AuroraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.mdAll),
                child: Icon(Icons.folder_shared_outlined, color: context.scheme.primary),
              ),
              const SizedBox(width: AuroraSpacing.sm + 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text("WebDAV storage", style: context.brand(20)),
                    Text("Finder, Explorer and file apps can mount your files.", style: context.caption),
                  ],
                ),
              ),
              _Tag("WEBDAV", context.scheme.primary),
            ],
          ),
          const SizedBox(height: AuroraSpacing.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.standardAll),
            child: Row(
              children: <Widget>[
                Expanded(child: SelectableText(shown, style: context.mono(size: 12, color: context.inkPrimary))),
                IconButton(
                  tooltip: "Copy WebDAV address",
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: base == null
                      ? null
                      : () async {
                          await Clipboard.setData(ClipboardData(text: shown));
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("WebDAV address copied")));
                        },
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "It runs on the same connection as the web portal and is on whenever the server is. "
            "Sign in with an account; each person sees only the folders they were given.",
            style: context.caption,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => unawaited(showWebDavGuide(context, address: shown)),
              icon: const Icon(Icons.menu_book_outlined, size: 16),
              label: const Text("Setup guide for phones and computers"),
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- network

class _NetworkCard extends ConsumerWidget {
  const _NetworkCard({required this.config, required this.canChange});

  final ServerConfig config;
  final bool canChange;

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool enable) async {
    if (enable) {
      final bool adminExists = await ref.read(adminExistsProvider.future);
      if (!context.mounted) return;
      if (!adminExists) {
        final bool? create = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            title: const Text("Create an admin account first"),
            content: const Text(
              "Other devices need a login to use VaultBox. Create the admin account, then turn network access on.",
            ),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text("Not now")),
              FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text("Create account")),
            ],
          ),
        );
        if (create == true && context.mounted) unawaited(context.push("/admin/new"));
        return;
      }
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text("Allow network access?"),
          content: const Text(
            "Other devices on your Wi-Fi will be able to reach this phone's VaultBox server. Traffic is "
            "encrypted, but only turn this on for networks you trust.",
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text("Cancel")),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text("Allow")),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    await _save(context, ref, config.copyWith(allowNetworkAccess: enable));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AuroraRowGroup(
      children: <Widget>[
        AuroraSwitchRow(
          icon: Icons.wifi_tethering,
          title: "Allow other devices on my network",
          subtitle: canChange
              ? (config.allowNetworkAccess
                    ? "On: devices on your Wi-Fi can reach the server."
                    : "Off: only this phone can reach the server.")
              : "Stop the server to change this.",
          value: config.allowNetworkAccess,
          onChanged: canChange ? (bool on) => unawaited(_toggle(context, ref, on)) : null,
        ),
        const AuroraSettingRow(
          icon: Icons.public_off_outlined,
          title: "Never on the internet",
          subtitle: "VaultBox only listens on your local network. It never opens a port on your router.",
        ),
      ],
    );
  }
}

// -------------------------------------------------------------- shared bits

Future<void> _save(BuildContext context, WidgetRef ref, ServerConfig next) async {
  if (!next.httpsEnabled && !next.httpEnabled) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Keep at least one of HTTPS and HTTP on.")),
    );
    return;
  }
  try {
    await ref.read(serverHostProvider).saveConfig(next);
    ref.invalidate(serverConfigProvider);
  } on AppFailure catch (failure) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure.message)));
  }
}

/// Asks for a new port and saves it. Ports below 1024 are reserved on Android,
/// and the two listeners can't share one.
Future<void> _changePort(BuildContext context, WidgetRef ref, ServerConfig config, {required bool https}) async {
  final TextEditingController controller = TextEditingController(text: "${https ? config.port : config.httpPort}");
  final int? chosen = await showDialog<int>(
    context: context,
    builder: (BuildContext dialogContext) {
      String? problem;
      return StatefulBuilder(
        builder: (BuildContext context, void Function(void Function()) setState) => AlertDialog(
          title: Text(https ? "HTTPS port" : "HTTP port"),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(labelText: "Port (1024–65535)", errorText: problem),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text("Cancel")),
            FilledButton(
              onPressed: () {
                final int? value = int.tryParse(controller.text.trim());
                final int other = https ? config.httpPort : config.port;
                if (value == null || value < 1024 || value > 65535) {
                  setState(() => problem = "Use a number from 1024 to 65535.");
                } else if (value == other) {
                  setState(() => problem = "That port is used by the other connection.");
                } else {
                  Navigator.of(dialogContext).pop(value);
                }
              },
              child: const Text("Save"),
            ),
          ],
        ),
      );
    },
  );
  // The dialog's exit animation still uses the controller, so it is left for the garbage collector.
  if (chosen == null || !context.mounted) return;
  await _save(context, ref, https ? config.copyWith(port: chosen) : config.copyWith(httpPort: chosen));
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.pillAll),
      child: Text(label, style: context.mono(size: 10, color: color, weight: FontWeight.w700).copyWith(letterSpacing: 0.6)),
    );
  }
}

/// A protocol with an on/off switch, its port and its current state.
class _ProtocolCard extends StatelessWidget {
  const _ProtocolCard({
    required this.icon,
    required this.title,
    required this.tag,
    required this.description,
    required this.enabled,
    required this.onToggle,
    required this.port,
    required this.onChangePort,
    required this.status,
    this.lockedNote,
    this.footer,
    this.warn = false,
  });

  final IconData icon;
  final String title;
  final String tag;
  final String description;
  final bool enabled;
  final ValueChanged<bool>? onToggle;
  final String? lockedNote;
  final int port;
  final VoidCallback? onChangePort;
  final String status;
  final Widget? footer;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final Color statusColor = warn ? context.statusWarning : (enabled ? context.statusSuccess : context.inkTertiary);
    return AuroraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.mdAll),
                child: Icon(icon, color: warn ? context.statusWarning : context.scheme.primary),
              ),
              const SizedBox(width: AuroraSpacing.sm + 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(child: Text(title, style: context.brand(20), overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 6),
                        _Tag(tag, warn ? context.statusWarning : context.scheme.primary),
                      ],
                    ),
                    Text(description, style: context.caption),
                  ],
                ),
              ),
              Switch(value: enabled, onChanged: onToggle),
            ],
          ),
          const SizedBox(height: AuroraSpacing.sm),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.standardAll),
            child: Row(
              children: <Widget>[
                Text("PORT", style: context.mono(size: 10, color: context.inkTertiary).copyWith(letterSpacing: 0.6)),
                const SizedBox(width: AuroraSpacing.sm),
                Text("$port", style: context.mono(size: 14, color: context.inkPrimary, weight: FontWeight.w700)),
                const Spacer(),
                if (onChangePort != null)
                  InkWell(
                    onTap: onChangePort,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text("Change", style: AuroraTypography.labelLg.copyWith(color: context.scheme.secondary)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: statusColor)),
              const SizedBox(width: 6),
              Text(status, style: context.mono(size: 11, color: statusColor)),
              if (lockedNote != null) ...<Widget>[
                const SizedBox(width: AuroraSpacing.sm),
                Expanded(child: Text(lockedNote!, style: context.caption, textAlign: TextAlign.end)),
              ],
            ],
          ),
          if (footer != null) footer!,
        ],
      ),
    );
  }
}
