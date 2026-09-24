import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:go_router/go_router.dart";

import "../../../app/app_state.dart";
import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_components.dart";
import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../core/errors/app_failure.dart";
import "../../../core/state/resource.dart";
import "../../../core/utils/byte_format.dart";
import "../../../domain/entities/account.dart";
import "../../../domain/entities/activity.dart";
import "../../../domain/entities/server_config.dart";
import "../../../domain/entities/server_state.dart";
import "../../../domain/entities/share.dart";
import "../../../domain/entities/storage_root.dart";
import "../../../domain/repositories/clock.dart";
import "../../../domain/repositories/server_host.dart";
import "../../../platform/adapters/url_opener.dart";
import "../../../platform/adapters/volume_stats_source.dart";
import "../../activity/activity_format.dart";
import "../home_summary.dart";
import "qr_sheet.dart";

/// Home: is the server up, where do I connect, how full is the storage, who is
/// here and what is moving. Everything on it is a real reading; nothing is
/// there to fill space.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AuroraSpacing.marginCompact,
          AuroraSpacing.sm,
          AuroraSpacing.marginCompact,
          AuroraSpacing.dockScrollClearance,
        ),
        children: const <Widget>[
          _AdminCard(),
          _ServerHero(),
          SizedBox(height: AuroraSpacing.md),
          _ProtocolRow(),
          SizedBox(height: AuroraSpacing.md),
          _StorageCard(),
          SizedBox(height: AuroraSpacing.md),
          _MetricGrid(),
          SizedBox(height: AuroraSpacing.md),
          _LiveActivityCard(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- hero card

class _ServerHero extends StatelessWidget {
  const _ServerHero();

  Future<void> _run(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } on AppFailure catch (failure) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ServerState server = context.watch<ServerStateCubit>().state.value ?? const ServerState.stopped();
    final ServerHost host = context.read<ServerHost>();
    final List<ActivityEvent> events = context.watch<ActivityEventsCubit>().state.value ?? const <ActivityEvent>[];
    final DateTime now = context.read<Clock>().now();
    final Duration? uptime = serverUptime(server, events, now);
    final String? address = primaryAddress(server);
    final String? lan = lanHostPort(server);

    return AuroraCard(
      padding: const EdgeInsets.all(AuroraSpacing.md),
      child: switch (server.run) {
        ServerRunState.running => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                _StatePill(label: "SERVER LIVE", color: context.statusSuccess),
                const Spacer(),
                if (uptime != null) _UptimePill(uptime: uptime),
              ],
            ),
            const SizedBox(height: AuroraSpacing.sm),
            Text("Your phone is serving files.", style: context.brand(26)),
            const SizedBox(height: 2),
            Text(
              lan == null
                  ? "Only this phone can reach it right now. Allow other devices under Protocols & Network."
                  : "Your files, served to your trusted network.",
              style: context.bodySecondary,
            ),
            const SizedBox(height: AuroraSpacing.md),
            if (address != null) _AddressBlock(address: address, canShare: lan != null),
            if (lan != null) ...<Widget>[
              const SizedBox(height: AuroraSpacing.sm),
              _LanRow(hostPort: lan),
            ],
            const SizedBox(height: AuroraSpacing.md),
            Row(
              children: <Widget>[
                Expanded(
                  child: _PillButton(
                    label: "Stop Server",
                    icon: Icons.power_settings_new,
                    foreground: context.statusDanger,
                    background: context.statusDangerSurface,
                    onPressed: () => unawaited(_run(context, host.stop)),
                  ),
                ),
                const SizedBox(width: AuroraSpacing.sm),
                Expanded(
                  child: AuroraPrimaryButton(
                    label: "Open Portal",
                    icon: Icons.open_in_browser,
                    onPressed: address == null ? null : () => unawaited(context.read<UrlOpener>().open("$address/")),
                  ),
                ),
              ],
            ),
          ],
        ),
        ServerRunState.starting => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _StatePill(label: "STARTING", color: context.statusWarning),
            const SizedBox(height: AuroraSpacing.sm),
            Text("Starting the server…", style: context.brand(26)),
            const SizedBox(height: 2),
            Text("Setting up the encrypted connection. This takes a moment.", style: context.bodySecondary),
            const SizedBox(height: AuroraSpacing.md),
            const LinearProgressIndicator(),
          ],
        ),
        ServerRunState.failed => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _StatePill(label: "SERVER ERROR", color: context.statusDanger),
            const SizedBox(height: AuroraSpacing.sm),
            Text("The server couldn't start.", style: context.brand(26)),
            const SizedBox(height: AuroraSpacing.sm),
            AuroraInlineBanner(
              message: "Something went wrong starting the background service.",
              status: AuroraStatus.danger,
              technicalDetail: server.detail,
            ),
            const SizedBox(height: AuroraSpacing.md),
            AuroraPrimaryButton(
              label: "Try again",
              icon: Icons.refresh,
              onPressed: () => unawaited(_run(context, host.start)),
            ),
          ],
        ),
        ServerRunState.stopped => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _StatePill(label: "STANDBY", color: context.inkTertiary),
            const SizedBox(height: AuroraSpacing.sm),
            Text("Your phone. Your files. Your server.", style: context.brand(26)),
            const SizedBox(height: 2),
            Text(
              "Your files stay on this phone and travel encrypted. Start the server whenever you want "
              "a laptop, a tablet or another phone to connect. Nothing is reachable until you do.",
              style: context.bodySecondary,
            ),
            const SizedBox(height: AuroraSpacing.md),
            AuroraPrimaryButton(
              label: "Start server",
              icon: Icons.bolt,
              onPressed: () => unawaited(_run(context, host.start)),
            ),
            const SizedBox(height: AuroraSpacing.sm),
            _PillButton(
              label: "Protocol options",
              icon: Icons.tune,
              foreground: context.inkPrimary,
              background: context.panelColor,
              onPressed: () => context.go("/settings/protocols"),
            ),
          ],
        ),
      },
    );
  }
}

class _StatePill extends StatelessWidget {
  const _StatePill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.pillAll),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 6),
          Text(label, style: context.mono(size: 11, color: color, weight: FontWeight.w600).copyWith(letterSpacing: 0.8)),
        ],
      ),
    );
  }
}

class _UptimePill extends StatelessWidget {
  const _UptimePill({required this.uptime});

  final Duration uptime;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: "Running for ${uptime.inHours} hours ${uptime.inMinutes.remainder(60)} minutes",
      child: ExcludeSemantics(
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.pillAll),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.schedule, size: 14, color: context.inkSecondary),
              const SizedBox(width: 4),
              Text("UP ${formatUptime(uptime)}", style: context.mono(size: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The address to open, with copy and QR buttons.
class _AddressBlock extends StatelessWidget {
  const _AddressBlock({required this.address, required this.canShare});

  final String address;

  /// Whether other devices can reach it (the QR code is only useful then).
  final bool canShare;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.mdAll),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text("PRIMARY ADDRESS", style: context.mono(size: 10, color: context.inkTertiary).copyWith(letterSpacing: 0.6)),
                const SizedBox(height: 2),
                SelectableText(address, style: context.mono(size: 14, color: context.inkPrimary, weight: FontWeight.w600)),
              ],
            ),
          ),
          _RoundIconButton(
            icon: Icons.content_copy,
            label: "Copy address",
            onPressed: () => unawaited(_copy(context, address, "Address copied")),
          ),
          if (canShare) ...<Widget>[
            const SizedBox(width: 4),
            _RoundIconButton(
              icon: Icons.qr_code_2,
              label: "Show QR code",
              onPressed: () => unawaited(showServerQrSheet(context, address)),
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> _copy(BuildContext context, String text, String confirmation) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(confirmation)));
}

class _LanRow extends StatelessWidget {
  const _LanRow({required this.hostPort});

  final String hostPort;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(Icons.lan_outlined, size: 16, color: context.inkTertiary),
        const SizedBox(width: 6),
        Text("LAN IP:", style: context.mono()),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            hostPort,
            style: context.mono(color: context.inkPrimary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const Spacer(),
        InkWell(
          onTap: () => unawaited(_copy(context, hostPort, "IP address copied")),
          borderRadius: AuroraRadii.pillAll,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(color: context.pillColor, borderRadius: AuroraRadii.pillAll),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.copy_all, size: 14, color: context.inkSecondary),
                const SizedBox(width: 4),
                Text("Copy IP", style: context.mono()),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: label,
      onPressed: onPressed,
      style: IconButton.styleFrom(backgroundColor: context.cardColor, minimumSize: const Size(40, 40)),
      icon: Icon(icon, size: 18, color: context.inkPrimary),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.icon,
    required this.foreground,
    required this.background,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color foreground;
  final Color background;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: AuroraRadii.pillAll,
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: AuroraSpacing.minTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(color: background, borderRadius: AuroraRadii.pillAll),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 18, color: foreground),
              const SizedBox(width: AuroraSpacing.sm),
              Flexible(
                child: Text(
                  label,
                  style: AuroraTypography.labelLg.copyWith(color: foreground, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ admin account

/// Shown until an admin account exists: without one nobody can sign in.
class _AdminCard extends StatelessWidget {
  const _AdminCard();

  @override
  Widget build(BuildContext context) {
    final bool? exists = context.watch<AdminExistsCubit>().state.value;
    if (exists != false) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AuroraSpacing.md),
      child: AuroraCard(
        borderColor: context.statusWarningBorder,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.person_add_alt, color: context.statusWarning),
                const SizedBox(width: AuroraSpacing.sm),
                Expanded(child: Text("No admin account yet", style: context.brand(22))),
              ],
            ),
            const SizedBox(height: AuroraSpacing.xs),
            Text("Create the login other devices will use to open your files.", style: context.bodySecondary),
            const SizedBox(height: AuroraSpacing.md),
            AuroraPrimaryButton(
              label: "Create admin account",
              icon: Icons.person_add_alt,
              onPressed: () => unawaited(context.push("/admin/new")),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ protocol chips

class _ProtocolRow extends StatelessWidget {
  const _ProtocolRow();

  @override
  Widget build(BuildContext context) {
    final ServerState server = context.watch<ServerStateCubit>().state.value ?? const ServerState.stopped();
    final ServerConfig? config = context.watch<ServerConfigCubit>().state.value;
    final List<ProtocolStatus> statuses = protocolStatuses(server, config, ftp: context.watch<FtpSettingsCubit>().state.value);

    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: statuses.length,
        separatorBuilder: (BuildContext context, int index) => const SizedBox(width: AuroraSpacing.sm),
        itemBuilder: (BuildContext context, int index) => Center(
          child: AuroraProtocolChip(
            label: statuses[index].label,
            detail: statuses[index].port,
            active: statuses[index].active,
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ storage

class _StorageCard extends StatelessWidget {
  const _StorageCard();

  @override
  Widget build(BuildContext context) {
    final Resource<List<StorageRoot>> roots = context.watch<StorageRootsCubit>().state;
    final Map<String, VolumeStats> stats = context.watch<RootStatsCubit>().state.value ?? const <String, VolumeStats>{};

    return roots.when(
      loading: () => const AuroraCard(child: Center(child: CircularProgressIndicator())),
      error: (Object error, StackTrace stack) => AuroraInlineBanner(
        message: "Couldn't read your storage locations.",
        status: AuroraStatus.danger,
        technicalDetail: error.toString(),
      ),
      data: (List<StorageRoot> list) {
        if (list.isEmpty) {
          return AuroraEmptyState(
            icon: Icons.folder_open,
            title: "No storage yet",
            message: "Pick a folder for Atomic Carton to manage and serve.",
            action: AuroraPrimaryButton(
              label: "Set up storage",
              icon: Icons.arrow_forward,
              expand: false,
              onPressed: () => unawaited(context.push("/onboarding/welcome")),
            ),
          );
        }

        final List<VolumeStats> measured = <VolumeStats>[
          for (final StorageRoot root in list)
            if (stats[root.id] != null) stats[root.id]!,
        ];
        final int total = measured.fold<int>(0, (int sum, VolumeStats s) => sum + s.totalBytes);
        final int free = measured.fold<int>(0, (int sum, VolumeStats s) => sum + s.freeBytes);
        final int used = total > free ? total - free : 0;

        return AuroraCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.pie_chart_outline, color: context.scheme.primary),
                  const SizedBox(width: AuroraSpacing.sm),
                  Expanded(child: Text("Storage Capacity", style: context.brand(22))),
                  InkWell(
                    onTap: () => context.go("/settings/storage"),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text("Manage →", style: context.mono(color: context.scheme.secondary)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AuroraSpacing.sm),
              if (measured.isNotEmpty) ...<Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: <Widget>[
                    Text(
                      ByteFormat.format(used),
                      style: AuroraTypography.headlineSm.copyWith(color: context.inkPrimary, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: 6),
                    Text("used of ${ByteFormat.format(total)}", style: context.bodySecondary),
                    const Spacer(),
                    Text("${ByteFormat.format(free)} free", style: context.mono(color: context.statusSuccess)),
                  ],
                ),
                const SizedBox(height: AuroraSpacing.sm),
                AuroraStorageMeter(
                  format: ByteFormat.format,
                  segments: <MeterSegment>[
                    MeterSegment(label: "Used", bytes: used, color: AuroraColors.auroraLavender),
                    MeterSegment(label: "Free", bytes: free, color: context.statusSuccessBorder),
                  ],
                ),
                const SizedBox(height: AuroraSpacing.sm),
              ],
              for (final StorageRoot root in list) _RootLine(root: root, stats: stats[root.id]),
            ],
          ),
        );
      },
    );
  }
}

class _RootLine extends StatelessWidget {
  const _RootLine({required this.root, required this.stats});

  final StorageRoot root;
  final VolumeStats? stats;

  @override
  Widget build(BuildContext context) {
    final VolumeStats? measured = stats;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Icon(root.isRemovable ? Icons.sd_card_outlined : Icons.folder_outlined, size: 18, color: context.inkSecondary),
          const SizedBox(width: AuroraSpacing.sm),
          Expanded(
            child: Text(root.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.body),
          ),
          if (!root.isAvailable)
            const AuroraStatusChip(label: "Offline", status: AuroraStatus.warning)
          else if (measured != null)
            Text("${ByteFormat.format(measured.freeBytes)} free", style: context.mono()),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ metrics

class _MetricGrid extends StatelessWidget {
  const _MetricGrid();

  @override
  Widget build(BuildContext context) {
    final DateTime now = context.read<Clock>().now();
    final List<ClientRecord> clients = context.watch<ActivityClientsCubit>().state.value ?? const <ClientRecord>[];
    final List<TransferRecord> transfers = context.watch<ActivityTransfersCubit>().state.value ?? const <TransferRecord>[];
    final List<Share> shares = context.watch<SharesCubit>().state.value ?? const <Share>[];
    final List<Account> accounts = context.watch<AccountsCubit>().state.value ?? const <Account>[];

    final List<ClientRecord> online = clients
        .where((ClientRecord c) => now.difference(c.lastSeenAt) < clientActiveWithin)
        .toList();
    final int moving = transfers.where((TransferRecord t) => t.isRunning && !isStalled(t, now)).length;
    final int activeLinks = shares.where((Share s) => s.isActive(now)).length;
    final int admins = accounts.where((Account a) => a.isAdmin).length;

    return Column(
      children: <Widget>[
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: AuroraMetricCard(
                  title: "Clients",
                  icon: Icons.devices_outlined,
                  value: online.isEmpty ? "None online" : "${online.length} Online",
                  caption: online.isEmpty ? "Nobody connected" : online.map((ClientRecord c) => c.actor).toSet().take(3).join(", "),
                  onTap: () => context.go("/activity"),
                ),
              ),
              const SizedBox(width: AuroraSpacing.sm),
              Expanded(
                child: AuroraMetricCard(
                  title: "Transfers",
                  icon: Icons.swap_vert,
                  value: moving == 0 ? "Idle" : "$moving moving",
                  caption: moving == 0 ? "Nothing in progress" : "Files in or out now",
                  onTap: () => context.go("/activity"),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AuroraSpacing.sm),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: AuroraMetricCard(
                  title: "Links",
                  icon: Icons.link,
                  value: "$activeLinks active",
                  caption: shares.length == activeLinks ? "Shared with people" : "${shares.length - activeLinks} finished",
                  onTap: () => context.go("/share"),
                ),
              ),
              const SizedBox(width: AuroraSpacing.sm),
              Expanded(
                child: AuroraMetricCard(
                  title: "People",
                  icon: Icons.group_outlined,
                  value: "${accounts.length} ${accounts.length == 1 ? "account" : "accounts"}",
                  caption: accounts.isEmpty ? "No one can sign in" : "$admins admin, ${accounts.length - admins} member",
                  onTap: () => context.go("/share"),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------ live activity

class _LiveActivityCard extends StatelessWidget {
  const _LiveActivityCard();

  @override
  Widget build(BuildContext context) {
    final DateTime now = context.read<Clock>().now();
    final List<TransferRecord> transfers = context.watch<ActivityTransfersCubit>().state.value ?? const <TransferRecord>[];
    final List<ActivityEvent> events = context.watch<ActivityEventsCubit>().state.value ?? const <ActivityEvent>[];
    final List<TransferRecord> running = transfers.where((TransferRecord t) => t.isRunning && !isStalled(t, now)).take(3).toList();
    final List<ActivityEvent> recent = events.take(3).toList();

    return AuroraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.swap_vert, color: context.scheme.tertiary),
              const SizedBox(width: AuroraSpacing.sm),
              Expanded(child: Text("Live Activity", style: context.brand(22))),
              InkWell(
                onTap: () => context.go("/activity"),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text("Activity View →", style: context.mono(color: context.scheme.secondary)),
                ),
              ),
            ],
          ),
          const SizedBox(height: AuroraSpacing.sm),
          if (running.isEmpty && recent.isEmpty)
            Text("Nothing has happened yet. Transfers and sign-ins will show up here.", style: context.bodySecondary)
          else ...<Widget>[
            for (final TransferRecord transfer in running) _LiveTransfer(transfer: transfer),
            if (running.isEmpty)
              for (final ActivityEvent event in recent)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        event.severity == ActivitySeverity.info ? Icons.info_outline : Icons.warning_amber_outlined,
                        size: 18,
                        color: event.severity == ActivitySeverity.info ? context.inkSecondary : context.statusWarning,
                      ),
                      const SizedBox(width: AuroraSpacing.sm),
                      Expanded(child: Text(event.message, style: context.body)),
                      const SizedBox(width: AuroraSpacing.sm),
                      Text(describeAgo(event.at, now), style: context.caption),
                    ],
                  ),
                ),
          ],
        ],
      ),
    );
  }
}

class _LiveTransfer extends StatelessWidget {
  const _LiveTransfer({required this.transfer});

  final TransferRecord transfer;

  @override
  Widget build(BuildContext context) {
    final double? fraction = transfer.fraction;
    final bool sending = transfer.direction == TransferDirection.download;
    return Container(
      margin: const EdgeInsets.only(bottom: AuroraSpacing.sm),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.mdAll),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  transfer.name,
                  style: context.body.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (fraction != null) Text("${(fraction * 100).round()}%", style: context.mono(color: context.scheme.primary)),
            ],
          ),
          Text("${sending ? "To" : "From"} ${transfer.actor}", style: context.mono(size: 11)),
          if (fraction != null) ...<Widget>[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: AuroraRadii.pillAll,
              child: LinearProgressIndicator(value: fraction, minHeight: 6),
            ),
          ],
          const SizedBox(height: 4),
          Text(describeTransferSize(transfer), style: context.mono(size: 11)),
        ],
      ),
    );
  }
}
