import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";
import "package:go_router/go_router.dart";

import "../../../app/app_state.dart";
import "../../../app/providers.dart";
import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_components.dart";
import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../core/errors/app_failure.dart";
import "../../../core/utils/byte_format.dart";
import "../../../core/state/resource.dart";
import "../../../domain/entities/storage_root.dart";
import "../../../domain/repositories/storage_root_repository.dart";
import "../../../domain/usecases/test_storage_access.dart";
import "../../../platform/adapters/volume_stats_source.dart";
import "../../storage/storage_location.dart";

/// Storage & Volumes: every folder VaultBox serves, where it really is (which
/// volume, which path), how full it is, and what you can do with it.
class StorageScreen extends StatelessWidget {
  const StorageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final Resource<List<StorageRoot>> roots = context.watch<StorageRootsCubit>().state;
    final Map<String, VolumeStats> stats = context.watch<RootStatsCubit>().state.value ?? const <String, VolumeStats>{};

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
            title: "Storage & Volumes",
            subtitle: "The folders VaultBox serves, and where they really are on this phone.",
          ),
          ...roots.when(
            loading: () => const <Widget>[Center(child: CircularProgressIndicator())],
            error: (Object error, StackTrace trace) => <Widget>[
              AuroraInlineBanner(
                message: "Couldn't read your storage locations.",
                status: AuroraStatus.danger,
                technicalDetail: error.toString(),
              ),
            ],
            data: (List<StorageRoot> list) => <Widget>[
              if (list.isEmpty)
                AuroraEmptyState(
                  icon: Icons.folder_open,
                  title: "Nothing is being served yet",
                  message: "Choose a folder on your phone or a memory card. Only what you choose is ever shared.",
                  action: AuroraPrimaryButton(
                    label: "Add storage location",
                    icon: Icons.create_new_folder_outlined,
                    expand: false,
                    onPressed: () => unawaited(context.push("/onboarding/welcome")),
                  ),
                )
              else ...<Widget>[
                _AggregateCard(roots: list, stats: stats),
                AuroraSectionHeader(
                  title: "Served locations",
                  trailing: Text("${list.length} configured", style: context.mono(size: 11)),
                ),
                for (int i = 0; i < list.length; i++) ...<Widget>[
                  _RootCard(root: list[i], stats: stats[list[i].id], canRemove: true),
                  const SizedBox(height: AuroraSpacing.md),
                ],
                AuroraCard(
                  child: Column(
                    children: <Widget>[
                      Icon(Icons.add_circle_outline, color: context.scheme.primary, size: 32),
                      const SizedBox(height: AuroraSpacing.xs),
                      Text("Add another location", style: context.brand(20)),
                      const SizedBox(height: 2),
                      Text(
                        "A folder in internal storage, on a memory card or on a USB drive.",
                        style: context.bodySecondary,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AuroraSpacing.md),
                      AuroraPrimaryButton(
                        label: "Add storage location",
                        icon: Icons.create_new_folder_outlined,
                        onPressed: () => unawaited(context.push("/onboarding/welcome")),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

const List<Color> _sliceColors = <Color>[
  AuroraColors.auroraLavender,
  AuroraColors.auroraPink,
  AuroraColors.auroraMid,
  AuroraColors.auroraSoftLavender,
];

/// All measured locations together: one number and one bar.
class _AggregateCard extends StatelessWidget {
  const _AggregateCard({required this.roots, required this.stats});

  final List<StorageRoot> roots;
  final Map<String, VolumeStats> stats;

  @override
  Widget build(BuildContext context) {
    final List<StorageRoot> measured = roots.where((StorageRoot r) => stats[r.id] != null).toList();
    if (measured.isEmpty) {
      return AuroraCard(
        child: Row(
          children: <Widget>[
            Icon(Icons.info_outline, color: context.inkSecondary),
            const SizedBox(width: AuroraSpacing.sm),
            Expanded(
              child: Text(
                "How much space is left couldn't be read for these locations.",
                style: context.bodySecondary,
              ),
            ),
          ],
        ),
      );
    }

    final int total = measured.fold<int>(0, (int sum, StorageRoot r) => sum + stats[r.id]!.totalBytes);
    final int free = measured.fold<int>(0, (int sum, StorageRoot r) => sum + stats[r.id]!.freeBytes);

    return AuroraCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text("TOTAL CAPACITY", style: context.mono(size: 10, color: context.inkTertiary).copyWith(letterSpacing: 0.6)),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(ByteFormat.format(free), style: context.brand(34)),
              const SizedBox(width: 6),
              Text("free of ${ByteFormat.format(total)}", style: context.bodySecondary),
            ],
          ),
          const SizedBox(height: AuroraSpacing.sm),
          AuroraStorageMeter(
            format: ByteFormat.format,
            segments: <MeterSegment>[
              for (int i = 0; i < measured.length; i++)
                MeterSegment(
                  label: measured[i].displayName,
                  bytes: stats[measured[i].id]!.usedBytes,
                  color: _sliceColors[i % _sliceColors.length],
                ),
              MeterSegment(label: "Free", bytes: free, color: context.statusSuccessBorder),
            ],
          ),
        ],
      ),
    );
  }
}

class _RootCard extends StatefulWidget {
  const _RootCard({required this.root, required this.stats, required this.canRemove});

  final StorageRoot root;
  final VolumeStats? stats;
  final bool canRemove;

  @override
  State<_RootCard> createState() => _RootCardState();
}

class _RootCardState extends State<_RootCard> {
  bool _testing = false;
  StorageTestResult? _result;

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    final StorageTestResult result = await context.read<TestStorageAccess>().call(widget.root);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = result;
    });
    context.read<RootStatsCubit>().refresh();
  }

  Future<void> _makeDefault() async {
    try {
      await context.read<StorageRootRepository>().setDefault(widget.root.id);
    } on AppFailure catch (failure) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }

  Future<void> _remove() async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text("Stop serving “${widget.root.displayName}”?"),
        content: const Text(
          "VaultBox forgets this location and no one can reach it through the server any more. "
          "Your files are not deleted, and you can add the folder again later.",
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text("Keep")),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text("Stop serving")),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await context.read<StorageRootRepository>().removeRoot(widget.root.id);
      context.read<BackendRegistry>().evict(widget.root.id);
      context.read<RootStatsCubit>().refresh();
    } on AppFailure catch (failure) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final StorageRoot root = widget.root;
    final VolumeStats? stats = widget.stats;
    final StorageLocationInfo place = describeStorageRoot(root);
    final StorageTestResult? result = _result;

    final IconData icon = switch (place.kind) {
      VolumeKind.internal => Icons.smartphone,
      VolumeKind.removable => Icons.sd_card_outlined,
      VolumeKind.appPrivate => Icons.folder_special_outlined,
      VolumeKind.memory => Icons.memory,
    };

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
                child: Icon(icon, color: context.scheme.primary),
              ),
              const SizedBox(width: AuroraSpacing.sm + 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(root.displayName, style: context.brand(20), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(place.volumeLabel, style: context.caption),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  if (root.isDefault) _Tag(label: "DEFAULT", color: context.scheme.primary),
                  const SizedBox(height: 4),
                  root.isAvailable
                      ? _Tag(label: "ONLINE", color: context.statusSuccess)
                      : _Tag(label: "OFFLINE", color: context.statusWarning),
                ],
              ),
            ],
          ),
          const SizedBox(height: AuroraSpacing.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: context.panelColor, borderRadius: AuroraRadii.standardAll),
            child: Row(
              children: <Widget>[
                Icon(Icons.folder_outlined, size: 16, color: context.inkTertiary),
                const SizedBox(width: 6),
                Expanded(child: SelectableText(place.path, style: context.mono(size: 12, color: context.inkPrimary))),
              ],
            ),
          ),
          const SizedBox(height: AuroraSpacing.sm),
          if (stats != null) ...<Widget>[
            AuroraStorageMeter(
              showLegend: false,
              format: ByteFormat.format,
              segments: <MeterSegment>[
                MeterSegment(label: "Used", bytes: stats.usedBytes, color: AuroraColors.auroraLavender),
                MeterSegment(label: "Free", bytes: stats.freeBytes, color: context.statusSuccessBorder),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Text("${ByteFormat.format(stats.usedBytes)} used", style: context.mono(size: 11)),
                const Spacer(),
                Text("${ByteFormat.format(stats.freeBytes)} free", style: context.mono(size: 11, color: context.statusSuccess)),
              ],
            ),
          ] else
            Text("How full this volume is couldn't be read.", style: context.caption),
          if (!root.capabilities.canWrite) ...<Widget>[
            const SizedBox(height: AuroraSpacing.sm),
            Text("Read-only: people can look and download but not add files.", style: context.caption),
          ],
          if (result != null) ...<Widget>[
            const SizedBox(height: AuroraSpacing.sm),
            AuroraInlineBanner(
              message: result.elapsed == null
                  ? result.message
                  : "${result.message} (${result.elapsed!.inMilliseconds} ms)",
              status: result.ok ? AuroraStatus.live : AuroraStatus.danger,
            ),
          ],
          const SizedBox(height: AuroraSpacing.sm),
          Wrap(
            spacing: AuroraSpacing.sm,
            runSpacing: AuroraSpacing.xs,
            children: <Widget>[
              _ActionPill(
                icon: Icons.speed_outlined,
                label: _testing ? "Testing…" : "Test read/write",
                onPressed: _testing ? null : () => unawaited(_test()),
              ),
              if (!root.isDefault)
                _ActionPill(icon: Icons.check_circle_outline, label: "Make default", onPressed: () => unawaited(_makeDefault())),
              if (widget.canRemove)
                _ActionPill(
                  icon: Icons.link_off,
                  label: "Stop serving",
                  danger: true,
                  onPressed: () => unawaited(_remove()),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color});

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

class _ActionPill extends StatelessWidget {
  const _ActionPill({required this.icon, required this.label, required this.onPressed, this.danger = false});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color color = danger ? context.statusDanger : context.inkPrimary;
    return Opacity(
      opacity: onPressed == null ? 0.5 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AuroraRadii.pillAll,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: danger ? context.statusDangerSurface : context.panelColor,
              borderRadius: AuroraRadii.pillAll,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 6),
                Text(label, style: AuroraTypography.labelLg.copyWith(color: color, fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
