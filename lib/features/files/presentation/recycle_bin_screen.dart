import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";

import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../core/state/resource.dart";
import "../../../core/state/resource_cubit.dart";
import "../../../core/utils/byte_format.dart";
import "../../../domain/entities/recycle_item.dart";
import "../../../domain/entities/storage_root.dart";
import "../../../domain/models/operation_batch.dart";
import "../../../domain/repositories/recycle_bin_repository.dart";
import "../../../domain/usecases/permanently_delete_recycled.dart";
import "../../../domain/usecases/restore_items.dart";

/// Recycle Bin — a `/files` sub-view per the consolidation decision in
/// docs/IMPLEMENTATION_PLAN.md §D ("filtered view of the same screen, not a
/// separate visual design"), reached as a contextual push from
/// [FilesScreen] rather than its own nav destination or go_router route.
///
/// Restore and permanent delete (doc §27: explicit confirmation required)
/// are both wired. What's still missing: a background purge sweep for items
/// past their [RecycleItem.purgeAfter] deadline — everything currently
/// waits for a person to act.
/// Screen-scoped — Home never watches recycle-bin items, so unlike almost
/// every other Cubit in this app this really is created-per-visit and
/// disposed-on-pop, mirroring the old `recycleItemsProvider`
/// (`StreamProvider.autoDispose.family<List<RecycleItem>, String>`).
class RecycleItemsCubit extends ResourceStreamCubit<List<RecycleItem>> {
  RecycleItemsCubit(RecycleBinRepository repository, String rootId)
    : super(repository.watchItems(rootId));
}

class RecycleBinScreen extends StatelessWidget {
  const RecycleBinScreen({required this.root, super.key});

  final StorageRoot root;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<RecycleItemsCubit>(
      create: (BuildContext context) =>
          RecycleItemsCubit(context.read<RecycleBinRepository>(), root.id),
      child: _RecycleBinScaffold(root: root),
    );
  }
}

class _RecycleBinScaffold extends StatelessWidget {
  const _RecycleBinScaffold({required this.root});

  final StorageRoot root;

  @override
  Widget build(BuildContext context) {
    final Resource<List<RecycleItem>> items = context.watch<RecycleItemsCubit>().state;

    return Scaffold(
      appBar: AppBar(title: const Text("Recycle Bin")),
      body: items.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
            child: AuroraInlineBanner(
              message: "Couldn't load the Recycle Bin.",
              status: AuroraStatus.danger,
              technicalDetail: error.toString(),
            ),
          ),
        ),
        data: (List<RecycleItem> list) {
          if (list.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.delete_outline,
                    size: 40,
                    color: context.inkTertiary,
                  ),
                  const SizedBox(height: AuroraSpacing.md),
                  Text("Recycle Bin is empty", style: AuroraTypography.bodyLg),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
            itemCount: list.length,
            separatorBuilder: (BuildContext context, int index) =>
                const SizedBox(height: AuroraSpacing.sm),
            itemBuilder: (BuildContext context, int index) =>
                _RecycleItemCard(item: list[index]),
          );
        },
      ),
    );
  }
}

class _RecycleItemCard extends StatelessWidget {
  const _RecycleItemCard({required this.item});

  final RecycleItem item;

  @override
  Widget build(BuildContext context) {
    return AuroraCard(
      child: Row(
        children: <Widget>[
          Icon(Icons.insert_drive_file_outlined, color: context.inkTertiary),
          const SizedBox(width: AuroraSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.originalName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AuroraTypography.bodyLg,
                ),
                const SizedBox(height: 2),
                Text(
                  "Deleted ${_relative(item.deletedAt)}"
                  "${item.sizeBytes != null ? ' · ${ByteFormat.format(item.sizeBytes!)}' : ''}",
                  style: AuroraTypography.bodySm.copyWith(color: context.inkSecondary),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _restore(context),
            child: const Text("Restore"),
          ),
          IconButton(
            icon: const Icon(Icons.delete_forever_outlined),
            tooltip: "Delete forever",
            color: context.statusDanger,
            onPressed: () => _confirmPermanentDelete(context),
          ),
        ],
      ),
    );
  }

  Future<void> _restore(BuildContext context) async {
    final OperationBatch batch = await context
        .read<RestoreItems>()
        .call(recycleItemIds: <String>[item.id]);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          batch.completedCount == 1
              ? "Restored to ${item.originalPath.normalized}"
              : batch.summary,
        ),
      ),
    );
  }

  /// Doc §27: "Permanent delete requires explicit confirmation." This is
  /// that confirmation — a dialog naming exactly what's about to happen,
  /// not a generic "are you sure?".
  Future<void> _confirmPermanentDelete(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('Delete "${item.originalName}" forever?'),
        content: const Text(
          "This can't be undone. The file will be permanently removed.",
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text("Cancel"),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.statusDanger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text("Delete forever"),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final OperationBatch batch = await context
        .read<PermanentlyDeleteRecycled>()
        .call(recycleItemIds: <String>[item.id]);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(batch.summary)));
  }

  static String _relative(DateTime moment) {
    final Duration age = DateTime.now().difference(moment);
    if (age.inMinutes < 1) return "just now";
    if (age.inHours < 1) return "${age.inMinutes} min ago";
    if (age.inHours < 24) return "${age.inHours} hr ago";
    return "${age.inDays} d ago";
  }
}
