import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../domain/models/file_ref.dart";
import "../../../domain/models/operation_batch.dart";
import "../../../domain/value_objects/storage_entry.dart";
import "../../../domain/value_objects/write_mode.dart";
import "../viewmodel/files_view_model.dart";
import "destination_picker_screen.dart";
import "recycle_bin_screen.dart";
import "widgets/conflict_dialog.dart";
import "widgets/file_row.dart";

/// The file manager. One screen handles browsing, multi-select, sort/filter
/// and per-item actions; everything else is a contextual sheet or dialog
/// rather than a route (kickoff §5, §52 — the seven "files_*" mockups
/// consolidate here).
class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({required this.directory, super.key});

  final FileRef directory;

  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    // Controllers created by this State are disposed by it — the single most
    // common Flutter leak (KB §9 "Memory").
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final double remaining =
        _scrollController.position.maxScrollExtent - _scrollController.position.pixels;
    // Prefetch a page before hitting the bottom so scrolling never stalls
    // waiting on I/O.
    if (remaining < FileRow.rowHeight * 8) {
      unawaited(ref.read(filesViewModelProvider(widget.directory).notifier).loadMore());
    }
  }

  @override
  Widget build(BuildContext context) {
    final FilesState state = ref.watch(filesViewModelProvider(widget.directory));
    final FilesViewModel viewModel =
        ref.read(filesViewModelProvider(widget.directory).notifier);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _FilesHeader(
              directory: widget.directory,
              state: state,
              onSelectAll: viewModel.selectAll,
              onClearSelection: viewModel.clearSelection,
              onSortTap: () => _showSortSheet(context, viewModel, state),
              onOpenRecycleBin: () => _openRecycleBin(context, viewModel),
            ),
            if (state.failure != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AuroraSpacing.marginCompact,
                  0,
                  AuroraSpacing.marginCompact,
                  AuroraSpacing.sm,
                ),
                child: AuroraInlineBanner(
                  message: state.failure!.message,
                  status: AuroraStatus.danger,
                  technicalDetail: state.failure!.debugDetail,
                  onDismiss: viewModel.dismissFailure,
                  actionLabel: "Retry",
                  onAction: viewModel.loadFirstPage,
                ),
              ),
            Expanded(child: _buildList(state, viewModel)),
          ],
        ),
      ),
      floatingActionButton: state.isSelectionMode
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                FloatingActionButton.small(
                  heroTag: "files-add-files",
                  tooltip: "Add files",
                  onPressed: () => _importFiles(context, viewModel),
                  backgroundColor: AuroraColors.auroraMid,
                  foregroundColor: AuroraColors.inkPrimary,
                  child: const Icon(Icons.upload_file_outlined),
                ),
                const SizedBox(height: AuroraSpacing.sm),
                FloatingActionButton.extended(
                  heroTag: "files-new-folder",
                  onPressed: () => _showCreateFolderDialog(context, viewModel),
                  backgroundColor: AuroraColors.auroraMid,
                  foregroundColor: AuroraColors.inkPrimary,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text("New folder"),
                ),
              ],
            ),
      bottomNavigationBar: state.isSelectionMode
          ? _SelectionActionBar(
              count: state.selectedCount,
              onCopy: () => _copySelected(context, viewModel),
              onMove: () => _moveSelected(context, viewModel),
              onDelete: () => _confirmDelete(context, viewModel),
            )
          : null,
    );
  }

  Widget _buildList(FilesState state, FilesViewModel viewModel) {
    if (state.isLoadingFirstPage) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.entries.isEmpty) {
      return const _EmptyFolder();
    }

    return ListView.builder(
      controller: _scrollController,
      // itemExtent lets the framework skip child measurement entirely —
      // required for large directories to scroll smoothly (see FileRow).
      itemExtent: FileRow.rowHeight,
      padding: const EdgeInsets.only(bottom: AuroraSpacing.dockScrollClearance),
      itemCount: state.entries.length + (state.isLoadingMore ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (index >= state.entries.length) {
          return const Center(
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final StorageEntry entry = state.entries[index];
        return FileRow(
          entry: entry,
          selected: state.isSelected(entry),
          selectionMode: state.isSelectionMode,
          onLongPress: () => viewModel.toggleSelection(entry),
          onTap: () {
            if (state.isSelectionMode) {
              viewModel.toggleSelection(entry);
            } else if (entry.isDirectory) {
              _openDirectory(entry);
            }
          },
        );
      },
    );
  }

  void _openDirectory(StorageEntry entry) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FilesScreen(
          directory: FileRef(root: widget.directory.root, path: entry.path),
        ),
      ),
    );
  }

  /// Unlike [_openDirectory] (a genuinely separate directory — nothing a
  /// child screen does there can change what *this* screen should show), a
  /// restore from the Recycle Bin can land an item right back in this exact
  /// directory. Refresh on return rather than leaving the list stale until
  /// some unrelated action happens to trigger a reload.
  Future<void> _openRecycleBin(BuildContext context, FilesViewModel viewModel) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecycleBinScreen(root: widget.directory.root),
      ),
    );
    if (!context.mounted) return;
    await viewModel.loadFirstPage();
  }

  /// System file picker -> import into this folder. The conflict prompt is
  /// only shown if a picked name already exists here.
  Future<void> _importFiles(BuildContext context, FilesViewModel viewModel) async {
    final OperationBatch? batch = await viewModel.importFiles(
      onConflicts: (List<String> names) async {
        // Called after the picker returned — the screen may be gone by now.
        if (!context.mounted) return null;
        return showConflictResolutionDialog(context, conflictingNames: names);
      },
    );
    if (batch == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(batch.summary)));
  }

  Future<void> _copySelected(BuildContext context, FilesViewModel viewModel) async {
    await _runTransfer(context, viewModel, isMove: false);
  }

  Future<void> _moveSelected(BuildContext context, FilesViewModel viewModel) async {
    await _runTransfer(context, viewModel, isMove: true);
  }

  /// Shared picker → validate → conflict-check → execute flow for both Copy
  /// and Move. Every `await` below is followed by a `context.mounted` guard
  /// before the next context-touching step — this method crosses several
  /// async gaps (a pushed screen, two dialogs, then the operation itself),
  /// and any one of them can outlive the widget (KB vol2 §9.1).
  Future<void> _runTransfer(
    BuildContext context,
    FilesViewModel viewModel, {
    required bool isMove,
  }) async {
    final FileRef? destination =
        await pickDestination(context, initialDirectory: widget.directory);
    if (destination == null || !context.mounted) return;

    final String? destinationError = viewModel.validateDestination(destination);
    if (destinationError != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(destinationError)));
      return;
    }

    final List<String> conflicts = await viewModel.findConflicts(destination);
    if (!context.mounted) return;

    ConflictPolicy policy = ConflictPolicy.keepBoth;
    if (conflicts.isNotEmpty) {
      final ConflictPolicy? chosen = await showConflictResolutionDialog(
        context,
        conflictingNames: conflicts,
      );
      if (chosen == null || !context.mounted) return; // cancelled
      policy = chosen;
    }

    final OperationBatch batch = isMove
        ? await viewModel.moveSelectedTo(destination, policy: policy)
        : await viewModel.copySelectedTo(destination, policy: policy);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(batch.summary)));
  }

  Future<void> _showCreateFolderDialog(
    BuildContext context,
    FilesViewModel viewModel,
  ) async {
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => const _CreateFolderDialog(),
    );
    final String trimmed = (name ?? "").trim();
    if (trimmed.isNotEmpty) {
      await viewModel.createFolder(trimmed);
    }
  }

  Future<void> _showSortSheet(
    BuildContext context,
    FilesViewModel viewModel,
    FilesState state,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final FileSortField field in FileSortField.values)
                ListTile(
                  title: Text(switch (field) {
                    FileSortField.name => "Name",
                    FileSortField.modified => "Date modified",
                    FileSortField.size => "Size",
                    FileSortField.type => "Type",
                  }),
                  trailing: state.sortField == field
                      ? Icon(
                          state.sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                          size: 18,
                        )
                      : null,
                  onTap: () {
                    final bool ascending =
                        state.sortField == field ? !state.sortAscending : true;
                    viewModel.setSort(field, ascending: ascending);
                    Navigator.of(sheetContext).pop();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, FilesViewModel viewModel) async {
    final int count = ref.read(filesViewModelProvider(widget.directory)).selectedCount;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text("Move $count item${count == 1 ? '' : 's'} to Recycle Bin?"),
        content: const Text(
          "You can restore items from the Recycle Bin later.",
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text("Move to Recycle Bin"),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final OperationBatch batch = await viewModel.deleteSelected();
    // BuildContext after an await — guard before touching it (KB vol2 §9.1).
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(batch.summary)),
    );
  }
}

/// Owns its [TextEditingController] so it is disposed only when the dialog
/// route has fully left the tree.
///
/// The previous version created the controller in the caller and disposed it
/// in a `finally` right after `showDialog` returned — but `showDialog`'s
/// future completes as soon as `pop` is called, while the dialog is still
/// animating out and its TextField is still using the controller. That threw
/// "A TextEditingController was used after being disposed" and corrupted the
/// widget tree (found by CI run #4's widget tests).
class _CreateFolderDialog extends StatefulWidget {
  const _CreateFolderDialog();

  @override
  State<_CreateFolderDialog> createState() => _CreateFolderDialogState();
}

class _CreateFolderDialogState extends State<_CreateFolderDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("New folder"),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: "Folder name"),
        onSubmitted: (String value) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Cancel"),
        ),
        TextButton(onPressed: _submit, child: const Text("Create")),
      ],
    );
  }
}

class _FilesHeader extends StatelessWidget {
  const _FilesHeader({
    required this.directory,
    required this.state,
    required this.onSelectAll,
    required this.onClearSelection,
    required this.onSortTap,
    required this.onOpenRecycleBin,
  });

  final FileRef directory;
  final FilesState state;
  final VoidCallback onSelectAll;
  final VoidCallback onClearSelection;
  final VoidCallback onSortTap;
  final VoidCallback onOpenRecycleBin;

  @override
  Widget build(BuildContext context) {
    final String title =
        directory.path.isRoot ? directory.root.displayName : directory.path.name;

    return Padding(
      padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
      child: AuroraCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                if (state.isSelectionMode)
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: "Clear selection",
                    onPressed: onClearSelection,
                  )
                else if (Navigator.of(context).canPop())
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: "Back",
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                Expanded(
                  child: Text(
                    state.isSelectionMode ? "${state.selectedCount} selected" : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AuroraTypography.headlineMd,
                  ),
                ),
                if (state.isSelectionMode)
                  TextButton(onPressed: onSelectAll, child: const Text("All"))
                else ...<Widget>[
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: "Recycle Bin",
                    onPressed: onOpenRecycleBin,
                  ),
                  IconButton(
                    icon: const Icon(Icons.swap_vert),
                    tooltip: "Sort",
                    onPressed: onSortTap,
                  ),
                ],
              ],
            ),
            const SizedBox(height: AuroraSpacing.xs),
            Text(
              "${state.entries.length} item${state.entries.length == 1 ? '' : 's'}"
              "${state.hasMore ? '+' : ''}",
              style: AuroraTypography.labelMonoMd.copyWith(
                color: AuroraColors.inkSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectionActionBar extends StatelessWidget {
  const _SelectionActionBar({
    required this.count,
    required this.onCopy,
    required this.onMove,
    required this.onDelete,
  });

  final int count;
  final VoidCallback onCopy;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AuroraSpacing.marginCompact),
        child: AuroraCard(
          padding: const EdgeInsets.symmetric(
            horizontal: AuroraSpacing.md,
            vertical: AuroraSpacing.sm,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: <Widget>[
              _SelectionAction(icon: Icons.copy_outlined, label: "Copy", onPressed: onCopy),
              _SelectionAction(
                icon: Icons.drive_file_move_outlined,
                label: "Move",
                onPressed: onMove,
              ),
              _SelectionAction(
                icon: Icons.delete_outline,
                label: "Delete",
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionAction extends StatelessWidget {
  const _SelectionAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AuroraSpacing.md,
            vertical: AuroraSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 20),
              const SizedBox(height: 2),
              Text(label, style: AuroraTypography.bodySm),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyFolder extends StatelessWidget {
  const _EmptyFolder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.folder_open_outlined, size: 40, color: AuroraColors.inkTertiary),
          const SizedBox(height: AuroraSpacing.md),
          Text("This folder is empty", style: AuroraTypography.bodyLg),
          const SizedBox(height: AuroraSpacing.xs),
          Text(
            "Create a folder or add files to get started.",
            style: AuroraTypography.bodySm.copyWith(color: AuroraColors.inkSecondary),
          ),
        ],
      ),
    );
  }
}
