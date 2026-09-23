# Project Handover

## Project Name
VaultBox — turns an Android phone into a secure personal storage server / mini-NAS (Flutter + Kotlin). Repo: `github.com/DevBehindYou/VaultBox` (public).

## Current Objective
Move a codebase that had **never compiled** to a verified, buildable state and continue Phase 0/1 (foundation + local file manager) of `docs/IMPLEMENTATION_PLAN.md`.

## User's Final Goal
A secure local-first phone storage server: local file manager first (always works), then an optional authenticated HTTPS/WebDAV/REST server on an Android Foreground Service, with sharing, users/ACL, Vault encryption, etc. Built carefully, phase by phase, using the Aurora Glass design.

## Current Status
- Project builds: **YES** (debug APK, CI run #6)
- Application launches: **YES** — verified on a real phone (Xiaomi 23076RN4BI (custom ROM AP1A.240505.005), Android 14 / API 34, arm64-v8a, rooted, USB debugging) on 2026-09-18
- Core functionality works: **PARTIAL** — on a real phone: onboarding, storage setup, create folder, select, delete → Recycle Bin → restore, and persistence across a cold restart all WORK. Not verified: SAF/SD-card path, large files. Cannot import/open files yet
- Tests passing: **111 / 111** (CI, Linux; run 35371459634)
- CI/CD working: **YES** (`.github/workflows/ci.yml`; runs #5, #6, #7 green)
- Deployment working: **N/A** (nothing deployed)

## What Was Completed
- Whole-codebase analysis; CI workflow that builds/analyzes/tests and publishes logs to a `ci-reports` branch.
- Fixed a dependency-resolution failure, 5 compile errors, several analyzer issues.
- Fixed real bugs: **data loss on same-folder/ancestor Replace**, path-name mangling, reload race (duplicate rows/hangs), disposed-controller crash, null dereferences, DB-in-file-root, visible bookkeeping folder.
- Committed the generated Android scaffold (Gradle 9.3.1 / Kotlin 2.4.0, minSdk 29).
- Reconciled the native SAF bridge with real Pigeon output; added a Dart adapter; +14 regression tests.
- **Tested on a real phone over adb** (user connected it): install, launch, onboarding, create/select/delete/restore, on-disk layout, cold-restart persistence. Found and fixed a dark-mode bug (selected row light-on-light) that no test could catch; found the debug-signing mismatch.

## What Is Currently Being Worked On
Nothing in flight. Work is on branch `ci/bootstrap` (8 commits incl. docs, not merged; latest green `fc5f2f4`).

## Most Important Discoveries
1. The environment can't host the SDK → **CI is the only compiler**; use the `ci-reports` branch to read results.
2. Pigeon 29 `@async` ⇒ Kotlin `suspend fun`, dispatched on **Main**; `FlutterActivity` is not a `ComponentActivity`.
3. `takePersistableUriPermission` must not get the PERSISTABLE flag (the draft would have crashed).
4. `continue-on-error` hides failed outcomes in the step list — read `summary.md`.
5. The plan cites a 29-file doc set that is **not in the repo**.

## Major Problems Found (all fixed unless noted)
See ERRORS_AND_FIXES.md #1–#12. **Open:** SAF byte I/O via `/proc/self/fd` unproven; no file import/open; dark theme/fonts incomplete; sort only covers loaded pages.

## Fixes Already Applied
CHANGES_MADE.md changes 1–10.

## Current Blockers
- **User decision needed:** approval to open a PR / merge `ci/bootstrap` → `main`.
- The phone is available only while the user connects it (agent can then install + drive the app over adb; see COMMANDS_AND_LOGS 'Device testing'). CI debug APKs are signed with a different key per run, so each new build needs `adb uninstall` first (ERRORS_AND_FIXES #14, PENDING P1).

## Pending Work
PENDING_TASKS.md (P0: land branch + smoke test; P1: file import/open, wire SAF, validate SAF I/O, refresh stale docs, tighten CI).

## Recommended Next Action
Ask the user to (a) install `vaultbox-debug-apk` from run #6 (or `gh run download 35366984098 -n vaultbox-debug-apk` with their OK) and report what happens, and (b) approve a PR to `main`. Fix whatever the smoke test reveals *before* building new features.

## Critical Warnings for Next Agent
- **Never install an SDK locally; never push to `main`; never claim UNTESTED things work.**
- Replace/Move/Delete paths are data-safety critical — keep the guards and their tests.
- `README.md` and `IMPLEMENTATION_PLAN.md` are **stale** (still say nothing compiled).
- Repo is **public**: no secrets in files/logs.
- The user's git identity is `DevBehindYou`; `gh` is at `C:\Program Files\GitHub CLI\gh.exe`.

## Files the Next Agent Should Inspect First
`.github/workflows/ci.yml` · `lib/features/files/viewmodel/files_view_model.dart` · `lib/data/repositories/file_repository_impl.dart` · `lib/domain/value_objects/storage_path.dart` · `android/.../storage/SafStorageHostApi.kt` · `android/.../MainActivity.kt` · `lib/data/services/saf_storage_backend.dart` · `lib/platform/adapters/pigeon_android_storage_host.dart` · `lib/app/providers.dart` (`BackendRegistry`).

## Security Considerations (summary)
Path traversal is the main defended boundary (`StoragePath` + DirectPath confinement). No auth/TLS/server exists yet. Never log secrets. No credentials anywhere; `GITHUB_TOKEN` is auto-injected; the user's `gh` token is in their Windows keyring. Vault/encryption not started. The SAF bridge grants broad folder access — treat any future server exposure of a SAF root as high-risk.

## Performance Findings
None measured. Design intent: paged listing (100/page), fixed-height rows, streamed I/O. Known: DirectPath paging re-enumerates from the start per page (O(n²) on huge folders); SAF resolves paths with one native call per segment (no cache).

## UI/UX Findings
Aurora Glass tokens/widgets exist; Home intentionally thin; Files UI has no rename/add/open/details; onboarding has no first-run redirect; dark theme partly light-only; fonts unbundled. Mockups (80) were not visually reviewed.
