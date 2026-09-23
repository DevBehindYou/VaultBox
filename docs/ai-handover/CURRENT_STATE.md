# Current Project State

*As of 2026-09-18, end of session 1. Verification labels: **VERIFIED** (green CI run), **IMPLEMENTED BUT UNTESTED**, **PARTIALLY VERIFIED**, **BROKEN**, **NOT IMPLEMENTED**, **UNKNOWN**.*

## Build Status

| Check | Result | Evidence |
|---|---|---|
| `flutter pub get` | **VERIFIED** OK | CI run #6 |
| Drift codegen (`build_runner`) | **VERIFIED** OK | run #6 |
| Pigeon codegen | **VERIFIED** OK (Pigeon 29.0.2) | run #6 |
| `flutter analyze` (`--no-fatal-infos --no-fatal-warnings`) | **VERIFIED** "No issues found" | run #6 |
| `flutter test` | **VERIFIED** 108 / 108 pass | run #6 |
| `flutter build apk --debug` | **VERIFIED** builds, **including** the Kotlin SAF bridge | run #6; artifact `vaultbox-debug-apk` 87,506,812 B, expires 2026-10-02 |
| `flutter build apk --release` | **UNKNOWN** — never attempted (R8/minify untested; signs with debug key) | — |
| `dart format` conformance | **BROKEN (advisory)** — nearly every file "Changed" | run #6 `logs/format.log` |

As of the phone test, the latest green commit is **`11720c5`** on branch **`ci/bootstrap`** (CI run https://github.com/DevBehindYou/VaultBox/actions/runs/35371459634; **111 tests**, analyze clean, APK builds). Later commits: see SESSION_HISTORY / `git log`. *Everything the next agent does
should start from that commit.*

## Runtime Status
**VERIFIED ON A REAL DEVICE (2026-09-18, manual, via adb):** Xiaomi 23076RN4BI (custom ROM AP1A.240505.005), Android 14 / API 34, arm64-v8a, rooted, USB debugging. Cold start OK (~3.4-4.7 s), Impeller renderer, **no crash, no Dart exception, no app-process errors in logcat** through the whole flow.

Verified on-device: Home -> onboarding (Welcome -> Choose storage -> Ready) -> **'This phone' root created** (`app_flutter/storage`, hidden `.vaultbox`); Drift DB created **outside** the file root (`app_flutter/vaultbox.sqlite`); Files tab; **New folder** dialog (no controller crash); listing refresh; long-press multi-select; delete -> confirm dialog -> moved to `.vaultbox/recycle/<uuid>__<name>` (verified on disk via `run-as`); Recycle Bin screen; **Restore** (verified on disk; list refreshes on return); **cold-restart persistence** (root + folder survive `am force-stop`).

**Not verified on-device:** SAF picker/bridge (native code never executed), large-file I/O, Copy/Move/conflict dialogs, Delete-forever, sort, rotation/foldable layouts, light theme, TalkBack, low storage, background behaviour.

## Feature Status

| Feature | Status | Notes |
|---|---|---|
| Aurora Glass tokens / light+dark theme | **PARTIALLY VERIFIED** | compiles + used by passing widget tests; dark mode incomplete (light-only `AuroraColors.*` in several widgets); fonts not bundled |
| 5-tab shell + dock + go_router | **VERIFIED ON DEVICE** (manual) | no shell/router test exists; no first-run redirect to onboarding (app opens on `/home`) |
| Onboarding (Welcome → Storage → Ready) | **VERIFIED ON DEVICE** (manual) | "This phone" root now `<documents>/storage`; SD/custom-folder option still disabled; no widget test |
| Home | **VERIFIED ON DEVICE** (manual) | honest 'server off' card + storage list; **storage card shows no free/total space** (`freeBytes` never populated) |
| Files: browse / page / sort / multi-select | **VERIFIED** (widget + VM tests, in-memory) | sort is per-loaded-page only |
| Files: create folder | **VERIFIED** (widget test) | dialog bug fixed |
| Files: rename | **IMPLEMENTED BUT UNTESTED** at UI level | VM + backend rename tested; **no rename UI entry point exists** |
| Files: copy / move + destination picker + conflict dialog | **PARTIALLY VERIFIED** | use cases + guards tested; destination-picker/conflict dialogs have **no widget test** |
| Files: delete → Recycle Bin / restore / delete forever | **VERIFIED** (widget test for delete+restore; use-case tests for all) | delete-forever UI untested; no purge sweep for `purgeAfter` |
| Files: add/import a file, open/preview a file, file details, search | **NOT IMPLEMENTED** | biggest functional gap for a "file manager" |
| `StoragePath` security model | **VERIFIED** (22 tests) | |
| `MemoryStorageBackend` / `DirectPathStorageBackend` | **VERIFIED** by a shared contract suite (32 test cases) on Linux | Windows/Android specifics (errno mapping) unverified |
| `SafStorageBackend` | **PARTIALLY VERIFIED** | metadata paths tested with a fake host; byte I/O (`/proc/self/fd`) untestable off-device |
| Kotlin `SafStorageHostApi` + `MainActivity` wiring | **PARTIALLY VERIFIED** — compiles against real generated interface; **never run** | |
| Dart `PigeonAndroidStorageHost` adapter | **VERIFIED** vs a fake Pigeon client (8 tests); never talks to real native | **not used by app code yet** |
| SAF as a selectable storage root | **NOT IMPLEMENTED** | `BackendRegistry._create` still throws `UnimplementedError` for `saf`; onboarding option disabled; `StorageRoot` has no field for the root document id |
| Drift DB (`storage_roots`, `recycle_items`) | **VERIFIED** (8 tests, in-memory sqlite on Linux) | **on-device: DB created, root persisted across a cold restart** (verified) |
| Server (FGS, HTTPS, WebDAV, REST), auth, users/ACL, sharing, Vault, transfers, activity, diagnostics, settings | **NOT IMPLEMENTED** | Share/Activity/Settings tabs are honest placeholders |

## Working Components
Everything marked VERIFIED above.

## Partially Working Components
SAF stack (Dart backend + adapter + Kotlin) — each layer passes what it can in isolation; no end-to-end path.

## Broken Components
None known to be *failing* today. (`dart format` is advisory-red.)

## Known UI defects seen on the real phone (not yet fixed)
- Recycle Bin shows a generic **file** icon even for folders (`RecycleItem` has no type).
- Home 'Storage' card lists 'This phone' with no used/free space.
- The confirmation **SnackBar is a bright white bar** in dark mode, sitting over the FAB/dock area.
- Secondary text (grey on near-black) is low-contrast in dark mode (not measured).
- No compact-dock-on-scroll (spec 6.2); default Flutter launcher icon.
- (FIXED in `11720c5`, verified on device) selected file row was light-on-light in dark mode.

## Disabled Components
SD-card/custom-folder onboarding option (UI-disabled with a "Phase 2" label).

## Temporary Workarounds
- CI gate ignores analyzer infos/warnings (`--no-fatal-infos --no-fatal-warnings`).
- `dart format` not enforced.
- `EXCLUDE_SAF_DRAFT` env switch remains in `ci.yml` (now `"false"`); safe to delete once trusted.
- `flutter_lints` held at 5.0.0 (6.0.0 exists).

## Current Branch
`ci/bootstrap` (tracks `origin/ci/bootstrap`). **8 commits ahead of `main`**; **no PR opened; not merged.**
`main` = `37f1d60` ("Push", made by the user).

## Current Commit
`fc5f2f4` (green; includes the handover docs). A follow-up docs-only commit may sit on top — docs-only pushes skip CI.

## Uncommitted Changes
None expected — working tree was clean and in sync with `origin/ci/bootstrap` at the end of the session. The design folder
`vaultbox_full_app_ui_ux_design/` is already committed on `main` (163 files).

## Environment
- **Local:** Windows 11 Home (10.0.26100), PowerShell 5.1 + Git Bash. **No Flutter/Dart.** Java 21 (Oracle) present; Android SDK partial
  (`platforms;android-35/36`, `build-tools;35/36`, `platform-tools`, licenses accepted, no cmdline-tools/emulator/NDK). C: 9.3 GB free, D: 1.4 GB free.
  `gh` 2.101.0 at `C:\Program Files\GitHub CLI\gh.exe` (**not on PATH for the agent's shell — call by full path**), authenticated as `DevBehindYou`
  (scopes `gist, read:org, repo, workflow`; token in Windows keyring — never printed).
- **CI:** `ubuntu-latest`, Temurin JDK 17.0.20, Flutter 3.47.4 / Dart 3.13.3 / DevTools 2.60.0, Gradle 9.3.1, Kotlin 2.4.0.
- **Resolved deps (pubspec.lock):** flutter_riverpod/riverpod 3.4.3 · go_router 18.0.1 · drift/drift_dev 2.35.0 · drift_flutter 0.3.1 ·
  sqlite3 3.6.0 · sqlite3_flutter_libs 0.6.0+eol · pigeon 29.0.2 · build_runner 2.16.1 · path_provider 2.1.6 · uuid 4.6.0 · flutter_lints 5.0.0.

## Git / GitHub State
- Repository `https://github.com/DevBehindYou/VaultBox` — **public**; default branch `main`.
- Remote branches: `main`, `ci/bootstrap`, `ci-reports` (automation-owned, force-pushed each run).
- PRs: none. Releases/tags: none.
- Workflow: `.github/workflows/ci.yml`, job `verify` — **7 runs**; #5, #6 and #7 (`fc5f2f4`) green (Gate passed). Actions artifact: `vaultbox-debug-apk` (14-day retention).
- Local `.git` identity: `DevBehindYou <ashutoshsept20@gmail.com>` (note: differs from the `akash.sep28@gmail.com` account email — irrelevant unless attribution matters).

## Deployment State
None. No servers, domains, or secrets. **Secrets required: none.** (`GITHUB_TOKEN` is the auto-provided workflow token.)

## Current CI/CD State
Green (runs #6, #7). Docs-only pushes skip CI (`paths-ignore`). Known upcoming break: runner label `ubuntu-latest` migrates to Ubuntu 26 on 2026-10-19.

## Current Test State
108 pass / 0 fail in CI (Linux), reproduced in runs #6 and #7. One DirectPath test is `skip: Platform.isWindows` (skipped tests are not counted as failures). See TESTING_STATUS.md.

## Unresolved Conflicts Between Sources
- `docs/IMPLEMENTATION_PLAN.md` and `README.md` still say "nothing has been compiled" and that `android/` doesn't exist and that SAF Kotlin is unreconciled — **now stale** (code + CI supersede them; priority rule: latest verified state > docs). They have **not** been updated yet (see PENDING_TASKS P1).
- The plan cites an external 29-file doc set that is not in the repo.
