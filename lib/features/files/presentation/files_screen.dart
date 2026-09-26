import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";

import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/design/aurora_widgets.dart";
import "../../../domain/entities/share.dart";
import "../../../domain/models/file_ref.dart";
import "../../../domain/models/operation_batch.dart";
import "../../../domain/repositories/file_repository.dart";
import "../../../domain/usecases/copy_items.dart";
import "../../../domain/usecases/delete_items_to_recycle_bin.dart";
import "../../../domain/usecases/import_files.dart";
import "../../../domain/usecases/move_items.dart";
import "../../../domain/value_objects/storage_entry.dart";
import "../../../domain/value_objects/write_mode.dart";
import "../../../platform/adapters/android_storage_host.dart";
import "../../share/presentation/create_share_dialog.dart";
import "../viewmodel/files_view_model.dart";
import "destination_picker_screen.dart";
import "recycle_bin_screen.dart";
import "widgets/conflict_dialog.dart";
import "widgets/file_row.dart";

/// The file manager. One screen handles browsing, multi-select, sort/filter
/// and per-item actions; everything else is a contextual sheet or dialog
/// rather than a route (kickoff §5, §52 — the seven "files_*" mockups
/// consolidate here).
class FilesScreen extends StatelessWidget {
  const FilesScreen({required this.directory, super.key});

  final FileRef directory;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<FilesCubit>(
      key: ValueKey<FileRef>(directory),
      create: (BuildContext context) => FilesCubit(
        directory: directory,
        files: context.read<FileRepository>(),
        deleteItems: context.read<DeleteItemsToRecycleBin>(),
        copyItems: context.read<CopyItems>(),
        moveItems: context.read<MoveItems>(),
        importFiles: context.read<ImportFiles>(),
        androidStorageHost: context.read<AndroidStorageHost>(),
      ),
      child: _FilesScreenBody(directory: directory),
    );
  }
}

class _FilesScreenBody extends StatefulWidget {
  const _FilesScreenBody({required this.directory});

  final FileRef directory;

  @override
  State<_FilesScreenBody> createState() => _FilesScreenBodyState();
}

class _FilesScreenBodyState extends State<_FilesScreenBody> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  String _query = "";

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
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final double remaining =
        _scrollController.position.maxScrollExtent - _scrollController.position.pixels;
    // Prefetch a page before hitting the bottom so scrolling never stalls
    // waiting on I/O.
    if (remaining < FileRow.rowHeight * 8) {
      unawaited(context.read<FilesCubit>().loadMore());
    }
  }

  @override
  Widget build(BuildContext context) {
    final FilesState state = context.watch<FilesCubit>().state;
    final FilesCubit viewModel = context.read<FilesCubit>();

    return Scaffold(
      // The shell's Scaffold already shrinks for the keyboard; shrinking here
      // too subtracted it twice ("BOTTOM OVERFLOWED BY 86 PIXELS", buttons
      // jumping over the header) when the search field was focused.
      resizeToAvoidBottomInset: false,
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
            if (!state.isSelectionMode)
              _FilesToolbar(
                directory: widget.directory,
                searchController: _searchController,
                onQueryChanged: (String value) => setState(() => _query = value),
                sortField: state.sortField,
                sortAscending: state.sortAscending,
                onSortTap: () => _showSortSheet(context, viewModel, state),
                onBreadcrumbTap: (int depth) => _goToBreadcrumb(depth),
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
              onShare: _onlySelected(state) == null
                  ? null
                  : () => _shareSelected(context, _onlySelected(state)!, ShareKind.download),
              onAskForFiles: _onlySelected(state)?.isDirectory ?? false
                  ? () => _shareSelected(context, _onlySelected(state)!, ShareKind.upload)
                  : null,
            )
          : null,
    );
  }

  /// The one selected item, or `null` if none or several are selected.
  StorageEntry? _onlySelected(FilesState state) {
    final List<StorageEntry> chosen = state.entries.where(state.isSelected).toList();
    return chosen.length == 1 ? chosen.first : null;
  }

  Future<void> _shareSelected(BuildContext context, StorageEntry entry, ShareKind kind) {
    return showCreateShareFlow(
      context,
      target: FileRef(root: widget.directory.root, path: entry.path),
      kind: kind,
      itemName: entry.name,
    );
  }

  Widget _buildList(FilesState state, FilesCubit viewModel) {
    if (state.isLoadingFirstPage) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.entries.isEmpty) {
      return const _EmptyFolder();
    }

    // Search only ever looks at pages already loaded (state.entries) — same
    // "per-loaded-page" limitation sort already has (no index-backed search
    // yet, PENDING_TASKS). Good enough for a folder a person can see through.
    final String query = _query.trim().toLowerCase();
    final List<StorageEntry> visible = query.isEmpty
        ? state.entries
        : state.entries.where((StorageEntry e) => e.name.toLowerCase().contains(query)).toList();

    if (visible.isEmpty) {
      return _NoSearchResults(query: _query);
    }

    return ListView.builder(
      controller: _scrollController,
      // itemExtent lets the framework skip child measurement entirely —
      // required for large directories to scroll smoothly (see FileRow).
      itemExtent: FileRow.rowHeight,
      padding: const EdgeInsets.only(bottom: AuroraSpacing.dockScrollClearance),
      itemCount: visible.length + (query.isEmpty && state.isLoadingMore ? 1 : 0),
      itemBuilder: (BuildContext context, int index) {
        if (index >= visible.length) {
          return const Center(
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final StorageEntry entry = visible[index];
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
          onMenu: () => _showEntryMenu(context, viewModel, entry),
        );
      },
    );
  }

  /// Pops back to the directory [depth] levels deep (0 = the root) — every
  /// subfolder is its own pushed [FilesScreen], so this is just popping the
  /// difference, not a new navigation mechanism.
  void _goToBreadcrumb(int depth) {
    final int pops = widget.directory.path.segments.length - depth;
    for (int i = 0; i < pops; i++) {
      Navigator.of(context).pop();
    }
  }

  /// Per-row "⋮" menu: the same actions the selection bar offers, applied to
  /// just this one entry (selecting it first reuses that existing logic
  /// rather than duplicating the transfer/delete/share flows).
  Future<void> _showEntryMenu(
    BuildContext context,
    FilesCubit viewModel,
    StorageEntry entry,
  ) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final String? action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text("Rename"),
                onTap: () => Navigator.of(sheetContext).pop("rename"),
              ),
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text("Copy"),
                onTap: () => Navigator.of(sheetContext).pop("copy"),
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_move_outlined),
                title: const Text("Move"),
                onTap: () => Navigator.of(sheetContext).pop("move"),
              ),
              if (!entry.isDirectory)
                ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: const Text("Share"),
                  onTap: () => Navigator.of(sheetContext).pop("share"),
                ),
              if (entry.isDirectory)
                ListTile(
                  leading: const Icon(Icons.move_to_inbox_outlined),
                  title: const Text("Ask for files"),
                  onTap: () => Navigator.of(sheetContext).pop("ask"),
                ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text("Delete"),
                onTap: () => Navigator.of(sheetContext).pop("delete"),
              ),
            ],
          ),
        );
      },
    );
    if (action == null || !context.mounted) return;

    if (action == "rename") {
      await _renameEntry(context, viewModel, entry);
      return;
    }

    // Every other action reuses the selection-based flow: select just this
    // entry (the menu only shows outside selection mode, so this starts from
    // no selection), run the existing handler, then clear the selection.
    viewModel.toggleSelection(entry);
    switch (action) {
      case "copy":
        await _copySelected(context, viewModel);
      case "move":
        await _moveSelected(context, viewModel);
      case "share":
        await _shareSelected(context, entry, ShareKind.download);
      case "ask":
        await _shareSelected(context, entry, ShareKind.upload);
      case "delete":
        await _confirmDelete(context, viewModel);
    }
    if (viewModel.state.isSelected(entry)) viewModel.toggleSelection(entry);
  }

  Future<void> _renameEntry(
    BuildContext context,
    FilesCubit viewModel,
    StorageEntry entry,
  ) async {
    final String? newName = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => _RenameDialog(initialName: entry.name),
    );
    final String trimmed = (newName ?? "").trim();
    if (trimmed.isEmpty || trimmed == entry.name) return;
    await viewModel.rename(entry, trimmed);
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
  Future<void> _openRecycleBin(BuildContext context, FilesCubit viewModel) async {
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
  Future<void> _importFiles(BuildContext context, FilesCubit viewModel) async {
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

  Future<void> _copySelected(BuildContext context, FilesCubit viewModel) async {
    await _runTransfer(context, viewModel, isMove: false);
  }

  Future<void> _moveSelected(BuildContext context, FilesCubit viewModel) async {
    await _runTransfer(context, viewModel, isMove: true);
  }

  /// Shared picker → validate → conflict-check → execute flow for both Copy
  /// and Move. Every `await` below is followed by a `context.mounted` guard
  /// before the next context-touching step — this method crosses several
  /// async gaps (a pushed screen, two dialogs, then the operation itself),
  /// and any one of them can outlive the widget (KB vol2 §9.1).
  Future<void> _runTransfer(
    BuildContext context,
    FilesCubit viewModel, {
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
    FilesCubit viewModel,
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
    FilesCubit viewModel,
    FilesState state,
  ) async {
    // Otherwise the search field gets focus back (and the keyboard) when the sheet closes.
    FocusManager.instance.primaryFocus?.unfocus();
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

  Future<void> _confirmDelete(BuildContext context, FilesCubit viewModel) async {
    final int count = viewModel.state.selectedCount;
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

/// Search box + breadcrumb + current sort, above the file list. Hidden during
/// selection mode (see the caller) — none of it is useful mid-bulk-action.
class _FilesToolbar extends StatelessWidget {
  const _FilesToolbar({
    required this.directory,
    required this.searchController,
    required this.onQueryChanged,
    required this.sortField,
    required this.sortAscending,
    required this.onSortTap,
    required this.onBreadcrumbTap,
  });

  final FileRef directory;
  final TextEditingController searchController;
  final ValueChanged<String> onQueryChanged;
  final FileSortField sortField;
  final bool sortAscending;
  final VoidCallback onSortTap;

  /// Called with the tapped crumb's depth (0 = the root).
  final ValueChanged<int> onBreadcrumbTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AuroraSpacing.marginCompact,
        0,
        AuroraSpacing.marginCompact,
        AuroraSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: searchController,
            onChanged: onQueryChanged,
            decoration: InputDecoration(
              isDense: true,
              hintText: "Search this folder…",
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: searchController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: "Clear search",
                      onPressed: () {
                        searchController.clear();
                        onQueryChanged("");
                        FocusManager.instance.primaryFocus?.unfocus();
                      },
                    ),
              filled: true,
              fillColor: context.cardColor,
              border: OutlineInputBorder(
                borderRadius: AuroraRadii.standardAll,
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: AuroraSpacing.sm),
          Row(
            children: <Widget>[
              Expanded(child: _Breadcrumb(directory: directory, onTap: onBreadcrumbTap)),
              const SizedBox(width: AuroraSpacing.sm),
              InkWell(
                onTap: onSortTap,
                borderRadius: AuroraRadii.pillAll,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: context.cardColor,
                    borderRadius: AuroraRadii.pillAll,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 14,
                        color: context.inkSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(_sortLabel(sortField), style: AuroraTypography.labelMonoMd),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _sortLabel(FileSortField field) => switch (field) {
    FileSortField.name => "Name",
    FileSortField.modified => "Date",
    FileSortField.size => "Size",
    FileSortField.type => "Type",
  };
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.directory, required this.onTap});

  final FileRef directory;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final List<String> segments = directory.path.segments;
    final List<Widget> crumbs = <Widget>[
      _Crumb(label: directory.root.displayName, current: segments.isEmpty, onTap: () => onTap(0)),
    ];
    for (int i = 0; i < segments.length; i++) {
      crumbs.add(Icon(Icons.chevron_right, size: 16, color: context.inkTertiary));
      crumbs.add(
        _Crumb(label: segments[i], current: i == segments.length - 1, onTap: () => onTap(i + 1)),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: crumbs),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({required this.label, required this.current, required this.onTap});

  final String label;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: current ? null : onTap,
      borderRadius: AuroraRadii.standardAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: current
              ? AuroraTypography.bodySm.copyWith(fontWeight: FontWeight.w700)
              : AuroraTypography.bodySm.copyWith(color: context.inkSecondary),
        ),
      ),
    );
  }
}

/// Same controller-ownership shape as [_CreateFolderDialog] — see its doc
/// comment for why the controller must be owned here, not by the caller.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Rename"),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: "New name"),
        onSubmitted: (String value) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Cancel"),
        ),
        TextButton(onPressed: _submit, child: const Text("Rename")),
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
                color: context.inkSecondary,
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
    this.onShare,
    this.onAskForFiles,
  });

  final int count;
  final VoidCallback onCopy;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  /// Only when exactly one item is selected.
  final VoidCallback? onShare;

  /// Only when exactly one folder is selected.
  final VoidCallback? onAskForFiles;

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
              if (onShare != null)
                _SelectionAction(icon: Icons.share_outlined, label: "Share", onPressed: onShare),
              if (onAskForFiles != null)
                _SelectionAction(icon: Icons.move_to_inbox_outlined, label: "Ask for files", onPressed: onAskForFiles),
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

class _NoSearchResults extends StatelessWidget {
  const _NoSearchResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.search_off, size: 40, color: context.inkTertiary),
          const SizedBox(height: AuroraSpacing.md),
          Text('No results for "$query"', style: AuroraTypography.bodyLg),
          const SizedBox(height: AuroraSpacing.xs),
          Text(
            "Only files already loaded on this screen are searched.",
            style: AuroraTypography.bodySm.copyWith(color: context.inkSecondary),
          ),
        ],
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
          Icon(Icons.folder_open_outlined, size: 40, color: context.inkTertiary),
          const SizedBox(height: AuroraSpacing.md),
          Text("This folder is empty", style: AuroraTypography.bodyLg),
          const SizedBox(height: AuroraSpacing.xs),
          Text(
            "Create a folder or add files to get started.",
            style: AuroraTypography.bodySm.copyWith(color: context.inkSecondary),
          ),
        ],
      ),
    );
  }
}
