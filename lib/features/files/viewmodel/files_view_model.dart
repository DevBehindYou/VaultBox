import "dart:async";

import "package:flutter_bloc/flutter_bloc.dart";

import "../../../core/errors/app_failure.dart";
import "../../../data/services/picked_file_source.dart";
import "../../../domain/entities/storage_root.dart";
import "../../../domain/models/file_ref.dart";
import "../../../domain/models/operation_batch.dart";
import "../../../domain/repositories/file_repository.dart";
import "../../../domain/usecases/copy_items.dart";
import "../../../domain/usecases/delete_items_to_recycle_bin.dart";
import "../../../domain/usecases/import_files.dart";
import "../../../domain/usecases/move_items.dart";
import "../../../domain/value_objects/storage_entry.dart";
import "../../../domain/value_objects/storage_path.dart";
import "../../../domain/value_objects/write_mode.dart";
import "../../../platform/adapters/android_storage_host.dart";

enum FileSortField { name, modified, size, type }

/// Immutable presentation state for the Files screen.
///
/// Selection is a `Set<String>` of normalized paths rather than a
/// `Set<StorageEntry>`: entries get replaced wholesale when a page reloads,
/// and identity-based selection would silently drop items across a refresh.
final class FilesState {
  const FilesState({
    required this.directory,
    this.entries = const <StorageEntry>[],
    this.isLoadingFirstPage = true,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.selectedPaths = const <String>{},
    this.isSelectionMode = false,
    this.sortField = FileSortField.name,
    this.sortAscending = true,
    this.failure,
  });

  final FileRef directory;
  final List<StorageEntry> entries;
  final bool isLoadingFirstPage;
  final bool isLoadingMore;
  final bool hasMore;
  final Set<String> selectedPaths;
  final bool isSelectionMode;
  final FileSortField sortField;
  final bool sortAscending;
  final AppFailure? failure;

  int get selectedCount => selectedPaths.length;

  bool isSelected(StorageEntry entry) => selectedPaths.contains(entry.path.normalized);

  FilesState copyWith({
    FileRef? directory,
    List<StorageEntry>? entries,
    bool? isLoadingFirstPage,
    bool? isLoadingMore,
    bool? hasMore,
    Set<String>? selectedPaths,
    bool? isSelectionMode,
    FileSortField? sortField,
    bool? sortAscending,
    AppFailure? failure,
    bool clearFailure = false,
  }) {
    return FilesState(
      directory: directory ?? this.directory,
      entries: entries ?? this.entries,
      isLoadingFirstPage: isLoadingFirstPage ?? this.isLoadingFirstPage,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      selectedPaths: selectedPaths ?? this.selectedPaths,
      isSelectionMode: isSelectionMode ?? this.isSelectionMode,
      sortField: sortField ?? this.sortField,
      sortAscending: sortAscending ?? this.sortAscending,
      failure: clearFailure ? null : (failure ?? this.failure),
    );
  }
}

/// Cubit for one directory view.
///
/// Was family-keyed by [FileRef] under Riverpod (one instance per distinct
/// [FileRef]) — under flutter_bloc, that becomes: construct a fresh
/// [FilesCubit] directly wherever one is needed (`FilesScreen`'s own
/// `BlocProvider`, `DestinationPickerScreen`'s), each wrapped in its own
/// `BlocProvider<FilesCubit>(key: ValueKey(fileRef), create: (context) =>
/// FilesCubit(directory: fileRef, ...))` so a new directory really does get a
/// fresh instance (same effect as the old `.autoDispose.family`).
///
/// Enumeration is paged rather than "list everything then render": doc
/// NFR-PERF-003 requires a responsive browser at 10,000+ files, and the
/// backend contract streams entries precisely so the first page can paint
/// before the tail has been read.
final class FilesCubit extends Cubit<FilesState> {
  FilesCubit({
    required FileRef directory,
    required FileRepository files,
    required DeleteItemsToRecycleBin deleteItems,
    required CopyItems copyItems,
    required MoveItems moveItems,
    required ImportFiles importFiles,
    required AndroidStorageHost androidStorageHost,
  }) : _files = files,
       _deleteItems = deleteItems,
       _copyItems = copyItems,
       _moveItems = moveItems,
       _importFiles = importFiles,
       _androidStorageHost = androidStorageHost,
       super(FilesState(directory: directory)) {
    scheduleMicrotask(loadFirstPage);
  }

  final FileRepository _files;
  final DeleteItemsToRecycleBin _deleteItems;
  final CopyItems _copyItems;
  final MoveItems _moveItems;
  final ImportFiles _importFiles;
  final AndroidStorageHost _androidStorageHost;

  static const int _pageSize = 100;
  static const String _reservedDirName = ".vaultbox";

  /// Marker file that keeps this root's media out of Gallery/Photos apps
  /// (see `onboarding_actions.dart`'s `_createNoMedia`) — bookkeeping, not
  /// user content, same reasoning as [_reservedDirName].
  static const String _noMediaFileName = ".nomedia";

  String? _cursor;

  /// Bumped by every [loadFirstPage] (and on close). A load only applies its
  /// result if it is still the newest one when it finishes.
  ///
  /// Without this, two overlapping reloads (e.g. the initial load still in
  /// flight when "create folder" or "back from Recycle Bin" reloads) each
  /// appended their page onto whatever `state.entries` held at that moment —
  /// producing duplicate rows — and the superseded one could wait forever on
  /// a stream it had itself cancelled.
  int _generation = 0;

  /// The newest [loadFirstPage] load. A superseded caller still has to honour
  /// "when this returns, the listing is loaded", so it waits for this one.
  Future<void>? _latestLoad;

  @override
  Future<void> close() {
    // Invalidate any in-flight load when this Cubit goes away; the load loop
    // notices on its next event and stops consuming (which cancels the
    // backend stream).
    _generation++;
    return super.close();
  }

  Future<void> loadFirstPage() async {
    // Touching `state`/`emit` after this Cubit is closed throws — every
    // method here that resumes after an `await` guards with `isClosed`
    // before touching state again, since the screen that owns this Cubit
    // can be popped mid-operation (e.g. a fast back-out during a folder
    // load).
    if (isClosed) return;
    final int generation = ++_generation;
    _cursor = null;
    emit(
      state.copyWith(
        entries: const <StorageEntry>[],
        isLoadingFirstPage: true,
        isLoadingMore: false,
        hasMore: true,
        clearFailure: true,
      ),
    );
    final Future<void> mine = _loadPage(generation);
    _latestLoad = mine;
    await _settled(mine);
  }

  Future<void> _settled(Future<void> mine) async {
    Future<void> waitingOn = mine;
    while (true) {
      await waitingOn;
      final Future<void>? latest = _latestLoad;
      if (latest == null || identical(latest, waitingOn)) return;
      waitingOn = latest;
    }
  }

  Future<void> loadMore() async {
    // A standing failure means "Retry" (loadFirstPage) is the way forward;
    // paging on top of it used to leave isLoadingMore stuck true forever.
    if (state.isLoadingMore ||
        state.isLoadingFirstPage ||
        !state.hasMore ||
        state.failure != null) {
      return;
    }
    emit(state.copyWith(isLoadingMore: true));
    await _loadPage(_generation);
  }

  Future<void> _loadPage(int generation) async {
    bool isStale() => isClosed || generation != _generation;

    final String? cursor = _cursor;
    final List<StorageEntry> page = <StorageEntry>[];

    try {
      await for (final StorageEntry entry in _files.list(
        state.directory,
        cursor: cursor,
        pageSize: _pageSize,
      )) {
        // Returning from inside `await for` cancels the underlying stream.
        if (isStale()) return;
        page.add(entry);
      }
    } on AppFailure catch (failure) {
      if (isStale()) return;
      emit(
        state.copyWith(
          isLoadingFirstPage: false,
          isLoadingMore: false,
          failure: failure,
        ),
      );
      return;
    } on Object catch (error) {
      // Anything that isn't already a typed failure is a bug or a platform
      // surprise; keep the raw detail behind "Technical details" only.
      if (isStale()) return;
      emit(
        state.copyWith(
          isLoadingFirstPage: false,
          isLoadingMore: false,
          failure: UnexpectedFailure(debugDetail: error.toString()),
        ),
      );
      return;
    }

    if (isStale()) return;

    // The cursor and hasMore are driven by the RAW page (what the backend
    // returned), not the filtered one, so hiding an entry can't stall paging.
    _cursor = page.isEmpty ? cursor : page.last.name;
    final bool atRoot = state.directory.path.isRoot;
    final List<StorageEntry> combined = <StorageEntry>[
      ...state.entries,
      // `.vaultbox` is VaultBox's own bookkeeping (Recycle Bin lives in it).
      // Showing it lets a user delete or rename it and silently break restore.
      // `.nomedia` is the same idea: bookkeeping, not something to browse.
      ...page.where(
        (StorageEntry e) => !(atRoot && (e.name == _reservedDirName || e.name == _noMediaFileName)),
      ),
    ];
    _sortInPlace(combined);

    final bool hasMore = page.length == _pageSize;
    emit(
      state.copyWith(
        entries: combined,
        isLoadingFirstPage: false,
        isLoadingMore: false,
        hasMore: hasMore,
      ),
    );

    // Keep reading straight away rather than when the person scrolls to the
    // bottom: pages arrive in directory order and the whole list is re-sorted,
    // so a page fetched mid-scroll landed ABOVE the viewport and a single pass
    // through a 250-item folder showed only half of it (real device,
    // 2026-09-26). Loading the rest now settles the list within a moment.
    if (hasMore) unawaited(loadMore());
  }

  void setSort(FileSortField field, {required bool ascending}) {
    final List<StorageEntry> sorted = <StorageEntry>[...state.entries];
    emit(state.copyWith(sortField: field, sortAscending: ascending));
    _sortInPlace(sorted);
    emit(state.copyWith(entries: sorted));
  }

  /// Directories always sort above files regardless of the active field —
  /// standard file-manager behaviour, and the mockups show it too.
  void _sortInPlace(List<StorageEntry> entries) {
    final int direction = state.sortAscending ? 1 : -1;
    entries.sort((StorageEntry a, StorageEntry b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      final int comparison = switch (state.sortField) {
        FileSortField.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        FileSortField.size => (a.sizeBytes ?? 0).compareTo(b.sizeBytes ?? 0),
        FileSortField.modified => (a.modifiedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(b.modifiedAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
        FileSortField.type =>
          _extensionOf(a.name).compareTo(_extensionOf(b.name)),
      };
      return comparison * direction;
    });
  }

  static String _extensionOf(String name) {
    final int dot = name.lastIndexOf(".");
    return dot <= 0 ? "" : name.substring(dot + 1).toLowerCase();
  }

  // --- Selection ---

  void toggleSelection(StorageEntry entry) {
    final Set<String> next = <String>{...state.selectedPaths};
    final String key = entry.path.normalized;
    if (!next.remove(key)) next.add(key);
    emit(
      state.copyWith(
        selectedPaths: next,
        isSelectionMode: next.isNotEmpty,
      ),
    );
  }

  void selectAll() {
    emit(
      state.copyWith(
        selectedPaths: state.entries.map((StorageEntry e) => e.path.normalized).toSet(),
        isSelectionMode: state.entries.isNotEmpty,
      ),
    );
  }

  void clearSelection() {
    emit(state.copyWith(selectedPaths: const <String>{}, isSelectionMode: false));
  }

  List<FileRef> get selectedRefs {
    final StorageRoot root = state.directory.root;
    return state.entries
        .where((StorageEntry e) => state.selectedPaths.contains(e.path.normalized))
        .map((StorageEntry e) => FileRef(root: root, path: e.path))
        .toList();
  }

  // --- Operations ---

  Future<void> createFolder(String name) async {
    try {
      await _files.createDirectory(state.directory, name);
      await loadFirstPage();
    } on AppFailure catch (failure) {
      if (isClosed) return;
      emit(state.copyWith(failure: failure));
    }
  }

  Future<void> rename(StorageEntry entry, String newName) async {
    try {
      await _files.renameSingle(
        FileRef(root: state.directory.root, path: entry.path),
        newName,
      );
      await loadFirstPage();
    } on AppFailure catch (failure) {
      if (isClosed) return;
      emit(state.copyWith(failure: failure));
    }
  }

  /// Returns the batch so the caller can show the per-item summary
  /// ("46 completed · 1 skipped · 1 failed") rather than a bare success toast.
  Future<OperationBatch> deleteSelected() async {
    final List<FileRef> refs = selectedRefs;
    final OperationBatch batch = await _deleteItems.call(sources: refs);
    if (isClosed) return batch;
    clearSelection();
    await loadFirstPage();
    return batch;
  }

  Future<OperationBatch> copySelectedTo(
    FileRef destination, {
    ConflictPolicy policy = ConflictPolicy.keepBoth,
  }) async {
    final OperationBatch batch = await _copyItems.call(
      sources: selectedRefs,
      destinationDirectory: destination,
      conflictPolicy: policy,
    );
    if (isClosed) return batch;
    clearSelection();
    await loadFirstPage();
    return batch;
  }

  Future<OperationBatch> moveSelectedTo(
    FileRef destination, {
    ConflictPolicy policy = ConflictPolicy.keepBoth,
  }) async {
    final OperationBatch batch = await _moveItems.call(
      sources: selectedRefs,
      destinationDirectory: destination,
      conflictPolicy: policy,
    );
    if (isClosed) return batch;
    clearSelection();
    await loadFirstPage();
    return batch;
  }

  /// "Add files": lets the person pick files with the system picker, then
  /// imports them into this folder.
  ///
  /// Returns the per-file batch, or `null` if nothing happened (picker
  /// cancelled, or the person cancelled at the conflict prompt). [onConflicts]
  /// is asked once, only if some picked names already exist here; returning
  /// `null` from it cancels the whole import. The picker's temporary copies are
  /// always deleted, whatever the outcome.
  Future<OperationBatch?> importFiles({
    required Future<ConflictPolicy?> Function(List<String> conflictingNames) onConflicts,
  }) async {
    final List<PickedFile> picked;
    try {
      picked = await _androidStorageHost.pickFilesToCache();
    } on AppFailure catch (failure) {
      if (!isClosed) emit(state.copyWith(failure: failure));
      return null;
    }
    if (picked.isEmpty) return null; // cancelled

    Future<void> discardAll() async {
      for (final PickedFile file in picked) {
        await deletePickedCacheFile(file.cachePath);
      }
    }

    try {
      if (isClosed) return null;
      final FileRef destination = state.directory;

      final List<String> conflicts = <String>[];
      for (final PickedFile file in picked) {
        if (await _existsIn(destination, file.name)) conflicts.add(file.name);
      }

      ConflictPolicy policy = ConflictPolicy.keepBoth;
      if (conflicts.isNotEmpty) {
        final ConflictPolicy? chosen = await onConflicts(conflicts);
        if (chosen == null) return null; // cancelled; `finally` discards the copies
        policy = chosen;
      }
      if (isClosed) return null;

      final OperationBatch batch = await _importFiles.call(
        sources: picked.map(importSourceFromPicked).toList(),
        destinationDirectory: destination,
        conflictPolicy: policy,
      );
      if (!isClosed) await loadFirstPage();
      return batch;
    } finally {
      await discardAll(); // idempotent; also covers early exits and unexpected throws
    }
  }

  Future<bool> _existsIn(FileRef directory, String name) async {
    try {
      final StorageEntry? existing = await _files.statEntry(
        FileRef(root: directory.root, path: directory.path.child(name)),
      );
      return existing != null;
    } on PathTraversalRejectedFailure {
      return false; // an unusable name isn't a conflict; the import reports it as failed
    }
  }

  // --- Copy/move pre-flight (destination picker + conflict sheet) ---

  /// Checks the *current selection* against [destination] for a name clash,
  /// before any copy/move I/O starts. One stat per selected item — fine at
  /// the scale a manual multi-select reaches; if this were driven by a
  /// programmatic bulk import instead of a person tapping rows, it should
  /// switch to a single `list()` + set-diff rather than N stats.
  Future<List<String>> findConflicts(FileRef destination) async {
    final List<String> conflicts = <String>[];
    for (final FileRef source in selectedRefs) {
      final FileRef candidate = FileRef(
        root: destination.root,
        path: destination.path.child(source.name),
      );
      final StorageEntry? existing = await _files.statEntry(candidate);
      if (existing != null) conflicts.add(source.name);
    }
    return conflicts;
  }

  /// Blocks a destination that is the selection's own directory, or is
  /// inside one of the selected folders — "copy this folder into itself"
  /// (doc §11 caveat: never let the write side see through to its own
  /// source). Returns a user-facing message, or null if [destination] is
  /// fine.
  String? validateDestination(FileRef destination) {
    for (final FileRef source in selectedRefs) {
      if (destination.root.id == source.root.id &&
          destination.path.isDescendantOfOrEqualTo(source.path)) {
        return "Can't copy or move a folder into itself.";
      }
    }
    return null;
  }

  void dismissFailure() => emit(state.copyWith(clearFailure: true));
}

/// Convenience for building a [FileRef] for a root's top level.
FileRef rootRef(StorageRoot root) =>
    FileRef(root: root, path: StoragePath.root(root.id));
