# Project Handover

## Project Name
VaultBox — turns an Android phone into a secure personal storage server / mini-NAS (Flutter + Kotlin). Repo: `github.com/DevBehindYou/VaultBox` (public).

## Current Objective
Move a codebase that had **never compiled** to a verified, buildable state and continue Phase 0/1 (foundation + local file manager) of `docs/IMPLEMENTATION_PLAN.md`.

## User's Final Goal
A secure local-first phone storage server: local file manager first (always works), then an optional authenticated HTTPS/WebDAV/REST server on an Android Foreground Service, with sharing, users/ACL, Vault encryption, etc. Built carefully, phase by phase, using the Aurora Glass design.

## Current Status
- Project builds: **YES** (debug APK, CI run #6)
- Application launches: **UNKNOWN** — never run on any device
- Core functionality works: **PARTIAL** — local file manager logic verified with in-memory backends; no real-device or SAF verification; cannot import/open files yet
- Tests passing: **108 / 108** (CI, Linux)
- CI/CD working: **YES** (`.github/workflows/ci.yml`; runs #5, #6 green)
- Deployment working: **N/A** (nothing deployed)

## What Was Completed
- Whole-codebase analysis; CI workflow that builds/analyzes/tests and publishes logs to a `ci-reports` branch.
- Fixed a dependency-resolution failure, 5 compile errors, several analyzer issues.
- Fixed real bugs: **data loss on same-folder/ancestor Replace**, path-name mangling, reload race (duplicate rows/hangs), disposed-controller crash, null dereferences, DB-in-file-root, visible bookkeeping folder.
- Committed the generated Android scaffold (Gradle 9.3.1 / Kotlin 2.4.0, minSdk 29).
- Reconciled the native SAF bridge with real Pigeon output; added a Dart adapter; +11 regression tests.

## What Is Currently Being Worked On
Nothing in flight. Work is on branch `ci/bootstrap` (7 commits, not merged); handover docs uncommitted.

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
- **User action needed:** real-device smoke test of the APK; approval to merge/PR `ci/bootstrap` → `main`.
- No device/emulator is available to the agent; nothing can be runtime-verified without the user.

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
