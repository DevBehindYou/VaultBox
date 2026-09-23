# Errors and Fixes

All errors below were **observed in CI** (source: `ci-reports` branch logs, runs #1–#5, 2026-09-18)
unless marked *(inspection)*. "RESOLVED" = confirmed by a later green CI run.
Run map: #1 `36d2abc` · #2 `3df259f` (baseline) · #3 `6d032c3` · #4 `87673b9` · #5 `89e2b38` (**first fully green**) · #6 `SAF bridge` (see TESTING_STATUS).

---

## Error 1 — `pub get` cannot resolve dependencies (project never could build)

### Error Message
```text
Because vaultbox depends on drift_flutter ^0.3.1 which depends on sqlite3_flutter_libs ^0.6.0+eol,
sqlite3_flutter_libs ^0.6.0+eol is required.
So, because vaultbox depends on sqlite3_flutter_libs ^0.5.24, version solving failed.
```
### Where / Root cause
`pubspec.yaml`. A direct `sqlite3_flutter_libs: ^0.5.24` pin contradicts drift_flutter's requirement (`^0.6.0+eol`, an end-of-life no-op stub; SQLite is bundled by `package:sqlite3` 3.x build hooks).
### Investigation
Run #1 `logs/pub_get.log`; every later step was skipped (`if: steps.pub_get.outcome == 'success'`).
### Final Fix
Removed the direct pin (commit `3df259f`). drift_flutter supplies it transitively.
### Status: RESOLVED (run #2 `pub get` success)
### Notes
Previous session claimed versions were "verified against pub.dev"; the drift pins were, this one was a stale leftover.

---

## Error 2 — `CupertinoPageTransitionsBuilder` undefined

### Error Message
```text
error • The method 'CupertinoPageTransitionsBuilder' isn't defined for the type 'AuroraTheme' • lib/core/design/aurora_theme.dart:148:31
error • Invalid constant value / non_constant_map_value  (same line, cascading)
```
### Root cause
`package:flutter/material.dart` no longer re-exports Cupertino symbols in Flutter 3.47.
### Final Fix
`import "package:flutter/cupertino.dart" show CupertinoPageTransitionsBuilder;`
### Status: RESOLVED (run #5 analyze "No issues found")

---

## Error 3 — `handleError(test:)` wrong parameter type

### Error Message
```text
lib/data/services/direct_path_storage_backend.dart:121:17: Error: The argument type 'bool Function(Object)'
can't be assigned to the parameter type 'bool Function(dynamic)?'.
```
### Root cause
`Stream.handleError`'s `test` takes `bool Function(dynamic)`; a closure with an `Object` parameter is not a subtype.
### Final Fix
`test: (Object? error) => error is FileSystemException`
### Status: RESOLVED. Also broke the whole APK build and the backend contract test file (compile failure → `loading …contract_test.dart [E]`).

---

## Error 4 — `Override` isn't a type (Riverpod 3)

### Error Message
```text
test/features/files_screen_test.dart:47:19: Error: 'Override' isn't a type.   overrides: <Override>[
```
### Root cause
Riverpod 3 does not export `Override` from `package:flutter_riverpod/flutter_riverpod.dart`.
### Final Fix
Let inference type the list: `overrides: [ ... ]`.
### Status: RESOLVED

---

## Error 5 — Drift `DateTime` equality in a test

### Error Message
```text
Expected: DateTime:<2026-09-16 12:00:00.000Z>   Actual: DateTime:<2026-09-16 12:00:00.000>
```
### Root cause
Drift returns **local** `DateTime`s; `DateTime ==` also compares `isUtc`. Same instant, different objects. (Production code is unaffected — it only formats/diffs.)
### Final Fix
Test uses `isAtSameMomentAs`.
### Status: RESOLVED

---

## Error 6 — Analyzer warnings/infos (baseline)
`removed_lint: avoid_returning_null_for_future` (removed from `analysis_options.yaml`); two `unused_import`s; `unawaited_futures` in `onboarding_storage_screen.dart`; `close_sinks` false positive in `saf_storage_backend.dart` (`// ignore: close_sinks`). **RESOLVED** (run #5: *No issues found*).

---

## Error 7 — Overlapping reloads duplicate rows and can hang *(behaviour bug; found by test)*

### Error Message
```text
Expected: ['taken.txt']   Actual: ['taken.txt', 'taken.txt']     (files_view_model_test findConflicts)
```
### Root cause
`FilesViewModel.loadFirstPage()` cancelled the previous subscription but the previous call still finished and appended its page onto the **new** call's `state.entries`. The cancelled call's `Completer` could also never complete, hanging awaiting callers (`createFolder`, `deleteSelected`, Recycle-Bin return). Real-app trigger: any reload while the initial load is in flight.
### Failed approach (do NOT repeat)
First fix used a generation token so stale loads discard their result — but a superseded `loadFirstPage()` then **returned early**, before the listing was loaded, so `await loadFirstPage()` callers saw an empty list (my own `.vaultbox` test caught it, run #4).
### Final Fix
Generation token **plus** `_latestLoad`/`_settled()`: a superseded call waits for the newest load before returning. Loop uses `await for` so returning cancels the backend stream.
### Status: RESOLVED (run #5)

---

## Error 8 — "TextEditingController was used after being disposed" *(real app bug)*

### Error Message
```text
The following assertion was thrown building RawGestureDetector(...):
A TextEditingController was used after being disposed.
The relevant error-causing widget was: TextField  files_screen.dart:248:20
… then: 'package:flutter/src/widgets/framework.dart': Failed assertion: line 6281: '_dependents.isEmpty'
```
Symptom in the widget test: `screen: []` — the failure message showed **no Text widget at all**.
### Root cause
`_showCreateFolderDialog` created the controller and disposed it in a `finally` immediately after `showDialog` returned. `showDialog`'s future completes on `pop()` while the dialog is still animating out and its `TextField` still uses the controller. This would throw in a debug build of the real app and corrupt the tree (which then cascaded into the *next* test — the "delete then restore" failure was a pure cascade).
### Final Fix
`_CreateFolderDialog` `StatefulWidget` owns and disposes its controller.
### Status: RESOLVED (run #5)
### Notes for next agent
When a widget test fails with a bare `_dependents.isEmpty` assertion, look for the **first** exception in the log (`grep -n "EXCEPTION CAUGHT"`); later ones are cascade.

---

## Error 9 — Destructive Replace *(inspection; regression-tested)*
Replace copy/move onto itself or onto an ancestor deleted the only copy before copying. See CHANGES_MADE "Data-loss guards". **RESOLVED** (6 new tests, run #5).

## Error 10 — `StoragePath.child()` rewrote real names *(inspection; regression-tested)*
`100%25.txt`→`100%.txt`; `%2F` → `/` inside one segment; edge spaces trimmed; `1:1 notes.txt` rejected as a drive letter; one odd name aborted the whole listing. **RESOLVED** (run #5).

## Error 11 — `item!` null dereference in Restore/PermanentlyDelete catch blocks *(inspection)*
A failing repository lookup would throw a `NullError` and abort the batch. **RESOLVED** (2 tests).

## Error 12 — `takePersistableUriPermission` with `FLAG_GRANT_PERSISTABLE_URI_PERMISSION` *(inspection of the draft Kotlin)*
The platform accepts only READ/WRITE bits and throws `IllegalArgumentException` otherwise. Fixed in the rewritten `SafStorageHostApi.kt`. **IMPLEMENTED, COMPILES (see run #6), NOT device-verified.**

---

## Error 13 — Selected file row unreadable in dark mode *(found on a real device)*
### Symptom
Long-press-selecting a folder in dark mode: the row background became near-white (#EEF3FB) while its text stayed light, so the folder name was practically invisible.
### Root cause
`FileRow` used the **light theme's** `AuroraColors.selectionSoft`/`selectionBlue` unconditionally; `AuroraColorsDark` had no selection colours. Widget tests only rendered the light theme, so CI could not see it.
### Fix
`AuroraColorsDark.selectionSoft (#1E2B40)` / `selectionBlue (#6AA7F2)`; `FileRow` picks by brightness. Test `test/features/file_row_test.dart` (3 tests). **Re-verified on the phone.**
### Status: RESOLVED (run 35371459634 + on device)
### Lesson
The dark theme is this phone's default and no test rendered it. Other light-only `AuroraColors.*` uses remain (see CURRENT_STATE 'Known UI defects').

---

## Error 14 — Newer CI APK cannot update an installed one *(tooling, not app code)*
### Error Message
```text
adb: failed to install app-debug.apk: Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE:
Existing package com.vaultbox.app signatures do not match newer version; ignoring!]
```
### Root cause
`flutter build apk --debug` signs with the runner's `~/.android/debug.keystore`, generated fresh on each new GitHub runner VM, so every CI run yields a differently-signed APK.
### Workaround used
`adb uninstall com.vaultbox.app` (deletes app-private data; only test data here), then `adb install`.
### Proper fix (PROPOSED — needs the user's OK: it commits a debug signing key to a *public* repo)
Generate one debug keystore with `keytool` (JDK 21 is installed locally), commit it as `android/app/debug.keystore` (+ `.gitignore` exception), set `signingConfigs.debug` in `android/app/build.gradle.kts`. **Debug-only; never reuse for a release key.** Afterwards `adb install -r` updates in place and keeps data.
### Status: WORKAROUND ONLY — see PENDING_TASKS P1

---

## Non-errors worth knowing (traps)

- **`continue-on-error` masks failures in the step list.** `gh run view` / the Actions API show `success` for a step whose *outcome* was `failure`. Read `summary.md` or the gate.
- **`dart format --set-exit-if-changed` fails on essentially every file** (Dart 3.13 formatter style). Advisory only; see DECISIONS D11.
- **CRLF warnings on Windows** (`LF will be replaced by CRLF`) are harmless; the repo stores LF. No `.gitattributes` exists.
- **A silent failed `adb install` leaves the OLD build running.** Read the install result ('Success') before trusting a screenshot.
- `gh run download` produced an empty folder when run in the background; `gh api repos/.../actions/artifacts/<id>/zip > file.zip` worked (~45 s for 87 MB).
- `actions/upload-artifact` etc.: latest majors used are `checkout@v7`, `setup-java@v6`, `upload-artifact@v7`, `flutter-action@v2` (checked 2026-09-18). A runner annotation warns `ubuntu-latest` migrates to Ubuntu 26 on 2026-10-19 — pin `ubuntu-24.04` if that breaks the build.
