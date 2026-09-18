# Instructions for the Next AI Agent

You are continuing an existing project. **Do NOT restart it.** It is a Flutter/Android app (VaultBox — a phone-as-NAS) that, as of the end of session 1, **compiles, analyzes clean, passes 108 tests and builds a debug APK in CI**, but has **never been run on a device**.

## Read first (in order)
1. `HANDOVER.md` · 2. `CURRENT_STATE.md` · 3. `ERRORS_AND_FIXES.md` · 4. `PENDING_TASKS.md` · 5. `DECISIONS.md` · then `ARCHITECTURE.md` and `docs/IMPLEMENTATION_PLAN.md` (**partly stale** — see CURRENT_STATE "Unresolved Conflicts").

## The one hard constraint
**The user cannot install Flutter/Dart/Android SDK (no disk). Never download or install a toolchain, and never propose it.** All verification is GitHub Actions. (User correction #1 in PROJECT_CONTEXT.)

## First objective
Get the user's decision on landing `ci/bootstrap`, and get a **real-device smoke test** of the debug APK (PENDING P0). Then P1: file import/open, SAF wiring, on-device SAF byte-I/O validation.

## The verification loop (memorise this)
```bash
# 0) sanity: where am I / is anything unpushed?
git status -sb && git log --oneline -5

# 1) commit + push a BRANCH (never main)
git add <paths> && git commit -m "..." && git push origin ci/bootstrap

# 2) find the run and wait for it (gh is NOT on PATH in the agent shell)
GH="/c/Program Files/GitHub CLI/gh.exe"
"$GH" run list --branch ci/bootstrap --limit 1 --json databaseId,status,displayTitle
"$GH" run watch <RUN_ID> --interval 15 --exit-status ; echo "exit=$?"

# 3) read EVERYTHING from the report branch (works with plain git, no token)
git fetch -q origin ci-reports
git show origin/ci-reports:summary.md                 # step OUTCOMES (not the UI's "conclusion")
git show origin/ci-reports:logs/analyze.log
git show origin/ci-reports:logs/test.log | grep -vE "^\s*$" | grep -nE "\[E\]|EXCEPTION CAUGHT|Some tests failed|All tests passed"
git show origin/ci-reports:logs/build_apk.log | grep -nE "^e: |error:|FAILURE|Built "
git show origin/ci-reports:generated/StorageApi.g.kt   # real Pigeon output
```
- PowerShell 5.1 has **no `??`, `&&`, `||`**. Prefer Git Bash for the above.
- A step can show `success` in `gh`/the API while its **outcome** was `failure` (`continue-on-error`). `summary.md` is authoritative.
- When a test log shows several exceptions, the **first** `EXCEPTION CAUGHT` is the cause; later ones cascade.
- Batch fixes: each round-trip is ~5–7 min. Add diagnostics (like `screenTexts(tester)`) *before* a run that might fail.
- Downloading the APK (`gh run download <id> -n vaultbox-debug-apk`) is a file download: **ask the user first** (filename `app-debug.apk`, ~87.5 MB, source GitHub Actions artifact).

## Inspect these files first
1. `lib/features/files/viewmodel/files_view_model.dart` (generation-token load logic — subtle, hard-won)
2. `lib/data/repositories/file_repository_impl.dart` (`copySingle` guards)
3. `lib/domain/value_objects/storage_path.dart` (`parse` vs `child`)
4. `android/app/src/main/kotlin/com/vaultbox/app/storage/SafStorageHostApi.kt` + `MainActivity.kt`
5. `lib/data/services/saf_storage_backend.dart` and `lib/platform/adapters/pigeon_android_storage_host.dart`
6. `.github/workflows/ci.yml`

## Do NOT repeat
- Do **not** try to install Flutter/Android locally or run `flutter` on the user's machine.
- Do **not** run `flutter create .` in the repo (adds a broken `widget_test.dart`); the scaffold is already committed.
- Do **not** re-add `sqlite3_flutter_libs ^0.5.x` (breaks `pub get`).
- Do **not** call `StoragePath.parse` for names you already hold, nor `child` for wire input.
- Do **not** dispose a `TextEditingController` right after `showDialog` returns — use a `StatefulWidget` that owns it.
- Do **not** put `<Override>` type arguments in Riverpod-3 tests; do **not** rely on `material.dart` for Cupertino symbols.
- Do **not** dereference `item!` in catch blocks; do **not** change `loadFirstPage` back to subscription+completer.
- Do **not** pass `FLAG_GRANT_PERSISTABLE_URI_PERMISSION` to `takePersistableUriPermission`.
- Do **not** use `registerForActivityResult` on `FlutterActivity`.
- Do **not** reformat the whole codebase inside a behaviour commit.
- Do **not** push to `main` or open/merge a PR without the user's explicit OK. Do **not** commit the `ci-report/` folder or any secret.
- Do **not** claim "works" for anything not in a green run's logs; label UNTESTED honestly.

## Important constraints
- Every file operation goes through `StorageBackend`; every client path through `StoragePath.parse`; never delete the only copy before the replacement is verified; Recycle Bin by default; never log secrets; streamed I/O only.
- Keep the 5-tab navigation; keep Home thin; no fake-functional controls ("Coming later" placeholders are OK).
- Riverpod 3 rules: constructor-injected family arg, `ref.mounted` after every `await` before writing `state`.
- Git identity is `DevBehindYou`; commit trailers: `Co-Authored-By: <model> <noreply@anthropic.com>`.
- Public repo: never write secrets, tokens, keystores, or personal data into files, logs, or `ci-reports`.

## Definition of done for the next phase
- [ ] User has installed the CI APK and confirmed launch + create/delete/restore on a real phone (or logs of the crash are captured and fixed).
- [ ] `ci/bootstrap` (or successor) merged to `main` with the user's approval; `main` is green.
- [ ] A user can add a file into VaultBox storage and open it.
- [ ] SAF root selectable in onboarding, with a device-verified read/write of a large file (or the chunked fallback implemented and verified).
- [ ] `README.md` and `docs/IMPLEMENTATION_PLAN.md` corrected; this handover updated (SESSION_HISTORY new session entry; CURRENT_STATE refreshed).
