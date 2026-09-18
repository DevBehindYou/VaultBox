import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../app/providers.dart";
import "../../../core/errors/app_failure.dart";
import "../../../domain/entities/storage_root.dart";
import "../../../domain/models/file_ref.dart";
import "../../../domain/models/operation_batch.dart";
import "../../../domain/repositories/file_repository.dart";
import "../../../domain/value_objects/storage_entry.dart";
import "../../../domain/value_objects/storage_path.dart";
import "../../../domain/value_objects/write_mode.dart";

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

/// ViewModel for one directory view.
///
/// Family-keyed by [FileRef] so each open directory has its own element —
/// which is why [FileRef] implements `==`/`hashCode` (KB vol2 §4.3: family
/// arguments need stable equality or every rebuild is a cache miss).
///
/// **Riverpod 3.x shape** (verified against riverpod.dev's 3.0 migration
/// guide, not guessed): family notifiers no longer receive their argument as
/// a `build(Arg arg)` parameter, and there is no more
/// `AutoDisposeFamilyNotifier` base class — `AutoDisposeNotifier` and
/// `FamilyNotifier` were fused into plain [Notifier]. The family argument is
/// instead injected through the constructor below, and `build()` takes no
/// parameters. The provider declaration at the bottom of this file
/// (`NotifierProvider.autoDispose.family<...>(FilesViewModel.new)`) is
/// unchanged by this — only the class body's shape moved.
///
/// Enumeration is paged rather than "list everything then render": doc
/// NFR-PERF-003 requires a responsive browser at 10,000+ files, and the
/// backend contract streams entries precisely so the first page can paint
/// before the tail has been read.
final class FilesViewModel extends Notifier<FilesState> {
  FilesViewModel(this.arg);

  /// The directory this instance was created for — one element per distinct
  /// [FileRef], per the family contract.
  final FileRef arg;

  static const int _pageSize = 100;
  static const String _reservedDirName = ".vaultbox";

  String? _cursor;

  /// Bumped by every [loadFirstPage] (and on dispose). A load only applies its
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
  FilesState build() {
    // Invalidate any in-flight load when this element goes away; the load
    // loop notices on its next event and stops consuming (which cancels the
    // backend stream).
    ref.onDispose(() => _generation++);
    scheduleMicrotask(loadFirstPage);
    return FilesState(directory: arg);
  }

  FileRepository get _files => ref.read(fileRepositoryProvider);

  Future<void> loadFirstPage() async {
    // Riverpod 3.0: touching `ref`/`state` after this element is disposed
    // now THROWS rather than silently no-op-ing (breaking change from 2.x —
    // verified against the official 3.0 migration guide, not assumed). Every
    // method here that resumes after an `await` guards with `ref.mounted`
    // before touching `state` again, since the screen that owns this
    // provider can be popped mid-operation (e.g. a fast back-out during a
    // folder load).
    if (!ref.mounted) return;
    final int generation = ++_generation;
    _cursor = null;
    state = state.copyWith(
      entries: const <StorageEntry>[],
      isLoadingFirstPage: true,
      isLoadingMore: false,
      hasMore: true,
      clearFailure: true,
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
    state = state.copyWith(isLoadingMore: true);
    await _loadPage(_generation);
  }

  Future<void> _loadPage(int generation) async {
    bool isStale() => !ref.mounted || generation != _generation;

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
      state = state.copyWith(
        isLoadingFirstPage: false,
        isLoadingMore: false,
        failure: failure,
      );
      return;
    } on Object catch (error) {
      // Anything that isn't already a typed failure is a bug or a platform
      // surprise; keep the raw detail behind "Technical details" only.
      if (isStale()) return;
      state = state.copyWith(
        isLoadingFirstPage: false,
        isLoadingMore: false,
        failure: UnexpectedFailure(debugDetail: error.toString()),
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
      ...page.where((StorageEntry e) => !(atRoot && e.name == _reservedDirName)),
    ];
    _sortInPlace(combined);

    state = state.copyWith(
      entries: combined,
      isLoadingFirstPage: false,
      isLoadingMore: false,
      hasMore: page.length == _pageSize,
    );
  }

  void setSort(FileSortField field, {required bool ascending}) {
    final List<StorageEntry> sorted = <StorageEntry>[...state.entries];
    state = state.copyWith(sortField: field, sortAscending: ascending);
    _sortInPlace(sorted);
    state = state.copyWith(entries: sorted);
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
    state = state.copyWith(
      selectedPaths: next,
      isSelectionMode: next.isNotEmpty,
    );
  }

  void selectAll() {
    state = state.copyWith(
      selectedPaths: state.entries.map((StorageEntry e) => e.path.normalized).toSet(),
      isSelectionMode: state.entries.isNotEmpty,
    );
  }

  void clearSelection() {
    state = state.copyWith(selectedPaths: const <String>{}, isSelectionMode: false);
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
      if (!ref.mounted) return;
      state = state.copyWith(failure: failure);
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
      if (!ref.mounted) return;
      state = state.copyWith(failure: failure);
    }
  }

  /// Returns the batch so the caller can show the per-item summary
  /// ("46 completed · 1 skipped · 1 failed") rather than a bare success toast.
  Future<OperationBatch> deleteSelected() async {
    final List<FileRef> refs = selectedRefs;
    final OperationBatch batch =
        await ref.read(deleteItemsProvider).call(sources: refs);
    if (!ref.mounted) return batch;
    clearSelection();
    await loadFirstPage();
    return batch;
  }

  Future<OperationBatch> copySelectedTo(
    FileRef destination, {
    ConflictPolicy policy = ConflictPolicy.keepBoth,
  }) async {
    final OperationBatch batch = await ref.read(copyItemsProvider).call(
      sources: selectedRefs,
      destinationDirectory: destination,
      conflictPolicy: policy,
    );
    if (!ref.mounted) return batch;
    clearSelection();
    await loadFirstPage();
    return batch;
  }

  Future<OperationBatch> moveSelectedTo(
    FileRef destination, {
    ConflictPolicy policy = ConflictPolicy.keepBoth,
  }) async {
    final OperationBatch batch = await ref.read(moveItemsProvider).call(
      sources: selectedRefs,
      destinationDirectory: destination,
      conflictPolicy: policy,
    );
    if (!ref.mounted) return batch;
    clearSelection();
    await loadFirstPage();
    return batch;
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

  void dismissFailure() => state = state.copyWith(clearFailure: true);
}

final filesViewModelProvider =
    NotifierProvider.autoDispose.family<FilesViewModel, FilesState, FileRef>(
      FilesViewModel.new,
    );

/// Convenience for building a [FileRef] for a root's top level.
FileRef rootRef(StorageRoot root) =>
    FileRef(root: root, path: StoragePath.root(root.id));
