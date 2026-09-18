# Commands and Logs

## Where logs live
- **Latest CI run:** branch `ci-reports` (force-pushed each run): `summary.md`, `logs/{versions,scaffold,pub_get,build_runner,pigeon,format,analyze,test,build_apk}.log`, `generated/{StorageApi.g.kt,storage_api.g.dart}`, `pubspec.lock`, `android-scaffold/` (only when generated).
- Older runs are gone from that branch (force-push). Their essential content is transcribed in ERRORS_AND_FIXES.md. Run pages: `https://github.com/DevBehindYou/VaultBox/actions/runs/<id>`.

| Run | Id | Commit | Result |
|---|---|---|---|
| #1 | 35363154349 | `36d2abc` | pub get FAILED (Error 1) |
| #2 | 35363443062 | `3df259f` | baseline: analyze 5 errors, tests won't compile, APK fails on Dart errors |
| #3 | 35364246742 | `6d032c3` | analyze OK, **APK OK**, 3 tests fail |
| #4 | 35365194176 | `87673b9` | 3 tests fail (reload semantics, dialog) |
| #5 | 35366008573 | `89e2b38` | **green**, 100 tests |
| #6 | 35366984098 | `4bd1af5` | **green**, 108 tests, Kotlin in APK |
| #7 | 35368040933 | `fc5f2f4` | **green**, 108 tests (docs + `paths-ignore`) |

## Reading CI (Git Bash)
```bash
GH="/c/Program Files/GitHub CLI/gh.exe"          # gh is not on PATH for the agent
"$GH" auth status                                # logged in as DevBehindYou (keyring)
"$GH" run list --branch ci/bootstrap --limit 3
"$GH" run watch <ID> --interval 15 --exit-status
git fetch -q origin ci-reports && git show origin/ci-reports:summary.md
"$GH" api repos/DevBehindYou/VaultBox/actions/runs/<ID>/artifacts --jq '.artifacts[]|"\(.name) \(.size_in_bytes)"'
```
Anonymous (no gh) status poll used early on: `GET https://api.github.com/repos/DevBehindYou/VaultBox/actions/runs?branch=ci/bootstrap` (60 req/h). A helper script was kept in the agent scratchpad (not in the repo).

## Commands the CI runs (mirror them mentally; do NOT run locally)
```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs      # Drift -> app_database.g.dart
mkdir -p lib/platform/pigeon android/app/src/main/kotlin/com/vaultbox/app/pigeon
dart run pigeon --input pigeons/storage_api.dart              # -> storage_api.g.dart + StorageApi.g.kt
dart format --output=none --set-exit-if-changed lib test pigeons   # advisory (fails)
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test --reporter expanded
flutter build apk --debug
```

## Git commands used
```bash
git switch -c ci/bootstrap
git add <explicit paths>            # design folder deliberately excluded from the first commit
git commit -F - <<EOF ... Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com> EOF
git push -u origin ci/bootstrap
git fetch origin ci-reports ; git show origin/ci-reports:<path>
git stash push -m wip-code-fixes ; git stash pop   # to isolate the pubspec fix for a clean baseline run
```

## Environment probes (Windows)
`Get-Command flutter,dart,java,adb,git,gradle,node` → only java (21.0.1), adb, git, node present.
`adb devices` → empty. `Get-PSDrive` → C: 9.3 GB free, D: 1.4 GB. Android SDK at `%LOCALAPPDATA%\Android\Sdk` (platforms 35/36, build-tools 35/36, platform-tools; no cmdline-tools/NDK/emulator; `licenses/android-sdk-license` present).
`winget install --id GitHub.cli` was run **by the user**.

## Important log excerpts (verbatim, trimmed)

**pub get, run #1**
```text
Because vaultbox depends on drift_flutter ^0.3.1 which depends on sqlite3_flutter_libs ^0.6.0+eol,
sqlite3_flutter_libs ^0.6.0+eol is required.
So, because vaultbox depends on sqlite3_flutter_libs ^0.5.24, version solving failed.
```
**analyze, run #2** (11 issues)
```text
error • The method 'CupertinoPageTransitionsBuilder' isn't defined for the type 'AuroraTheme' • lib/core/design/aurora_theme.dart:148:31
error • The argument type 'bool Function(Object)' can't be assigned to the parameter type 'bool Function(dynamic)?' • lib/data/services/direct_path_storage_backend.dart:121:17
error • The name 'Override' isn't a type … • test/features/files_screen_test.dart:47:19  (and files_view_model_test.dart:41:19)
warning • 'avoid_returning_null_for_future' was removed in Dart '3.3.0' • analysis_options.yaml:25:7
```
**tests, run #3/#4**
```text
Expected: ['taken.txt']   Actual: ['taken.txt', 'taken.txt']
A TextEditingController was used after being disposed.   (files_screen.dart:248, TextField)
'_dependents.isEmpty': is not true.   (cascade)
screen: []
```
**run #5/#6**
```text
analyze:  No issues found! (ran in 15.2s)
test:     00:04 +108: All tests passed!
apk:      ✓ Built build/app/outputs/flutter-apk/app-debug.apk
```
**Pigeon 29.0.2 Kotlin shape (verified)**
```kotlin
interface AndroidStorageApi { suspend fun openDocumentTree(): SafTreeMessage? ; suspend fun listChildren(...): List<SafEntryMessage> ; ... suspend fun openFileDescriptor(...): Long
  companion object { fun setUp(binaryMessenger: BinaryMessenger, api: AndroidStorageApi?, messageChannelSuffix: String = "") } }
// generated handlers: CoroutineScope(Dispatchers.Main).launch { ... }      FlutterError(code, message, details): RuntimeException
```
**Runner notice:** `The ubuntu-latest label will migrate to Ubuntu 26 beginning October 19, 2026.`

## Deployment commands
None.

## Secrets
Required: **none.** (`GITHUB_TOKEN` is auto-injected per run.) The `gh` token lives in the user's Windows keyring — *VALUE NOT STORED FOR SECURITY*. Nothing secret is in this repo, this handover, or `ci-reports`.
