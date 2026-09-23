# Changes Made (session 1, 2026-09-18)

Branch `ci/bootstrap`, 8 commits on top of `main@37f1d60` (7 code/CI commits + the docs commit). Each change lists the CI evidence.
Order = commit order. Verification always means a green run of `.github/workflows/ci.yml`.

---
## Change 1 — GitHub Actions as the build machine  (`36d2abc`)
### Problem
No Flutter/Dart/Android toolchain locally (user: not enough storage). The code had never been compiled.
### Root Cause
Environmental constraint (see DECISIONS D1).
### Solution
`.github/workflows/ci.yml` (job `verify`): setup-java 17 → flutter-action 3.47.4 → scaffold `android/` → pub get → build_runner → pigeon → format (advisory) → analyze → test → debug APK → upload APK → assemble + **publish report to `ci-reports`** → **Gate**. All verification steps `continue-on-error`; Gate fails on any `outcome == failure`.
### Files Modified
`.github/workflows/ci.yml` (new), `.gitignore` (new).
### Key Implementation Details
- Scaffold step generates into `$RUNNER_TEMP/scaffold` with `--org com.vaultbox --project-name app` and `cp -rn`'s only `android/` (avoids the default `widget_test.dart`).
- Report branch is force-pushed with `x-access-token:${GITHUB_TOKEN}`; requires `permissions: contents: write`.
- `.gitignore` ignores `*.g.dart`, `*.freezed.dart`, `*.drift.dart`, generated `pigeon/*.g.kt`, keystores, `android/local.properties`, `ci-report/`.
### Verification
Run #1 exercised it end-to-end (found Error 1). ### Remaining Concerns
`ubuntu-latest` → Ubuntu 26 on 2026-10-19. (`paths-ignore` for docs was added later — Change 11.)

---
## Change 2 — pubspec resolution fix  (`3df259f`)
### Problem / Root cause / Solution
See ERRORS_AND_FIXES #1. Removed `sqlite3_flutter_libs: ^0.5.24`. Committed **alone** so run #2 was a clean baseline of the previous session's code.
### Files Modified: `pubspec.yaml`. ### Verification: run #2 (`pub get`, `build_runner`, `pigeon` OK).

---
## Change 3 — Android Gradle scaffold committed  (`1e5c4c9`)
### Problem
`android/` contained only the Kotlin draft; nothing could build.
### Solution
Took the scaffold CI generated (run #2, `ci-reports:android-scaffold/`) and committed it: Gradle 9.3.1, Kotlin 2.4.0, `namespace`/`applicationId` `com.vaultbox.app`. **Local edits:** manifest label `VaultBox`; `minSdk = 29` (was `flutter.minSdkVersion`).
### Files Modified
`android/**` (Gradle KTS, manifests, resources, `MainActivity.kt`, wrapper properties). `gradle-wrapper.jar` intentionally **not** committed (gitignored; Flutter regenerates it).
### Verification: run #3+ APK builds. ### Remaining Concerns
`targetSdk` = Flutter default (unchecked); no release signing config; no launcher icon customisation; no `INTERNET`/foreground-service permissions yet (needed in Phase 2).

---
## Change 4 — Compile errors from the first real build  (`6d032c3`)
### Problem / Root cause / Solution
ERRORS_AND_FIXES #2–#6: Cupertino import, `handleError` `test:` type, Riverpod-3 `Override`, Drift `DateTime` test, removed lint, unused imports, `unawaited`, `close_sinks`.
### Files Modified
`lib/core/design/aurora_theme.dart`, `lib/data/services/direct_path_storage_backend.dart`, `analysis_options.yaml`, `lib/domain/repositories/file_repository.dart`, `lib/features/files/presentation/destination_picker_screen.dart`, `lib/features/onboarding/presentation/onboarding_storage_screen.dart`, `lib/data/services/saf_storage_backend.dart`, 3 test files.
### Verification: run #3 analyze clean + APK built.

---
## Change 5 — Data-loss guards for copy/move  (`6d032c3`)
### Problem
`FileRepositoryImpl.copySingle` in Replace mode **deletes the target first**. If the target *is* the source (copy/move into its own folder) or *contains* it (`/b/b` → `/`, Replace targets `/b`), the only copy was destroyed and the following copy failed. A folder copied into itself would also recurse without end (backend-level).
### Root Cause *(inspection)*
Guards existed only in the UI pre-check (`validateDestination`), and only for folder-into-itself, not same-folder or ancestor cases.
### Solution
Two layers: (1) `CopyItems`: same path ⇒ *skipped* unless Keep-both (Duplicate); `MoveItems`: destination == source's parent ⇒ *skipped* ("Already in this folder"). (2) `FileRepositoryImpl.copySingle` (same-backend branch): throws new `InvalidOperationFailure` if target ⊆ source, or (Replace) source ⊂ target.
### Files Modified
`lib/core/errors/app_failure.dart` (+`InvalidOperationFailure`), `lib/data/repositories/file_repository_impl.dart`, `lib/domain/usecases/copy_items.dart`, `lib/domain/usecases/move_items.dart`.
### Verification
6 new tests in `test/domain/file_operations_test.dart` ("Data-loss guards"), green run #5+.
### Remaining Concerns
Replace is still non-atomic delete-then-copy; cross-backend Replace relies on `openWrite(replace)` (atomic on DirectPath, truncating on SAF). Whole-path checks assume same-root comparison only.

---
## Change 6 — `StoragePath.child()` is literal  (`6d032c3`)
### Problem / Root cause
`child()` delegated to `parse()` (decode + trim), so real names changed identity; one bad name threw out of `list()`.
### Solution
Literal validation (see DECISIONS D6); listings in DirectPath/SAF skip unrepresentable names; MemoryBackend `list` uses `child()`; drive-letter check restricted to letters.
### Files Modified
`lib/domain/value_objects/storage_path.dart`, `lib/data/services/{memory,direct_path,saf}_storage_backend.dart`.
### Verification
6 new `child()` tests, a both-backends "names are literal" contract test, a DirectPath unrepresentable-name test (skipped on Windows).
### Remaining Concerns
Skipped names are invisible to the user and unlogged. Names containing `/` or `\` can't be represented at all.

---
## Change 7 — Recycle use cases: null-safety  (`6d032c3`)
`RestoreItems` / `PermanentlyDeleteRecycled` used `item!` inside `catch` blocks (null when the lookup itself failed) ⇒ crashed the batch. Now `item?.recyclePath ?? StoragePath.root("unknown")`. Tests: `LookupFailsBin` fake, 2 tests.

---
## Change 8 — App-storage root, hidden bookkeeping, `loadMore`  (`6d032c3`)
- `onboarding_actions.dart`: root is now `<documents>/storage` (was the documents dir that also holds `vaultbox.sqlite`).
- `FilesViewModel`: hides `/.vaultbox` at the root only (cursor/`hasMore` use the raw page); `loadMore` no longer runs while a failure is standing.
- Test: `.vaultbox` hidden at root, visible below.
### Concerns
No migration for an install created by an older build (none exist).

---
## Change 9 — Concurrent-reload race + dialog controller  (`87673b9`, `89e2b38`)
ERRORS_AND_FIXES #7 and #8. `FilesViewModel` rewritten around `_generation` / `_latestLoad` / `_settled()` and `await for`; `_CreateFolderDialog` StatefulWidget. Widget tests now attach `screenTexts(tester)` to failure reasons.
Verification: run #5 (all 100 tests green at that point).

---
## Change 10 — SAF native bridge reconciled  (`4bd1af5`)
### Problem
`SafStorageHostApi.kt` was a guess: not implementing the interface, plain `fun`s (generated methods are `suspend`), `registerForActivityResult` (unavailable on `FlutterActivity`), illegal `takePersistableUriPermission` flags (would throw), no root document id in the contract, no `MainActivity` wiring, no Dart adapter.
### Solution
Pigeon spec: all methods `@async`, `SafTreeMessage.rootDocumentId`. Kotlin rewritten (`override suspend fun`, `Dispatchers.IO`, `guarded{}` → `FlutterError(code=…)`, `"w"`→`"wt"`, null size stays null, `ActivityTreePickerLauncher` via `startActivityForResult`). `MainActivity` registers `AndroidStorageApi.setUp(...)`. New `PigeonAndroidStorageHost` + `SafTreeInfo.rootDocumentId`. CI no longer excludes the Kotlin file.
### Files Modified
`pigeons/storage_api.dart`, `android/.../storage/SafStorageHostApi.kt`, `android/.../MainActivity.kt`, `lib/platform/adapters/android_storage_host.dart`, `lib/platform/adapters/pigeon_android_storage_host.dart` (new), `test/platform/pigeon_android_storage_host_test.dart` (new), `.github/workflows/ci.yml`.
### Verification
Run #6: Kotlin compiles into the APK; 8 adapter tests pass. **Never executed on a device.**
### Remaining Concerns
`/proc/self/fd` byte I/O unproven; `Dispatchers.Main` picker/`onActivityResult` unproven; `pending` picker callback lost on Activity recreation; not wired to `BackendRegistry`/onboarding; `persistedTrees` may return trees whose root is gone (no stale-grant reconciliation yet).

---
## Change 11 — Handover documentation
`docs/ai-handover/*` (this package) + `paths-ignore: docs/**, **.md` on `push` in `ci.yml`. Committed as `fc5f2f4`; run #7 green.

---
## Explicitly NOT changed
`README.md` and `docs/IMPLEMENTATION_PLAN.md` still contain now-false statements ("never compiled", "android/ does not exist", etc.). `dart format` not applied. `flutter_lints` not bumped. The design folder was left untouched.
