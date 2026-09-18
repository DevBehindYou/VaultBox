import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../app/providers.dart";
import "../../../core/design/aurora_colors.dart";
import "../../../core/design/aurora_spacing.dart";
import "../../../core/design/aurora_typography.dart";
import "../../../domain/entities/storage_root.dart";
import "../../../domain/models/file_ref.dart";
import "../../../domain/value_objects/storage_entry.dart";
import "../viewmodel/files_view_model.dart";

/// Consolidates the `move_copy_destination_picker` mockup into a single
/// pushed screen rather than its own route/shell — matches kickoff §52
/// ("choose one final production design", contextual, not a nav destination).
///
/// Read-only browsing on purpose: this reuses [filesViewModelProvider] for
/// listing (paging, sorting all come for free) but ignores its selection
/// state entirely — a picker that let you multi-select *inside* the picker
/// would be a second, confusing selection model layered on top of the one
/// that sent you here.
///
/// Returns the chosen [FileRef] via `Navigator.pop`, or `null` if cancelled.
class DestinationPickerScreen extends ConsumerStatefulWidget {
  const DestinationPickerScreen({required this.initialDirectory, super.key});

  final FileRef initialDirectory;

  @override
  ConsumerState<DestinationPickerScreen> createState() =>
      _DestinationPickerScreenState();
}

class _DestinationPickerScreenState extends ConsumerState<DestinationPickerScreen> {
  late FileRef _current = widget.initialDirectory;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<StorageRoot>> roots = ref.watch(storageRootsProvider);
    final FilesState listing = ref.watch(filesViewModelProvider(_current));

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
            child: listing.isLoadingFirstPage
                ? const Center(child: CircularProgressIndicator())
                : listing.entries.isEmpty
                    ? Center(
                        child: Text(
                          "Nothing here",
                          style: AuroraTypography.bodyMd.copyWith(
                            color: AuroraColors.inkSecondary,
                          ),
                        ),
                      )
                    : ListView.builder(
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
                                  : AuroraColors.inkTertiary,
                            ),
                            title: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: entry.isDirectory
                                  ? null
                                  : const TextStyle(color: AuroraColors.inkTertiary),
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
