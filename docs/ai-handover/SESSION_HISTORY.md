# Session History

## Session 1 — 2026-09-18

**Objective (user):** "Analyze VaultBox project's every file and start building the app carefully and accordingly," plus a full AI-agent handover protocol.

### Timeline of meaningful events

1. **Analysis.** Read every source file (`lib/` 58 files, `test/` 7, `pigeons/`, Kotlin draft, `pubspec`, `analysis_options`, README, IMPLEMENTATION_PLAN, Aurora `DESIGN.md`, UI spec headings). Sampled — did not visually review — the 80 mockups. Found, by inspection: same-folder Replace data loss; `StoragePath.child` decoding real names; null `item!` in catch blocks; DB file inside the file root; `.vaultbox` visible; a `@HostApi` spec with a synchronous `openDocumentTree`; and that the README's "never compiled" was literally true.
2. **Toolchain check.** No Flutter/Dart on the machine (Java 21, partial Android SDK, no device). Network to Google/pub.dev works. Discovered current stable Flutter **3.47.4** (Dart 3.13.3); Windows zip = 1,842 MB; only 9.3 GB free on C:.
3. **Asked permission to download the SDK.** **User correction:** *no storage for Flutter/Dart or Android SDK — use a GitHub workflow.* → Decision D1.
4. **Preflight (read-only network):** all pubspec packages exist; action majors current (`checkout@v7`, `setup-java@v6`, `upload-artifact@v7`, `flutter-action@v2`); `flutter 3.47.4` in the Linux manifest; repo initially **private** (anonymous API 404) so a `ci-reports` git branch was chosen as the log channel.
5. **User made the repo public**, then **installed the GitHub CLI** and completed `gh auth login` (HTTPS, browser flow) themselves. The user also **committed and pushed everything to `main` (`37f1d60`)** mid-session — the agent adapted (branch `ci/bootstrap` from it).
6. **Run #1** (workflow only): `pub get` failed → project could never have resolved dependencies. Fixed (Change 2).
7. **Run #2 (baseline of the untouched code):** pub get, build_runner, pigeon OK; analyze 5 errors; test compile errors; APK failed on the same Dart errors — proving the Android scaffold + Gradle toolchain worked. Scaffold committed.
8. **Run #3:** analyze clean, **APK builds**, 97/100 tests pass. 3 failures → behaviour bugs (duplicate rows).
9. **Run #4:** duplicates fixed but a superseded reload returned early (agent's own regression, caught by the agent's own new test); widget tests showed `screen: []`.
10. **Run #5 — first fully green** (100 tests): root causes were the disposed `TextEditingController` (real bug) and the reload race.
11. **SAF bridge:** read real Pigeon output → `suspend fun`, `Dispatchers.Main`, `FlutterActivity` ≠ `ComponentActivity`, illegal persistable flag in the draft. Rewrote Kotlin + `MainActivity` + Dart adapter (+8 tests).
12. **Run #6 — green** (108 tests, APK includes Kotlin).
13. Wrote this handover; committed with a workflow `paths-ignore` for docs. **Run #7 (`fc5f2f4`) green.**

14. **User connected a rooted phone with USB debugging** and asked the agent to check the app on it. Agent: `adb devices` (read-only) -> Android 14/arm64/40 GB free -> downloaded the CI APK (`gh api .../artifacts/<id>/zip`, 87.5 MB, to the scratchpad) -> verified the package with `aapt2` -> `adb install` -> launched -> **drove the whole flow with screenshots** -> on-disk checks with `run-as` (no root) -> cold-restart persistence.
15. **Results:** launches and works end-to-end; found a **dark-mode selected-row contrast bug** (fixed in `11720c5`, CI green, 111 tests, re-verified on the phone) and the **debug-signing mismatch** (worked around by uninstalling/reinstalling the test app; proper fix awaits the user's OK). App left installed on the phone.
16. **User:** 'that's enough testing on mobile ... lets build and move to the next phases.' -> device testing paused; next phases built with CI as the loop (see later entries / `git log`).

### User corrections preserved
| # | Correction | Effect |
|---|---|---|
| 1 | "I don't have enough storage… use alt … like GitHub workflow to build and test." | No local SDK, ever. CI is the loop. |
| 2 | "I have made the repo public." | Anonymous API status reads work; visibility no longer blocks. |
| 3 | 'I have my phone with Rooted USB debugging and you check the app with my phone if I connect it.' | Agent may install/drive the app over adb while the phone is connected; keep reads scoped to the app (logcat by pid, `run-as`), never touch other apps/data, don't use root to alter the device. |
| 4 | 'that's enough testing on mobile ... build and move to the next phases.' | Stop device testing for now; proceed with Phase 1 remainder / Phase 2 via CI. |
| — | (User actions) installed `gh`, authenticated it, pushed `main`, connected the phone. | `gh` available (full path); `main` moved under the agent. |

### Findings that were *not* bugs but matter
- CI step "conclusion" hides failed outcomes under `continue-on-error`.
- `dart format` flags every file.
- Riverpod 3 / Flutter 3.47 API shifts (`Override`, Cupertino export, `handleError` typing).
- The plan references a 29-file external doc set not in the repo.

### Result at end of session
Green CI on `ci/bootstrap`; smoke-tested on a real phone (1 device); handover written; **not merged to `main`**; SAF path still unexercised on a device.

### Pending at end of session
See `PENDING_TASKS.md` (P0: land the branch + real-device smoke test).

---
## Session Timeline (template for future sessions)

### YYYY-MM-DD — Session N
**Objective** … **Completed** … **Problems discovered** … **Pending** …
