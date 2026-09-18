# Technical Decisions

Two groups: **inherited** (made by earlier sessions, recorded in `docs/IMPLEMENTATION_PLAN.md`;
still ACTIVE unless noted) and **this session** (2026-09-18).

## This session

### D1 — Verify with GitHub Actions, never locally
- **Decision:** All compile/analyze/test/APK verification runs in `.github/workflows/ci.yml`.
- **Reason:** User statement: not enough storage for Flutter/Dart **or** the Android SDK. C: had 9.3 GB free, D: 1.4 GB.
- **Alternatives:** local Flutter install (declined by the user); Dart-only install (would still not run Flutter tests); WSL/Docker (needs more disk).
- **Consequences:** every experiment costs a push and ~5–7 min. Batch fixes; use the `ci-reports` branch to read everything at once.
- **Status:** ACTIVE (user constraint).

### D2 — Workflow never stops at the first failure
- **Decision:** each verification step is `continue-on-error: true`; a final **Gate** step fails the job if any gated step's *outcome* is `failure`.
- **Reason:** a round-trip is minutes; the first run needs the *whole* picture (pub get → codegen → analyze → test → APK).
- **Gotcha:** with `continue-on-error`, a step's `conclusion` shows `success` in the UI/API while its `outcome` is `failure`. **Read `summary.md` (outcomes), not the step list.**
- **Status:** ACTIVE.

### D3 — Results are published to a `ci-reports` branch
- **Decision:** the last step force-pushes `ci-report/` (logs, summary, generated Pigeon output, pristine Android scaffold) to orphan branch `ci-reports` using `GITHUB_TOKEN` (`permissions: contents: write`).
- **Reason:** repo was private at first; logs/artifacts need auth. `git fetch origin ci-reports` works with the user's existing Git Credential Manager. Kept even after the repo went public and `gh` was installed because it needs no token and shows *all* logs in one place.
- **Read with:** `git fetch origin ci-reports && git show origin/ci-reports:summary.md` (also `logs/analyze.log`, `logs/test.log`, `logs/build_apk.log`, `generated/*`).
- **Consequences:** latest run only (force-push); branch is automation-owned, safe to delete. No secrets are ever written there.
- **Status:** ACTIVE.

### D4 — Generate the Android scaffold in CI, into a scratch dir
- **Decision:** `flutter create --platforms=android --org com.vaultbox --project-name app $RUNNER_TEMP/scaffold`, then `cp -rn` only `android/`.
- **Reason:** running `flutter create .` in the repo would also drop a default `test/widget_test.dart` that references a counter app and breaks `flutter test`; the README (rightly) warned against hand-typing a Gradle/AGP/Kotlin triple.
- **Result:** Gradle 9.3.1, Kotlin 2.4.0, namespace/applicationId `com.vaultbox.app`. Committed after run #2 so builds are reproducible. The CI scaffold step now skips itself (it detects `android/build.gradle.kts`).
- **Status:** ACTIVE.

### D5 — Baseline first, fixes second
- **Decision:** run #2 was deliberately the *unmodified* previous-session code (plus only the pubspec fix) to learn what actually fails; my behaviour fixes were stashed until then.
- **Reason:** attribution — otherwise a failing test could be either the old code or my change.
- **Status:** DONE.

### D6 — `StoragePath.child()` is a literal append, not a parse
- **Decision:** `child(name)` validates one literal name (no decode, no trim; rejects empty/blank, `.`, `..`, `/`, `\`, control chars, `X:` drive-letter prefixes) and appends it. `parse()` keeps wire semantics.
- **Reason:** the old `child()` delegated to `parse()`, so real names were rewritten (`100%25.txt`→`100%.txt`, `%2F`→`/`).
- **Alternatives:** keep decode and re-encode names on the way out (rejected: every backend would need to agree on encoding; error-prone).
- **Consequences:** protocol handlers **must** call `parse` on client input and only use `child` for names they already hold. Names containing `\` or `/` cannot be represented and are *skipped* in listings (logged nowhere yet).
- **Status:** ACTIVE.

### D7 — Two-layer guard against destructive Replace
- **Decision:** (1) use cases skip same-path copy/move (`Already in this folder` / `Source and destination are the same`); (2) `FileRepositoryImpl.copySingle` throws `InvalidOperationFailure` when the target is inside/equal to the source, or (Replace) the source is inside the target.
- **Reason:** Replace = delete target then copy; if target ⊇ source the delete destroys the only copy.
- **Alternative:** make Replace write-to-temp-then-swap (not possible generically on SAF). Deferred.
- **Status:** ACTIVE.

### D8 — Hide `.vaultbox` at the root; move app storage to `<documents>/storage`
- **Reason:** `.vaultbox/recycle` is bookkeeping (deleting it breaks restore); the documents dir also holds `vaultbox.sqlite`.
- **Status:** ACTIVE. (An existing install from an earlier build would keep its old root — none exist; the app never ran.)

### D9 — Pigeon HostApi methods are all `@async`
- **Decision:** annotate all 10 methods of `AndroidStorageApi` with `@async`.
- **Reason:** a synchronous HostApi method cannot wait for `ACTION_OPEN_DOCUMENT_TREE`'s result; also keeps ContentResolver work off the platform main thread.
- **Consequence:** generated Kotlin uses `callback: (Result<T>) -> Unit`; `SafStorageHostApi.kt` must be rewritten against it (pending).
- **Status:** TEMPORARY until reconciled against generated code.

### D10 — Removed the direct `sqlite3_flutter_libs` dependency
- **Reason:** `drift_flutter ^0.3.1` requires `sqlite3_flutter_libs ^0.6.0+eol`; a direct `^0.5.24` pin made `pub get` fail (CI run #1).
- **Status:** ACTIVE.

### D11 — Do not reformat the codebase yet
- `dart format --set-exit-if-changed` reports nearly every file as changed (Dart 3.13 formatter style). Left advisory to avoid a giant noisy diff mixed with behaviour changes. Do it as one dedicated commit.
- **Status:** REVISIT.

### D12 — Kept `flutter_lints ^5.0.0` (6.0.0 exists)
- Avoid new-lint noise while there are real errors to fix. **Status:** REVISIT.

## Inherited (from docs/IMPLEMENTATION_PLAN.md — external doc set not available to verify)

| ID | Decision | Status |
|---|---|---|
| ADR-004 | One `StorageBackend` interface; no protocol owns filesystem logic | ACTIVE |
| ADR-006 | Android Foreground Service (not the Activity) owns server lifecycle | ACTIVE (unbuilt) |
| ADR-003 | WebDAV over HTTPS is the primary mountable protocol | ACTIVE (unbuilt) |
| ADR-009 | FTPS optional & gated; plain FTP off; SFTP post-MVP | ACTIVE (unbuilt) |
| ADR-011 | One item's failure never aborts a batch | ACTIVE |
| ADR-012 | Recycle Bin is the default delete; permanent delete explicit | ACTIVE |
| — | MVVM + Riverpod (manual providers, no codegen) + go_router | ACTIVE |
| — | Drift for metadata; never large files | ACTIVE |
| — | No `freezed`/`json_serializable` until toolchain proven | REVISIT (toolchain now proven in CI) |
| — | Home stays thin (6 questions), not the mockup's dashboard | ACTIVE |
| — | 80 mockups consolidate to 5 tabs; Vault/Users/etc. are sub-destinations | ACTIVE |
