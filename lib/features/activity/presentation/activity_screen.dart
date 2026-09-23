import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";

import "../../../app/app_state.dart";
import "../../../core/design/aurora_components.dart";
import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../core/state/resource.dart";
import "../../../domain/entities/activity.dart";
import "../../../domain/repositories/activity_repository.dart";
import "../../../domain/repositories/clock.dart";
import "../activity_format.dart";

/// The Activity tab: files moving in and out, who is connected, and what has
/// happened. The server writes all of it from its own engine; this screen reads
/// it back every few seconds while it is open.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

enum _Section { transfers, clients, events }

class _ActivityScreenState extends State<ActivityScreen> {
  _Section _section = _Section.transfers;

  Future<void> _clear() async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text("Clear the history?"),
        content: const Text(
          "This empties the lists of transfers, clients and events. Your files, "
          "accounts and links are not touched.",
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text("Keep")),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text("Clear")),
        ],
      ),
    );
    if (yes != true) return;
    await context.read<ActivityRepository>().clear();
    unawaited(context.read<ActivityTransfersCubit>().refreshNow());
    unawaited(context.read<ActivityClientsCubit>().refreshNow());
    unawaited(context.read<ActivityEventsCubit>().refreshNow());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(AuroraSpacing.marginCompact, AuroraSpacing.sm, AuroraSpacing.marginCompact, 0),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: SegmentedButton<_Section>(
                      segments: const <ButtonSegment<_Section>>[
                        ButtonSegment<_Section>(value: _Section.transfers, label: Text("Transfers")),
                        ButtonSegment<_Section>(value: _Section.clients, label: Text("Clients")),
                        ButtonSegment<_Section>(value: _Section.events, label: Text("Events")),
                      ],
                      selected: <_Section>{_section},
                      onSelectionChanged: (Set<_Section> chosen) => setState(() => _section = chosen.first),
                    ),
                  ),
                  IconButton(
                    tooltip: "Clear the history",
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: () => unawaited(_clear()),
                  ),
                ],
              ),
              const SizedBox(height: AuroraSpacing.md),
              Expanded(
                child: switch (_section) {
                  _Section.transfers => const _TransfersView(),
                  _Section.clients => const _ClientsView(),
                  _Section.events => const _EventsView(),
                },
              ),
            ],
          ),
      ),
    );
  }
}

/// Loading / error / empty / list, shared by the three lists.
class _ActivityList<T> extends StatelessWidget {
  const _ActivityList({
    required this.value,
    required this.emptyIcon,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.itemBuilder,
  });

  final Resource<List<T>> value;
  final IconData emptyIcon;
  final String emptyTitle;
  final String emptyMessage;
  final Widget Function(BuildContext context, T item) itemBuilder;

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (Object error, StackTrace trace) => const Text("Couldn't load this list."),
      data: (List<T> items) {
        if (items.isEmpty) {
          return SingleChildScrollView(
            child: AuroraEmptyState(icon: emptyIcon, title: emptyTitle, message: emptyMessage),
          );
        }
        return ListView.separated(
          itemCount: items.length,
          separatorBuilder: (BuildContext context, int index) => const SizedBox(height: AuroraSpacing.sm),
          itemBuilder: (BuildContext context, int index) => itemBuilder(context, items[index]),
        );
      },
    );
  }
}

// -------------------------------------------------------------- transfers

class _TransfersView extends StatelessWidget {
  const _TransfersView();

  @override
  Widget build(BuildContext context) {
    final DateTime now = context.read<Clock>().now();
    return _ActivityList<TransferRecord>(
      value: context.watch<ActivityTransfersCubit>().state,
      emptyIcon: Icons.swap_vert,
      emptyTitle: "Nothing has moved yet",
      emptyMessage: "Files sent or received through the web page, a WebDAV app or a link will show up here.",
      itemBuilder: (BuildContext context, TransferRecord transfer) => _TransferCard(transfer: transfer, now: now),
    );
  }
}

class _TransferCard extends StatelessWidget {
  const _TransferCard({required this.transfer, required this.now});

  final TransferRecord transfer;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final bool stalled = isStalled(transfer, now);
    final AuroraStatus status = switch (transfer.state) {
      TransferState.running => stalled ? AuroraStatus.warning : AuroraStatus.live,
      TransferState.completed => AuroraStatus.idle,
      TransferState.failed => AuroraStatus.danger,
      TransferState.interrupted => AuroraStatus.warning,
    };
    final bool sending = transfer.direction == TransferDirection.download;

    return AuroraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(sending ? Icons.north_east : Icons.south_west, size: 20),
              const SizedBox(width: AuroraSpacing.sm),
              Expanded(
                child: Text(
                  transfer.name,
                  style: AuroraTypography.headlineSm,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              AuroraStatusChip(label: describeTransferState(transfer, now), status: status),
            ],
          ),
          const SizedBox(height: AuroraSpacing.xs),
          Text(
            "${sending ? "To" : "From"} ${transfer.actor} · ${describeVia(transfer.via)} · "
            "${describeAgo(transfer.startedAt, now)}",
            style: AuroraTypography.bodySm.copyWith(color: context.inkSecondary),
          ),
          if (transfer.isRunning && !stalled && transfer.fraction != null) ...<Widget>[
            const SizedBox(height: AuroraSpacing.sm),
            LinearProgressIndicator(value: transfer.fraction),
          ],
          const SizedBox(height: AuroraSpacing.xs),
          Text(
            describeTransferSize(transfer),
            style: AuroraTypography.tabularFigures(AuroraTypography.labelMonoMd),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- clients

class _ClientsView extends StatelessWidget {
  const _ClientsView();

  @override
  Widget build(BuildContext context) {
    final DateTime now = context.read<Clock>().now();
    return _ActivityList<ClientRecord>(
      value: context.watch<ActivityClientsCubit>().state,
      emptyIcon: Icons.devices_outlined,
      emptyTitle: "Nobody has connected in the last day.",
      emptyMessage: "People who sign in from a browser or a WebDAV app appear here while they are connected.",
      itemBuilder: (BuildContext context, ClientRecord client) => _ClientCard(client: client, now: now),
    );
  }
}

class _ClientCard extends StatelessWidget {
  const _ClientCard({required this.client, required this.now});

  final ClientRecord client;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final bool active = now.difference(client.lastSeenAt) < clientActiveWithin;
    return AuroraCard(
      child: Row(
        children: <Widget>[
          Icon(switch (client.via) {
            AccessVia.web => Icons.language,
            AccessVia.webdav => Icons.folder_shared_outlined,
            AccessVia.link => Icons.link,
            AccessVia.ftp => Icons.dns_outlined,
          }),
          const SizedBox(width: AuroraSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(client.actor, style: AuroraTypography.headlineSm),
                const SizedBox(height: AuroraSpacing.xs),
                Text(
                  "${describeVia(client.via)} · ${client.address}",
                  style: AuroraTypography.tabularFigures(AuroraTypography.labelMonoMd),
                ),
                const SizedBox(height: AuroraSpacing.xs),
                Text(
                  "Since ${describeAgo(client.firstSeenAt, now)}",
                  style: AuroraTypography.bodySm.copyWith(color: context.inkSecondary),
                ),
              ],
            ),
          ),
          AuroraStatusChip(
            label: active ? "Connected" : describeAgo(client.lastSeenAt, now),
            status: active ? AuroraStatus.live : AuroraStatus.idle,
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- events

class _EventsView extends StatelessWidget {
  const _EventsView();

  @override
  Widget build(BuildContext context) {
    final DateTime now = context.read<Clock>().now();
    return _ActivityList<ActivityEvent>(
      value: context.watch<ActivityEventsCubit>().state,
      emptyIcon: Icons.event_note_outlined,
      emptyTitle: "Nothing has happened yet",
      emptyMessage: "Sign-ins, refused attempts and link use are listed here.",
      itemBuilder: (BuildContext context, ActivityEvent event) => _EventCard(event: event, now: now),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event, required this.now});

  final ActivityEvent event;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color) = switch (event.severity) {
      ActivitySeverity.info => (Icons.info_outline, context.inkSecondary),
      ActivitySeverity.warning => (Icons.warning_amber_outlined, context.statusWarning),
      ActivitySeverity.problem => (Icons.error_outline, context.statusDanger),
    };
    final String when = describeAgo(event.at, now);
    final String? address = event.address;
    return AuroraCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: color, size: 20),
          const SizedBox(width: AuroraSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(event.message, style: AuroraTypography.bodyMd),
                const SizedBox(height: AuroraSpacing.xs),
                Text(
                  address == null ? when : "$when · $address",
                  style: AuroraTypography.bodySm.copyWith(color: context.inkSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
