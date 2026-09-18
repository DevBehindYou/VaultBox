import "dart:async";

import "../value_objects/storage_capabilities.dart";
import "../value_objects/storage_entry.dart";
import "../value_objects/storage_path.dart";
import "../value_objects/write_mode.dart";

/// A handle for streaming a write. Callers push bytes via [sink] and must
/// call [commit] when done or [abort] on any failure/cancellation —
/// implementations are responsible for the temp→verify→commit pattern
/// described in doc §11 ("Generic copy") and §26 ("Data integrity motto":
/// never destroy the only valid copy of user data before the replacement is
/// verified). Never calling either leaves a backend-specific orphaned temp
/// file, which is why every call site (see `data_safety.dart`, Phase 1
/// follow-up) wraps this in try/finally.
abstract interface class StorageWriteHandle {
  StreamSink<List<int>> get sink;

  /// Finalizes the write — for backends that support it, this is the atomic
  /// rename-over-temp step. Returns the number of bytes actually written, so
  /// callers can verify against an expected size/checksum before trusting
  /// the result.
  Future<int> commit();

  /// Discards the write and cleans up any temp state. Safe to call multiple
  /// times; safe to call after [commit] has already succeeded (no-op).
  Future<void> abort();
}

/// The single storage abstraction every file-facing module depends on —
/// `03_System_Architecture_MVVM.md` ("Storage abstraction") and ADR-004.
/// WebDAV, HTTP, FTPS, the local file manager and Vault transforms all read
/// and write through implementations of this interface; no protocol package
/// is ever allowed to own the data/storage model directly.
///
/// Implementations: [see `data/services/`] `MemoryStorageBackend` (tests),
/// `DirectPathStorageBackend` (this delivery), `SafStorageBackend` (Phase 2,
/// pending native bridge — see `platform/pigeon/storage_api.dart`),
/// `VaultStorageBackend` (Phase 8).
abstract interface class StorageBackend {
  /// Matches the owning [StorageRoot.id] — a backend instance is scoped to
  /// exactly one root.
  String get id;

  Future<StorageCapabilities> capabilities();

  /// Directory listing. Streams entries rather than returning a `List` so
  /// large directories render incrementally (NFR-PERF-003) — the ViewModel
  /// is responsible for pagination/virtualization on top of this, not this
  /// interface.
  ///
  /// Paging contract, identical across every backend: [cursor] is the **name**
  /// of the last entry the caller already received, and enumeration resumes
  /// strictly after it; `null` means start from the beginning. Callers pass
  /// back `lastEntry.name` without needing to know which backend they're
  /// talking to.
  ///
  /// Caveat worth knowing before relying on deep paging: this only holds if a
  /// backend enumerates in a stable order between calls. The in-memory backend
  /// sorts, so it does. `DirectPathStorageBackend` inherits whatever order the
  /// OS gives it, which is stable in practice on a quiet directory but is not
  /// guaranteed if the directory is being modified concurrently — a file added
  /// mid-scroll can be missed or repeated. That's an acceptable trade for now
  /// (the alternative is buffering and sorting the whole directory, which is
  /// exactly what NFR-PERF-003 forbids at 10,000 files), but it should become
  /// an index-backed cursor once the file index lands (doc §06).
  Stream<StorageEntry> list(StoragePath directory, {String? cursor, int? pageSize});

  /// Resolves metadata for one path. Returns a [StorageStat] with
  /// `exists: false` rather than throwing when nothing is there — "does this
  /// exist" is a normal question, not an error.
  Future<StorageStat> stat(StoragePath path);

  /// Streams file content. [start]/[end] are an inclusive byte range for
  /// backends that report `supportsRandomAccess` (doc §10 "Range requests");
  /// implementations that don't support ranges should throw if a range is
  /// requested rather than silently ignoring it.
  Stream<List<int>> openRead(StoragePath path, {int? start, int? end});

  /// Opens a streaming write handle. See [StorageWriteHandle] doc comment
  /// for the commit/abort contract.
  Future<StorageWriteHandle> openWrite(StoragePath path, {WriteMode mode = WriteMode.create});

  Future<void> createDirectory(StoragePath path);

  /// Renames the leaf segment only — same parent, new [newName]. For moving
  /// to a different parent use [move].
  Future<void> rename(StoragePath source, String newName);

  /// Moves within this backend. Callers needing cross-backend moves (e.g.
  /// SD card → Vault) compose this with [copy] + [delete] at the use-case
  /// layer (doc §11 "Generic move": "If safe backend-native move exists: move.
  /// Otherwise: copy → verify → delete source. Never delete source first.").
  Future<void> move(StoragePath source, StoragePath target);

  Future<void> copy(StoragePath source, StoragePath target);

  /// Permanent delete at the backend level. Recycle Bin semantics (default
  /// deletion target per ADR-012) live one layer up, in `FileRepository` /
  /// `DeleteItemsToRecycleBin` — this method is the "actually remove the
  /// bytes" primitive that the Recycle Bin's own purge step eventually calls.
  Future<void> delete(StoragePath path);
}
