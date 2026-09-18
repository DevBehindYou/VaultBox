import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../app/providers.dart";
import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../core/utils/byte_format.dart";
import "../../../domain/entities/recycle_item.dart";
import "../../../domain/entities/storage_root.dart";
import "../../../domain/models/operation_batch.dart";

/// Recycle Bin — a `/files` sub-view per the consolidation decision in
/// docs/IMPLEMENTATION_PLAN.md §D ("filtered view of the same screen, not a
/// separate visual design"), reached as a contextual push from
/// [FilesScreen] rather than its own nav destination or go_router route.
///
/// Restore and permanent delete (doc §27: explicit confirmation required)
/// are both wired. What's still missing: a background purge sweep for items
/// past their [RecycleItem.purgeAfter] deadline — everything currently
/// waits for a person to act.
class RecycleBinScreen extends ConsumerWidget {
  const RecycleBinScreen({required this.root, super.key});

  final StorageRoot root;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<RecycleItem>> items = ref.watch(recycleItemsProvider(root.id));

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
                  const Icon(
                    Icons.delete_outline,
                    size: 40,
                    color: AuroraColors.inkTertiary,
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

class _RecycleItemCard extends ConsumerWidget {
  const _RecycleItemCard({required this.item});

  final RecycleItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AuroraCard(
      child: Row(
        children: <Widget>[
          const Icon(Icons.insert_drive_file_outlined, color: AuroraColors.inkTertiary),
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
                  style: AuroraTypography.bodySm.copyWith(color: AuroraColors.inkSecondary),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _restore(context, ref),
            child: const Text("Restore"),
          ),
          IconButton(
            icon: const Icon(Icons.delete_forever_outlined),
            tooltip: "Delete forever",
            color: AuroraColors.statusDanger,
            onPressed: () => _confirmPermanentDelete(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _restore(BuildContext context, WidgetRef ref) async {
    final OperationBatch batch = await ref
        .read(restoreItemsProvider)
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
  Future<void> _confirmPermanentDelete(BuildContext context, WidgetRef ref) async {
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
            style: FilledButton.styleFrom(backgroundColor: AuroraColors.statusDanger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text("Delete forever"),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final OperationBatch batch = await ref
        .read(permanentlyDeleteRecycledProvider)
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
