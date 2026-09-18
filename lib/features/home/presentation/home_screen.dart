import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:go_router/go_router.dart";

import "../../../app/providers.dart";
import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../core/utils/byte_format.dart";
import "../../../domain/entities/storage_root.dart";

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
/// Server state is Phase 2; until the Foreground Service exists this screen
/// shows the real storage picture and an honest "not running yet" state
/// rather than a mocked-up live server.
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
                const AuroraStatusChip(label: "Server off", status: AuroraStatus.idle),
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

class _ServerCard extends StatelessWidget {
  const _ServerCard();

  @override
  Widget build(BuildContext context) {
    return AuroraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text("Your phone isn't serving yet.", style: AuroraTypography.headlineMd),
          const SizedBox(height: AuroraSpacing.sm),
          Text(
            "The local file manager works now. Network serving over HTTPS and "
            "WebDAV arrives with the Phase 2 background service.",
            style: AuroraTypography.bodyMd.copyWith(color: AuroraColors.inkSecondary),
          ),
          const SizedBox(height: AuroraSpacing.md),
          // No fake Start button: per kickoff §77 a control that looks live but
          // does nothing is worse than none at all.
          const AuroraStatusChip(label: "HTTPS", status: AuroraStatus.idle, detail: "8443"),
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
