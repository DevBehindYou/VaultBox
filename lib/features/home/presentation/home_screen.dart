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
import "../../../domain/entities/server_state.dart";
import "../../../domain/entities/storage_root.dart";
import "../../../domain/repositories/server_host.dart";

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
        "Start VaultBox's background service. For now it only runs a health "
            "check on this phone itself; sharing files over the network "
            "(HTTPS, WebDAV) arrives in Phase 3.",
      ServerRunState.starting => "Starting the background service…",
      ServerRunState.running =>
        "The background service is running. It answers on this phone only — "
            "nothing is exposed to your network yet.",
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
          if (server.isRunning && server.endpoint != null) ...<Widget>[
            const SizedBox(height: AuroraSpacing.sm),
            SelectableText(
              server.endpoint!,
              style: AuroraTypography.tabularFigures(AuroraTypography.labelMonoMd),
            ),
          ],
          if (server.run == ServerRunState.failed && server.detail != null) ...<Widget>[
            const SizedBox(height: AuroraSpacing.sm),
            AuroraInlineBanner(
              message: "The service reported an error.",
              status: AuroraStatus.danger,
              technicalDetail: server.detail,
            ),
          ],
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
