import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";

import "../../../app/providers.dart";
import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../core/errors/app_failure.dart";
import "../../../core/utils/byte_format.dart";
import "../../../domain/entities/server_config.dart";
import "../../../domain/entities/server_state.dart";
import "../../../domain/entities/storage_root.dart";
import "../../../domain/repositories/server_host.dart";
import "../../share/share_links.dart";
import "qr_sheet.dart";

/// Home. Deliberately thinner than its mockup.
///
/// `home_server_live` shows six stat cards (storage, clients, throughput,
/// queues, node temperature, live activity). Doc §69 says Home must answer
/// exactly six questions — is it running, where do I connect, how much space
/// is free, is anyone connected, is anything transferring, is there a
/// problem — and kickoff §6 explicitly forbids turning it into a 20-widget
/// monitoring dashboard. Throughput and device temperature answer none of
/// those six, so they live in Server Details / Diagnostics instead.
///
/// Server state is real as of Phase 2 (Foreground Service + headless Dart
/// runtime), but the server itself is still a loopback-only health listener:
/// this screen says so plainly instead of implying network serving.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<StorageRoot>> roots = ref.watch(storageRootsProvider);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AuroraSpacing.marginCompact,
            AuroraSpacing.marginCompact,
            AuroraSpacing.marginCompact,
            AuroraSpacing.dockScrollClearance,
          ),
          children: <Widget>[
            Row(
              children: <Widget>[
                Text("VaultBox", style: AuroraTypography.headlineLg),
                const Spacer(),
                const _ServerStatusChip(),
              ],
            ),
            const SizedBox(height: AuroraSpacing.md),
            const _ServerCard(),
            const _AdminCard(),
            const SizedBox(height: AuroraSpacing.md),
            roots.when(
              loading: () => const AuroraCard(
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (Object error, StackTrace stack) => AuroraInlineBanner(
                message: "Couldn't read your storage locations.",
                status: AuroraStatus.danger,
                technicalDetail: error.toString(),
              ),
              data: (List<StorageRoot> list) => _StorageCard(
                roots: list,
                onAddStorage: () => context.push("/onboarding/welcome"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerStatusChip extends ConsumerWidget {
  const _ServerStatusChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ServerState server =
        ref.watch(serverStateProvider).value ?? const ServerState.stopped();
    return switch (server.run) {
      ServerRunState.stopped => const AuroraStatusChip(label: "Server off", status: AuroraStatus.idle),
      ServerRunState.starting => const AuroraStatusChip(label: "Starting…", status: AuroraStatus.idle),
      ServerRunState.running => const AuroraStatusChip(label: "Server on", status: AuroraStatus.live),
      ServerRunState.failed => const AuroraStatusChip(label: "Failed", status: AuroraStatus.danger),
    };
  }
}

class _ServerCard extends ConsumerWidget {
  const _ServerCard();

  static List<String> _urls(ServerState server) => server.endpoints.isNotEmpty
      ? server.endpoints
      : <String>[if (server.endpoint != null) server.endpoint!];

  static String _reachableCopy(ServerState server) {
    final List<String> urls = _urls(server);
    final bool https = urls.any((String u) => u.startsWith("https://"));
    final bool http = urls.any((String u) => u.startsWith("http://"));
    final StringBuffer text = StringBuffer(
      "The background service is running and reachable from devices on your local network",
    );
    if (https && http) {
      text.write(" over HTTPS (encrypted) and HTTP (not encrypted).");
    } else if (http) {
      text.write(" over HTTP, which is not encrypted.");
    } else {
      text.write(" over HTTPS.");
    }
    if (https) {
      text.write(" HTTPS uses a self-signed certificate: compare the fingerprint below before trusting it.");
    }
    return text.toString();
  }

  /// True when the server only listens on this phone (loopback endpoint).
  static bool _isLocalOnly(String? endpoint) {
    final String? host = endpoint == null ? null : Uri.tryParse(endpoint)?.host;
    return host == null || host == "127.0.0.1" || host == "localhost";
  }

  Future<void> _run(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } on AppFailure catch (failure) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ServerState server =
        ref.watch(serverStateProvider).value ?? const ServerState.stopped();
    final ServerHost host = ref.read(serverHostProvider);

    final String headline = switch (server.run) {
      ServerRunState.stopped => "Your phone isn't serving.",
      ServerRunState.starting => "Starting the server…",
      ServerRunState.running => "The server is running.",
      ServerRunState.failed => "The server couldn't start.",
    };
    final String explanation = switch (server.run) {
      ServerRunState.stopped =>
        "Start VaultBox's background service to open your files from a browser or "
            "a WebDAV app on your network. Nothing is reachable until you start it.",
      ServerRunState.starting => "Starting the background service…",
      ServerRunState.running => _isLocalOnly(server.endpoint)
          ? "The background service is running. It answers on this phone only — "
                "nothing is exposed to your network."
          : _reachableCopy(server),
      ServerRunState.failed => "Something went wrong starting the background service.",
    };

    return AuroraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(headline, style: AuroraTypography.headlineMd),
          const SizedBox(height: AuroraSpacing.sm),
          Text(
            explanation,
            style: AuroraTypography.bodyMd.copyWith(color: AuroraColors.inkSecondary),
          ),
          if (server.isRunning)
            for (final String url in _urls(server)) ...<Widget>[
              const SizedBox(height: AuroraSpacing.sm),
              SelectableText(
                url,
                style: AuroraTypography.tabularFigures(AuroraTypography.labelMonoMd),
              ),
              if (url.startsWith("http://") && !_isLocalOnly(url))
                Text(
                  "Not encrypted — use only on a network you trust.",
                  style: AuroraTypography.bodySm.copyWith(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? AuroraColorsDark.statusWarning
                        : AuroraColors.statusWarning,
                  ),
                ),
            ],
          if (shareLinkBase(server) != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => unawaited(showServerQrSheet(context, shareLinkBase(server)!)),
                icon: const Icon(Icons.qr_code_2),
                label: const Text("Show QR code"),
              ),
            ),
          const _FingerprintRow(),
          if (server.run == ServerRunState.failed && server.detail != null) ...<Widget>[
            const SizedBox(height: AuroraSpacing.sm),
            AuroraInlineBanner(
              message: "The service reported an error.",
              status: AuroraStatus.danger,
              technicalDetail: server.detail,
            ),
          ],
          const _NetworkAccessSwitch(),
          const _ProtocolSwitches(),
          const SizedBox(height: AuroraSpacing.md),
          switch (server.run) {
            ServerRunState.running => OutlinedButton.icon(
              onPressed: () => unawaited(_run(context, host.stop)),
              icon: const Icon(Icons.stop),
              label: const Text("Stop server"),
            ),
            ServerRunState.starting => const AuroraPrimaryButton(
              label: "Starting…",
              onPressed: null,
              expand: false,
            ),
            ServerRunState.stopped || ServerRunState.failed => AuroraPrimaryButton(
              label: server.run == ServerRunState.failed ? "Try again" : "Start server",
              icon: Icons.play_arrow,
              expand: false,
              onPressed: () => unawaited(_run(context, host.start)),
            ),
          },
        ],
      ),
    );
  }
}

/// Off by default. Turning it on exposes the server to the local network, so it
/// asks first, and it can only change while the server is stopped (settings are
/// read once, at start).
class _NetworkAccessSwitch extends ConsumerWidget {
  const _NetworkAccessSwitch();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ServerState server =
        ref.watch(serverStateProvider).value ?? const ServerState.stopped();
    final ServerConfig? config = ref.watch(serverConfigProvider).value;
    if (config == null) return const SizedBox.shrink();
    final bool canChange =
        server.run == ServerRunState.stopped || server.run == ServerRunState.failed;

    // SwitchListTile paints on the nearest Material; the card's coloured
    // DecoratedBox would hide that (and trips a debug assertion) — own Material.
    return Material(
      type: MaterialType.transparency,
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text("Allow other devices on my network"),
        subtitle: Text(
          canChange
              ? "Off: only this phone can reach the server."
              : "Stop the server to change this.",
        ),
        value: config.allowNetworkAccess,
        onChanged: canChange
            ? (bool enable) => unawaited(_change(context, ref, config, enable))
            : null,
      ),
    );
  }

  Future<void> _change(
    BuildContext context,
    WidgetRef ref,
    ServerConfig config,
    bool enable,
  ) async {
    if (enable) {
      final bool adminExists = await ref.read(adminExistsProvider.future);
      if (!context.mounted) return;
      if (!adminExists) {
        // Nothing to log in with yet: exposing the server would only expose a login page.
        final bool? create = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            title: const Text("Create an admin account first"),
            content: const Text(
              "Other devices need a login to use VaultBox. Create the admin "
              "account, then turn network access on.",
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text("Not now"),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text("Create account"),
              ),
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
            "Other devices on your Wi-Fi will be able to reach this phone's "
            "VaultBox server. Traffic is encrypted, but only turn this on for "
            "networks you trust.",
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text("Cancel"),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text("Allow"),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    try {
      await ref.read(serverHostProvider).saveConfig(config.copyWith(allowNetworkAccess: enable));
      ref.invalidate(serverConfigProvider);
    } on AppFailure catch (failure) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }
}

/// Which protocols the server speaks. HTTPS (encrypted) is on by default; plain
/// HTTP is an explicit, warned opt-in for people who accept the risk on a
/// network they trust (e.g. to skip the self-signed certificate warning). At
/// least one must stay on, and both lock while the server runs.
class _ProtocolSwitches extends ConsumerWidget {
  const _ProtocolSwitches();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ServerState server =
        ref.watch(serverStateProvider).value ?? const ServerState.stopped();
    final ServerConfig? config = ref.watch(serverConfigProvider).value;
    if (config == null) return const SizedBox.shrink();
    final bool canChange =
        server.run == ServerRunState.stopped || server.run == ServerRunState.failed;

    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: <Widget>[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text("HTTPS (encrypted)"),
            subtitle: const Text("Recommended. Uses a self-signed certificate."),
            value: config.httpsEnabled,
            onChanged: canChange
                ? (bool on) => unawaited(_set(context, ref, config.copyWith(httpsEnabled: on)))
                : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text("HTTP (not encrypted)"),
            subtitle: Text(
              canChange
                  ? "Opens in any browser without a certificate warning, but "
                        "passwords and files can be read by others on your Wi-Fi."
                  : "Stop the server to change this.",
            ),
            value: config.httpEnabled,
            onChanged: canChange
                ? (bool on) => unawaited(_toggleHttp(context, ref, config, on))
                : null,
          ),
        ],
      ),
    );
  }

  Future<void> _toggleHttp(
    BuildContext context,
    WidgetRef ref,
    ServerConfig config,
    bool on,
  ) async {
    if (on) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text("Turn on unencrypted HTTP?"),
          content: const Text(
            "With HTTP, your password and your files travel across the network "
            "in plain text. Anyone on the same Wi-Fi who is listening can read "
            "them. Only use it on a network you fully trust, and keep HTTPS on "
            "for everything else. HTTP only accepts devices on private networks.",
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text("Cancel"),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text("Turn on HTTP"),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    await _set(context, ref, config.copyWith(httpEnabled: on));
  }

  Future<void> _set(BuildContext context, WidgetRef ref, ServerConfig next) async {
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
}

/// The certificate fingerprint a person compares with their browser's warning
/// before trusting the self-signed certificate.
class _FingerprintRow extends ConsumerWidget {
  const _FingerprintRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? fingerprint = ref.watch(tlsFingerprintProvider).value;
    if (fingerprint == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AuroraSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            "Certificate fingerprint (SHA-256)",
            style: AuroraTypography.bodySm.copyWith(color: AuroraColors.inkSecondary),
          ),
          SelectableText(fingerprint, style: AuroraTypography.labelMonoSm),
        ],
      ),
    );
  }
}

/// Shown until an admin account exists.
class _AdminCard extends ConsumerWidget {
  const _AdminCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool? exists = ref.watch(adminExistsProvider).value;
    if (exists != false) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AuroraSpacing.md),
      child: AuroraCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text("No admin account yet", style: AuroraTypography.headlineSm),
            const SizedBox(height: AuroraSpacing.xs),
            Text(
              "Create the login other devices will use.",
              style: AuroraTypography.bodyMd.copyWith(color: AuroraColors.inkSecondary),
            ),
            const SizedBox(height: AuroraSpacing.md),
            AuroraPrimaryButton(
              label: "Create admin account",
              icon: Icons.person_add_alt,
              expand: false,
              onPressed: () => unawaited(context.push("/admin/new")),
            ),
          ],
        ),
      ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.roots, required this.onAddStorage});

  final List<StorageRoot> roots;
  final VoidCallback onAddStorage;

  @override
  Widget build(BuildContext context) {
    if (roots.isEmpty) {
      return AuroraCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text("No storage chosen yet", style: AuroraTypography.headlineSm),
            const SizedBox(height: AuroraSpacing.xs),
            Text(
              "Pick a folder for VaultBox to manage and serve.",
              style: AuroraTypography.bodyMd.copyWith(color: AuroraColors.inkSecondary),
            ),
            const SizedBox(height: AuroraSpacing.md),
            AuroraPrimaryButton(
              label: "Set up storage",
              icon: Icons.arrow_forward,
              expand: false,
              onPressed: onAddStorage,
            ),
          ],
        ),
      );
    }

    return AuroraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text("Storage", style: AuroraTypography.headlineSm),
          const SizedBox(height: AuroraSpacing.sm),
          for (final StorageRoot root in roots) _RootLine(root: root),
        ],
      ),
    );
  }
}

class _RootLine extends StatelessWidget {
  const _RootLine({required this.root});

  final StorageRoot root;

  @override
  Widget build(BuildContext context) {
    final int? free = root.freeBytes;
    final int? total = root.totalBytes;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AuroraSpacing.xs),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              root.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AuroraTypography.bodyLg,
            ),
          ),
          if (!root.isAvailable)
            const AuroraStatusChip(label: "Offline", status: AuroraStatus.warning)
          else if (free != null && total != null)
            Text(
              "${ByteFormat.format(free)} free of ${ByteFormat.format(total)}",
              style: AuroraTypography.tabularFigures(
                AuroraTypography.labelMonoMd,
              ).copyWith(color: AuroraColors.inkSecondary),
            ),
        ],
      ),
    );
  }
}
