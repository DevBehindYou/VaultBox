# Architecture

> Everything in **"Existing"** sections was read directly from the source in this session.
> Anything under **"Proposed"** does not exist yet. Facts about runtime behaviour are only
> stated where CI verified them — see `CURRENT_STATE.md` / `TESTING_STATUS.md`.

## High-Level Architecture (Existing)

```
View (features/*/presentation)          Flutter widgets, ConsumerWidget/ConsumerStatefulWidget
  ↓ watches
ViewModel (features/*/viewmodel)        Riverpod Notifier<State>   (only FilesViewModel exists)
  ↓ calls
UseCase (domain/usecases)               batch orchestration + safety ordering
  ↓ calls
Repository (domain/repositories iface; data/repositories impl)
  ↓ calls
StorageBackend (domain/repositories iface; data/services impl)
```

Non-negotiables encoded in code comments (cite the *missing* external doc set, see PROJECT_CONTEXT):
one `StorageBackend` for everything (ADR-004) · untrusted paths only via `StoragePath.parse` ·
never delete the only valid copy before verification · Recycle Bin is the default delete ·
never log secrets · streamed I/O only.

## Application Layers

| Layer | Path | Contents |
|---|---|---|
| Composition root | `lib/app/` | `providers.dart` (all Riverpod providers + `BackendRegistry`), `router.dart` (go_router), `shell_scaffold.dart` (5-tab dock) |
| Core | `lib/core/` | `design/` Aurora tokens+theme+widgets, `errors/app_failure.dart` (sealed `AppFailure` hierarchy), `logging/app_logger.dart`, `utils/byte_format.dart` |
| Domain | `lib/domain/` | `entities/` (`StorageRoot`, `RecycleItem`), `value_objects/` (`StoragePath`, `StorageEntry`/`StorageStat`, `StorageCapabilities`, `WriteMode`/`ConflictPolicy`), `models/` (`FileRef`, `OperationBatch`/`ItemOutcome`), `repositories/` (interfaces), `usecases/` |
| Data | `lib/data/` | `db/app_database.dart` (Drift), `repositories/` (Drift + in-memory fakes + `FileRepositoryImpl`), `services/` (3 backends, clock/id) |
| Platform | `lib/platform/adapters/android_storage_host.dart` | hand-written `AndroidStorageHost` interface that `SafStorageBackend` depends on (decoupled from Pigeon types on purpose) |
| Features | `lib/features/` | `onboarding/`, `home/`, `files/` (screen, destination picker, recycle bin, conflict dialog, `FileRow`, `FilesViewModel`), `placeholder_screen.dart` |
| Native | `android/app/src/main/kotlin/com/vaultbox/app/storage/SafStorageHostApi.kt` | first-draft SAF implementation, **not compiled, not wired** |
| Codegen source | `pigeons/storage_api.dart` | Pigeon spec → `lib/platform/pigeon/storage_api.g.dart` + `android/.../pigeon/StorageApi.g.kt` (both gitignored, generated in CI) |

## Directory Structure (Existing)

```text
VaultBox/
├── .github/workflows/ci.yml          # the build machine (added this session)
├── .gitignore                        # added this session
├── analysis_options.yaml             # strict-casts/inference/raw-types + extra lints
├── pubspec.yaml
├── README.md, LICENSE
├── docs/IMPLEMENTATION_PLAN.md       # phase plan, scope classification, risk register R-9…R-21
├── docs/ai-handover/                 # this handover
├── pigeons/storage_api.dart
├── android/                          # ONLY the Kotlin draft; Gradle scaffold is NOT committed yet
├── lib/{app,core,domain,data,platform,features}/…
├── test/{domain,data,features}/…     # 7 test files
└── vaultbox_full_app_ui_ux_design/   # 80 screens (code.html + screen.png each), DESIGN.md, 56 KB spec
```

## Major Modules

**`StoragePath`** (`domain/value_objects/storage_path.dart`) — `(rootId, segments)`; the only
path type. `parse()` = wire input (decodes once, rejects double-encoding, `..`, absolute,
backslash, control chars). `child(name)` = **literal** name append (fixed this session — it used
to route through `parse` and mangle real names). `isDescendantOfOrEqualTo` powers
copy-into-itself checks.

**`StorageBackend`** (`domain/repositories/storage_backend.dart`) — `list` (stream, name-cursor
paging), `stat` (returns `exists:false`, never throws), `openRead` (inclusive byte range),
`openWrite` → `StorageWriteHandle{sink, commit, abort}`, `createDirectory`, `rename`, `move`,
`copy`, `delete`. Implementations:
- `MemoryStorageBackend` — flat `Map<String,_MemoryNode>`; test fake that implements the *full* contract.
- `DirectPathStorageBackend` — `dart:io`; sibling temp file + rename on commit; `_resolve()` confinement.
- `SafStorageBackend` — resolves path→documentId by walking `listChildren` per segment (no cache);
  reads/writes through `File('/proc/self/fd/$fd')` (**unverified on any device**); reports
  `supportsAtomicReplace:false`, `canCopyWithinBackend:false`.

**`FileRepositoryImpl`** — resolves `FileRef.root` → backend via `BackendResolver`. `copySingle`:
same-backend → backend `copy` (Replace = delete target first, now guarded); cross-backend →
stream + size verify; directories recurse. `resolveNonConflictingName` → `name (N).ext`, bounded at 1000.

**Use cases** — `CopyItems`, `MoveItems` (always copy → delete source), `DeleteItemsToRecycleBin`
(copy to `/.vaultbox/recycle/<id>__<name>`, delete source, add metadata), `RestoreItems`,
`PermanentlyDeleteRecycled`. All return `OperationBatch` of per-item `ItemOutcome`s
(completed / skipped / failed).

**`FilesViewModel`** — `Notifier<FilesState>`, family-keyed by `FileRef`, page size 100, cursor =
name of last raw entry, directories sorted first, selection by normalised-path `Set<String>`.
Riverpod 3 shape: constructor-injected family arg, `ref.mounted` guards after awaits.

## Data Flow

Files tab → `_FilesEntryPoint` (watches `storageRootsProvider`) → `FilesScreen(rootRef(root))` →
`filesViewModelProvider(FileRef)` → `FileRepository.list` → `BackendRegistry.forRoot(root)` →
backend. Mutations go ViewModel → use case → `FileRepository` → backend, then `loadFirstPage()`.

## Authentication Flow
Not implemented.

## API Flow
Not implemented (no server code exists; `shelf`/`shelf_router`/etc. deliberately not in `pubspec.yaml`).

## Database Flow
`AppDatabase` (Drift) shared by `DriftStorageRootRepository` and `DriftRecycleBinRepository`;
both are the runtime default; in-memory twins exist as test fakes. `setDefault` runs in a transaction.
Capabilities are **not** persisted (derived from `backendType`, currently always `fullLocal()`).

## File Handling Flow
Delete → copy into per-root recycle dir → delete source → insert `recycle_items` row.
Restore → copy back with `WriteMode.create` (conflict ⇒ *skipped*, item stays in bin) → delete recycled copy → delete row.
Move → copy then delete source. Cross-root: streamed. Conflicts: one upfront Replace / Keep both / Skip for the whole batch.

## State Management
Riverpod 3.x, manual providers. `Provider`s for services/repos/use cases;
`StreamProvider` for roots; `StreamProvider.autoDispose.family` for recycle items;
`NotifierProvider.autoDispose.family` for the files ViewModel.

## Background Tasks / External Integrations
None yet. (Foreground Service, NSD, Keystore, power/network callbacks are Phase 2+.)

## Dependency Relationships
`features → app/providers → data + domain → core`. Domain depends only on `core/errors`.
`data/services/saf_storage_backend.dart → platform/adapters/android_storage_host.dart`.

## Build System

Flutter/Dart via `pubspec.yaml`; codegen via `build_runner` (Drift) and `dart run pigeon`.
Android Gradle scaffold is generated **in CI** into a scratch dir and copied into `android/`
(`cp -rn`, non-clobbering) — see `.github/workflows/ci.yml`. `applicationId` will be
`com.vaultbox.app` (`--org com.vaultbox --project-name app`).

## Deployment Architecture
None (no server, no release pipeline). Only artefact: debug APK from CI.

## Known Architectural Problems (Existing)

1. **Native bridge does not exist yet** — Kotlin draft doesn't implement the generated interface
   and (before this session's `@async` change) the spec had a synchronous `openDocumentTree()`
   that cannot wait for an Activity result.
2. **SAF byte I/O via `/proc/self/fd`** is the least-verified idea in the project: re-opening the
   magic symlink re-does path/permission resolution and may fail under scoped storage. A chunked
   platform-channel stream is the fallback.
3. **No transfer engine** — copy/move run inline, unbounded, non-cancellable.
4. **Replace is delete-then-copy** (not atomic) — acceptable only because guards now prevent the
   self/ancestor cases; SAF `openWrite(replace)` truncates in place (R-20).
5. **Sort applies only to loaded pages** (paging + client-side sort) — sorting by size/date on a
   >100-item folder is wrong until an index-backed cursor exists (R-13).
6. **No file import / open / preview** — the Files tab can create folders and manipulate existing
   files but there is no way to add a file or open one.
7. **Dark theme incomplete** — several widgets reference light-only `AuroraColors.*` directly.
8. **Fonts not registered** (Epilogue/Inter/JetBrains Mono fall back to platform default).
9. **Root offline handling** — `StorageDisconnectedFailure` is thrown for *many* unrelated
   conditions (missing dir, missing file, ENOENT); it is overloaded and will confuse recovery UX.

## Recommended Architectural Improvements (Proposed — NOT existing)

- Add a `TransferEngine` (bounded concurrency, progress, cancel) and route Copy/Move through it.
- Add a documentId cache to `SafStorageBackend` keyed by `StoragePath` (invalidate on mutation).
- Split "not found" from "storage disconnected" failures.
- Persist a file index (Drift) to enable stable cursors and server-side sort.
- Route SAF byte I/O through a chunked platform-channel stream if `/proc/self/fd` proves unreliable on-device.
