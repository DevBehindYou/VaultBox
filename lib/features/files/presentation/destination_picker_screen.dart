import "package:flutter/material.dart";
import "package:flutter_bloc/flutter_bloc.dart";

import "../../../app/app_state.dart";
import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_context.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../core/state/resource.dart";
import "../../../domain/entities/storage_root.dart";
import "../../../domain/models/file_ref.dart";
import "../../../domain/repositories/file_repository.dart";
import "../../../domain/usecases/copy_items.dart";
import "../../../domain/usecases/delete_items_to_recycle_bin.dart";
import "../../../domain/usecases/import_files.dart";
import "../../../domain/usecases/move_items.dart";
import "../../../domain/value_objects/storage_entry.dart";
import "../../../platform/adapters/android_storage_host.dart";
import "../viewmodel/files_view_model.dart";

/// Consolidates the `move_copy_destination_picker` mockup into a single
/// pushed screen rather than its own route/shell — matches kickoff §52
/// ("choose one final production design", contextual, not a nav destination).
///
/// Read-only browsing on purpose: this reuses [FilesCubit] for
/// listing (paging, sorting all come for free) but ignores its selection
/// state entirely — a picker that let you multi-select *inside* the picker
/// would be a second, confusing selection model layered on top of the one
/// that sent you here.
///
/// Returns the chosen [FileRef] via `Navigator.pop`, or `null` if cancelled.
class DestinationPickerScreen extends StatefulWidget {
  const DestinationPickerScreen({required this.initialDirectory, super.key});

  final FileRef initialDirectory;

  @override
  State<DestinationPickerScreen> createState() =>
      _DestinationPickerScreenState();
}

class _DestinationPickerScreenState extends State<DestinationPickerScreen> {
  late FileRef _current = widget.initialDirectory;

  @override
  Widget build(BuildContext context) {
    final Resource<List<StorageRoot>> roots = context.watch<StorageRootsCubit>().state;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _current.path.isRoot ? _current.root.displayName : _current.path.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: _current.path.isRoot
            ? const CloseButton()
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _current = FileRef(root: _current.root, path: _current.path.parent);
                }),
              ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(_current),
            child: const Text("Select this folder"),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          roots.maybeWhen(
            data: (List<StorageRoot> list) => list.length > 1
                ? _RootSwitcher(
                    roots: list,
                    selectedId: _current.root.id,
                    onSelect: (StorageRoot root) =>
                        setState(() => _current = rootRef(root)),
                  )
                : const SizedBox.shrink(),
            orElse: () => const SizedBox.shrink(),
          ),
          Expanded(
            // Read-only browsing on purpose: this reuses [FilesCubit] for
            // listing (paging, sorting all come for free) but ignores its
            // selection state entirely — a fresh instance per [_current],
            // same effect as the old family provider, via a key that
            // changes whenever the browsed directory does.
            child: BlocProvider<FilesCubit>(
              key: ValueKey<FileRef>(_current),
              create: (BuildContext context) => FilesCubit(
                directory: _current,
                files: context.read<FileRepository>(),
                deleteItems: context.read<DeleteItemsToRecycleBin>(),
                copyItems: context.read<CopyItems>(),
                moveItems: context.read<MoveItems>(),
                importFiles: context.read<ImportFiles>(),
                androidStorageHost: context.read<AndroidStorageHost>(),
              ),
              child: Builder(
                builder: (BuildContext context) {
                  final FilesState listing = context.watch<FilesCubit>().state;
                  if (listing.isLoadingFirstPage) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (listing.entries.isEmpty) {
                    return Center(
                      child: Text(
                        "Nothing here",
                        style: AuroraTypography.bodyMd.copyWith(
                          color: context.inkSecondary,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: listing.entries.length,
                    itemBuilder: (BuildContext context, int index) {
                      final StorageEntry entry = listing.entries[index];
                      return ListTile(
                        enabled: entry.isDirectory,
                        leading: Icon(
                          entry.isDirectory
                              ? Icons.folder_outlined
                              : Icons.insert_drive_file_outlined,
                          color: entry.isDirectory
                              ? AuroraColors.auroraLavender
                              : context.inkTertiary,
                        ),
                        title: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: entry.isDirectory
                              ? null
                              : TextStyle(color: context.inkTertiary),
                        ),
                        trailing: entry.isDirectory
                            ? const Icon(Icons.chevron_right, size: 20)
                            : null,
                        onTap: entry.isDirectory
                            ? () => setState(() {
                                  _current = FileRef(
                                    root: _current.root,
                                    path: entry.path,
                                  );
                                })
                            : null,
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RootSwitcher extends StatelessWidget {
  const _RootSwitcher({
    required this.roots,
    required this.selectedId,
    required this.onSelect,
  });

  final List<StorageRoot> roots;
  final String selectedId;
  final ValueChanged<StorageRoot> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AuroraSpacing.marginCompact,
          vertical: AuroraSpacing.xs,
        ),
        itemCount: roots.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(width: AuroraSpacing.sm),
        itemBuilder: (BuildContext context, int index) {
          final StorageRoot root = roots[index];
          final bool selected = root.id == selectedId;
          return ChoiceChip(
            label: Text(root.displayName),
            selected: selected,
            onSelected: (_) => onSelect(root),
          );
        },
      ),
    );
  }
}

/// Pushes the picker and returns the chosen [FileRef], or `null` on cancel.
Future<FileRef?> pickDestination(BuildContext context, {required FileRef initialDirectory}) {
  return Navigator.of(context).push<FileRef>(
    MaterialPageRoute<FileRef>(
      builder: (_) => DestinationPickerScreen(initialDirectory: initialDirectory),
      fullscreenDialog: true,
    ),
  );
}
