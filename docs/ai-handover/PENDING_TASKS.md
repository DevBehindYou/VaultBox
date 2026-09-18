# Pending Tasks

Every task below assumes the **CI-only verification loop** (no local SDK). "Verification criteria" = what a green CI run / the user must show.

## P0 — Critical

- [ ] **Get the work onto `main` (user decision needed).**
  - Problem: 7 commits + docs live only on `ci/bootstrap`; `main` still has the un-compilable baseline.
  - Required action: commit `docs/ai-handover/*`, then **ask the user** whether to open a PR `ci/bootstrap → main` (or merge). Do not push to `main` unasked. If opening a PR: `gh pr create --base main --head ci/bootstrap`; note `gh` is at `C:\Program Files\GitHub CLI\gh.exe`.
  - Relevant files: whole branch. Dependencies: user approval.
  - Verification: `main` builds green in CI (workflow triggers on push to any branch except `ci-reports`).

- [x] **Smoke-test the debug APK on a real phone — DONE 2026-09-18** (agent-driven over adb while the user had the phone connected). Original text kept below; repeat after UI-affecting changes.
  - Problem: the app has never been launched; every runtime claim is UNKNOWN.
  - Required action: user downloads artifact `vaultbox-debug-apk` (run #6, 87.5 MB, expires 2026-10-02) — `gh run download 35366984098 -n vaultbox-debug-apk` (needs the user's OK: it's a file download) or the Actions page — installs it, then: launch → Files tab → "Set up storage" → "This phone" → New folder → long-press → Delete → Recycle Bin → Restore. Ask for a screenshot/`adb logcat` of any crash.
  - Verification: user confirms each step; any crash gets logged in ERRORS_AND_FIXES.
  - Risk: first-launch crashes (Drift init, `path_provider`, router) are plausible and untested.

- [ ] **Re-run CI after any change and read `ci-reports` before claiming anything works.** (Standing rule.)

## P1 — High priority

- [ ] **Add file import/open (the app can't add a file today).**
  - Required action: add a picker (`file_picker` or a SAF `ACTION_OPEN_DOCUMENT` Pigeon method) + "Add files" FAB/menu → stream into `openWrite` (never `readAsBytes`); open/preview via an intent or an in-app viewer. Needs a decision on the package (see DECISIONS; check pub.dev with `Invoke-RestMethod https://pub.dev/api/packages/<name>`).
  - Files: `lib/features/files/**`, `pubspec.yaml`, `AndroidManifest.xml`.
  - Verification: widget test with an in-memory backend + APK smoke test.

- [ ] **Wire SAF into the app (make "SD card / custom folder" real).**
  - Problem: `BackendRegistry._create` throws `UnimplementedError` for `saf`; onboarding option disabled; `StorageRoot` has no root-document-id field.
  - Required action: (1) store root document id (new Drift column ⇒ **schema v2 + migration**, or derive via `AndroidStorageHost.persistedTrees()` at startup); (2) `BackendRegistry` builds `SafStorageBackend(host: PigeonAndroidStorageHost(), treeUri: root.uriOrPath, rootDocumentId: …)`; (3) `_capabilitiesFor` in `DriftStorageRootRepository` must return SAF's honest capabilities (`canMoveWithinBackend:false`, `supportsAtomicReplace:false`…); (4) enable the onboarding option → `host.openDocumentTree()` → verify with a real write probe → add root; (5) reconcile `persistedTrees()` vs stored roots (revoked grant ⇒ mark unavailable).
  - Files: `lib/app/providers.dart`, `lib/data/db/app_database.dart`, `lib/data/repositories/drift_storage_root_repository.dart`, `lib/features/onboarding/**`, `lib/domain/entities/storage_root.dart`.
  - Verification: unit tests with `FakeAndroidStorageHost`; **device test required** for the byte path.

- [ ] **Validate SAF byte I/O on a device; fall back if `/proc/self/fd` fails.**
  - Problem: `File('/proc/self/fd/$fd')` re-open may hit scoped-storage checks (R-19). Also Dart must close the detached fd.
  - Required action: on-device test: read + write a >500 MB file, cancel mid-transfer. If it fails, implement chunked streaming over an `EventChannel` (or Pigeon `@async` read/write-chunk methods) inside `SafStorageBackend` without changing its public contract.
  - Verification: user-run test; add an integration test only if a device/emulator lane becomes available.

- [ ] **Update stale docs.** `README.md` ("nothing compiled", "android/ does not exist", setup) and `docs/IMPLEMENTATION_PLAN.md` (§A, §G R-9/R-10/R-11/R-19, §H "Not yet written"). Record: CI is the build machine, Pigeon `suspend` fact, resolved risks (R-9, R-12 already, R-19 partially), new risks below.

- [ ] **Add rename + file-details entry points in the Files UI** (VM/backends already support rename; no UI calls it).

- [ ] **Tighten CI gate:** `--fatal-infos`, then enforce `dart format` after a single dedicated reformat commit (DECISIONS D11); pin `runs-on: ubuntu-24.04` before 2026-10-19; add `flutter test --coverage`.

- [ ] **Stable debug signing so CI APKs update in place** (ERRORS_AND_FIXES #14). Ask the user first (adds a debug keystore to a public repo). Steps: `keytool -genkeypair -v -keystore android/app/debug.keystore -alias androiddebugkey -storepass android -keypass android -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US"`, `.gitignore` exception, `signingConfigs.debug` in `app/build.gradle.kts`, CI green, one last uninstall, then `adb install -r` works. Release signing must use a different, secret key (GitHub Actions secrets) — never commit it.

- [ ] **Polish found on the real phone:** Recycle Bin folder icon (store entry type in `RecycleItem` -> Drift schema bump); Home storage card free/total; dark-mode SnackBar styling/placement; dark-mode secondary-text contrast; launcher icon; audit remaining light-only `AuroraColors.*`; add a dark-theme widget pass for every screen.

## P2 — Medium

- [ ] Transfer engine (bounded concurrency, progress, cancel) replacing inline copy/move (`docs/IMPLEMENTATION_PLAN.md` §H item 2).
- [ ] Widget tests: onboarding, shell/router (incl. first-run redirect — app currently opens on `/home`), destination picker, conflict dialog, Recycle Bin screen.
- [ ] Recycle Bin purge sweep for `purgeAfter` (30-day retention is recorded but never enforced); set `sizeBytes` on recycle (always null today).
- [ ] Split `StorageDisconnectedFailure` (overloaded for "not found"/"missing dir"/ENOENT) into distinct failures.
- [ ] Dark-theme audit (widgets using `AuroraColors.*` directly); register fonts (Epilogue, Inter, JetBrains Mono, Patrick Hand) via `google_fonts` or assets.
- [ ] Log (via `AppLogger`) when a listing skips an unrepresentable name.
- [ ] Index-backed paging + server-side sort (R-13); SAF documentId cache (R-21).
- [ ] Release build: signing config, R8 rules for Drift/Pigeon, `flutter build apk --release` in CI.
- [ ] Bump `flutter_lints` to 6.x and fix the fallout.

## P3 — Optional

- [ ] Phase 2 (Foreground Service host) → Phase 3 (HTTPS + auth) → Phase 4 (WebDAV) … per `docs/IMPLEMENTATION_PLAN.md` §F. **Do not start before P0/P1 are done and the user has smoke-tested.**
- [ ] Obtain the missing `Android_Personal_Storage_Server_Documentation/` set from the user before Phase 2.
- [ ] Review the 80 mockups screen-by-screen (only listed/sampled so far) before building each consolidated screen; generate a per-screen checklist.
- [ ] Consider `.gitattributes` (`* text=auto eol=lf`) to silence CRLF warnings.
- [ ] Remove the `EXCLUDE_SAF_DRAFT` switch once nobody needs to bisect Kotlin.

## New risks found this session (add to the plan's register)
| ID | Risk |
|---|---|
| R-22 | Never launched on any device: first-run crash risk in Drift init / router / permissions is entirely unknown. |
| R-23 | Picker result callback (`ActivityTreePickerLauncher.pending`) is lost if the Activity is destroyed while the system picker is open (process/Activity recreation). |
| R-24 | Skipped unrepresentable filenames are silent — files with `\` in the name are invisible. |
| R-25 | Replace remains non-atomic; guards cover self/ancestor cases only. |
| R-26 | `ubuntu-latest` → Ubuntu 26 migration (2026-10-19) may change the toolchain image. |
| R-27 | Release/R8 build never attempted. |
