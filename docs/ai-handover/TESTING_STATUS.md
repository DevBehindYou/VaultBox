# Testing Status

Terminology: *inspected* (read only) · *implemented* · *compiled* · *tested* (automated, CI) ·
*verified in runtime* · *verified on a real device* · *verified in production*.
**Nothing in this project has been verified on a device or in production.** All "tested" below means
`flutter test` on `ubuntu-latest` in GitHub Actions.

## Build Testing
- `flutter build apk --debug` — **compiled** OK in CI (run #6), incl. Kotlin. Artifact: `vaultbox-debug-apk`.
- Release build, signing, R8, split-ABI, App Bundle — **not attempted**.

## Unit Testing — 108 tests, all passing (run #6)

| File | ≈ Tests (log-line count; approximate) | Covers |
|---|---|---|
| `test/data/storage_backend_contract_test.dart` | 32 | one suite run against **Memory** and **DirectPath** backends: round-trip, abort leaves nothing, create/replace modes, dup dir, list direct-children, name-cursor paging, inclusive byte range, copy/no-clobber/recursive, rename, recursive delete, **literal names**, DirectPath other-root refusal, **unrepresentable-name skip** |
| `test/domain/storage_path_test.dart` | 22 | normalisation, parent/equality, traversal rejection (plain, %-encoded, double-encoded, backslash, absolute, control chars), `child()` literal semantics, `isDescendantOfOrEqualTo` |
| `test/domain/file_operations_test.dart` | 21 | CopyItems/MoveItems (batch isolation, keepBoth/skip, failed copy leaves source), Delete→bin, Restore (+conflict), PermanentlyDelete (+no-op), **data-loss guards** (same-folder replace/move, ancestor replace, copy-into-self), **failing lookup** |
| `test/features/files_screen_test.dart` | 17 (counts include framework-reported sub-events) | Files widget: render, empty, long-press selection, create folder, delete→bin→restore round-trip |
| `test/data/saf_storage_backend_test.dart` | 9 | metadata half of SAF backend vs a fake host |
| `test/data/drift_repositories_test.dart` | 8 | Drift roots + recycle repos on `NativeDatabase.memory()` |
| `test/features/files_view_model_test.dart` | *(counted in the totals above)* | findConflicts, `.vaultbox` hiding, validateDestination |
| `test/platform/pigeon_android_storage_host_test.dart` | *(added in run #6)* | adapter mapping + error translation vs a fake Pigeon client |

(Per-file counts are from a grep of the expanded reporter; totals are authoritative: **+108, no failures**.)

## Integration Testing
None. No `integration_test/` directory.

## UI Testing
Widget tests for `FilesScreen` only. **Not covered:** onboarding, home, shell/dock/router, destination picker, conflict dialog, Recycle Bin screen in isolation, dark theme, accessibility/semantics, golden tests.

## Device Testing / Compatibility Testing
**None.** No device, emulator, OEM lab, or Android-version matrix.

## API Testing / Security Testing / Performance Testing
No server exists. Path-traversal logic is unit-tested (highest-value tests, doc §42). No fuzzing, no perf/jank profiling, no 10,000-file benchmark, no memory profiling of streaming copy.

## Database Testing
Drift repos tested in-memory. **Not tested:** migrations (schema v1 only), on-device file location, concurrent access, `driftDatabase()` initialisation.

## Deployment Testing / CI/CD Testing
CI workflow itself exercised across 6 runs. The `ci-reports` publish step works with `GITHUB_TOKEN` (`contents: write`).

## Tests Failing
None (run #6).

## Tests Not Yet Run
`flutter test` on Windows/macOS (contract suite has 1 skip-on-Windows test; sqlite3 native lib resolution unverified there).

## Manual Verification Performed
Code review of every file in `lib/`, `test/`, `pigeons/`, Kotlin draft, docs, design system doc. Mockups (80 screens) were **listed and sampled by name only**, not visually reviewed.

## Known Testing Gaps (prioritised)
1. **Real-device smoke test** of the debug APK: launch → onboarding → "This phone" → create/delete/restore. *(User can do this: install the CI artifact.)*
2. SAF on a real device: pick tree → list → create → copy a large file → read back (validates `/proc/self/fd`; R-19/R-20).
3. Widget tests for onboarding, router/shell, destination picker, conflict dialog, Recycle Bin.
4. A property/regression test for `BackendRegistry` `saf` path once wired.
5. Golden tests / dark-mode audit.
6. Coverage measurement (`flutter test --coverage`) — not yet collected.
