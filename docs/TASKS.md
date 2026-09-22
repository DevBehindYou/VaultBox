# VaultBox — Tasks Left

Everything still open, as of 2026-09-23, grouped by who acts and in what order. Written at the user's
request. Companion files: [EDIT_LOG.md](EDIT_LOG.md), [CHAT_LOG.md](CHAT_LOG.md),
[ROADMAP.md](ROADMAP.md).

State in one line: branch `ci/bootstrap`, last push `2ffdaf0`, **fully green** (942 tests, `flutter
analyze` clean, debug APK builds). M2 (FTP/FTPS) is done and compiled for the first time. Now doing a
full state-management rewrite: Riverpod → BLoC (`flutter_bloc`), at the user's request.

## A. Finish M2 — FTP / FTPS — DONE (2026-09-23, commits `6052175`, `2ffdaf0`)

Every item below was completed and is green on CI. Left here as a record, not a to-do list:

- [x] Fixed the TLS upgrade race in `lib/server/ftp/ftp_session.dart` `_auth` (pause before reply).
- [x] Cross-checked every FTP API call against its real signature — only the TLS upgrade had real bugs (see below).
- [x] Second bug found beyond the stated race: `SecureSocket.secureServer`/`.secure` have no `subscription:` parameter (checked against api.dart.dev) — first CI compile confirmed this. Fixed by pausing the subscription and letting `dart:io` detach the raw socket internally, not passing it as an argument.
- [x] Known TLS-handshake-timeout gap noted in a comment, not built out (per the original acceptance).
- [x] Unit tests added: `ftp_settings_test.dart`, `ftp_paths_test.dart`, `ftp_listing_test.dart`, `root_names_test.dart`, `tls_context_test.dart`.
- [x] Protocol tests added: `ftp_protocol_test.dart` (27 cases — login/lockout, all commands, ACL denial, PORT/cross-address refusal, connection limits).
- [x] TLS tests added: `ftp_tls_test.dart` (explicit/implicit FTPS, PROT C refusal, no-certificate refusal), using a runtime-generated cert via the `openssl` CLI.
- [x] Pushed twice: first compile failed (the `subscription:` bug above), fixed in one batch, second push green — 942 tests.
- [ ] **Still needs the user**: install the new debug APK on the phone and test FTPS from a PC client and the other phone (see section C).

## B. In progress — Riverpod → BLoC rewrite (agent, this session)

Full replace, at the user's explicit request (chose this over a partial/gradual migration after being
told the full-app blast radius and no-local-compiler risk). Plan:

- [ ] `pubspec.yaml`: add `flutter_bloc`, remove `flutter_riverpod`.
- [ ] Core DI (`lib/app/providers.dart`, 71 providers): plain service/repo/use-case `Provider<T>` entries (~50 of them) become `RepositoryProvider`/`MultiRepositoryProvider` — same construction closures, same test override shape, not real BLoC state.
- [ ] The providers a screen actually watches reactively (`StreamProvider`/`FutureProvider` for storage roots, server state/config, TLS fingerprint, admin-exists, accounts, shares, owner account, activity events/transfers/clients, recycle-bin items, root stats, FTP settings) become real Cubits.
  - Non-`autoDispose` ones (roots, server state/config, TLS fingerprint, admin-exists, accounts, shares, owner account) → app-level Cubits, created once at the root, alive for the app's lifetime — matches current always-on caching.
  - `autoDispose` ones (recycle-bin items per root, activity feeds, root stats, FTP settings) → screen-scoped Cubits, created by the screen that needs them, disposed on pop — matches current per-visit lifecycle (this matters most for the activity feeds' polling timers, which must stop when the screen closes).
- [ ] `lib/features/files/viewmodel/files_view_model.dart` (the one real Riverpod `Notifier`) → `FilesCubit`, same method-call shape.
- [ ] Every `ConsumerWidget`/`ConsumerStatefulWidget` (14 files) → plain `StatelessWidget`/`StatefulWidget` using `BlocBuilder`/`context.watch<T>()`/`context.read<T>()`.
- [ ] Every test using `ProviderScope`/`ProviderContainer` overrides (13 files) → `MultiRepositoryProvider`/`MultiBlocProvider` with fakes injected directly.
- [ ] Router (`lib/app/router.dart`) and app bootstrap: swap `ProviderScope` for the BLoC provider tree.
- [ ] Commit locally per feature module; push to CI only at 2-3 checkpoints, not after every file (GitHub Actions quota).

CI reading loop:

```bash
git push origin ci/bootstrap
git fetch -q origin ci-reports
git show origin/ci-reports:summary.md
git show origin/ci-reports:logs/analyze.log
git show origin/ci-reports:logs/test.log
```

(`gh` is at `C:\Program Files\GitHub CLI\gh.exe`, not on the agent's PATH. Steps use `continue-on-error`, so the Actions page can show "success" for a failed step; `summary.md` has the real outcomes. The `dart format (advisory)` step always shows failure and does not gate.)

## B. Next milestones (agent)

- [ ] **M1.5:** Files tab restyle per mockup `files_storage_explorer` (volume cards, search, breadcrumb, sort, rows as cards); restyle the onboarding screens; light/dark visual pass over every screen.
- [ ] **M3 extras**, in this order: auto-stop timer; global read-only mode; IP allow-list; app PIN lock; "server stopped" activity event; notification actions (native); regenerate TLS certificate (native); hotspot information. See [ROADMAP.md](ROADMAP.md) §3.
- [ ] Keep the widget tests in step with each new card or screen (tall test surface, in-memory repositories, override `settingsRepositoryProvider`).

## C. Needs the user

- [ ] **Phone test set-up** (the agent must not do these): create the admin account (password), add a storage location through the system folder picker, start the server and allow the notification permission.
- [ ] **Try FTP from the other phone's file explorer** once M2 is green, and report what the app shows. The Protocols screen has a "How to connect with FTP" guide with the host and port filled in.
- [ ] **Approve each APK download** for a phone test (a download always needs a yes).
- [ ] **Decide on merging:** open a PR `ci/bootstrap → main`, merge directly, or keep waiting. Nothing goes to `main` without an explicit OK.
- [ ] **Decide on stable debug signing** (a debug keystore committed to a public repo so CI APKs update in place instead of needing an uninstall each time).
- [ ] Ask for a handover refresh (`docs/ai-handover/`, `README.md`, `IMPLEMENTATION_PLAN.md`) when wanted; the agent will not do it unprompted.

## D. Housekeeping

- [ ] `docs/ai-handover/`, `README.md` and `docs/IMPLEMENTATION_PLAN.md` are out of date (last refreshed 2026-09-18, before phases 2–6 and the UI overhaul). Refresh only when asked.
- [ ] `dart format (advisory)` reports failure on every run. Either do one dedicated reformat commit and then enforce it, or remove the step.
- [ ] From the older list (verify still true): pin `runs-on: ubuntu-24.04` before 2026-10-19; add `flutter test --coverage`; move to `--fatal-infos`; bump `flutter_lints` to 6.x.
- [ ] Debug APKs are signed with a different key per CI run: always `adb uninstall com.vaultbox.app` before installing a newer one (this wipes app data on the phone).

## E. Carried over from `docs/ai-handover/PENDING_TASKS.md`

Status was **not re-verified** for this list; check the code before starting any of them.

- [ ] Rename and file-details entry points in the Files UI.
- [ ] Recycle Bin: show the right icon for folders (store the entry type in `RecycleItem`); record sizes on recycle; confirm the 30-day purge sweep really runs.
- [ ] Transfer engine with bounded concurrency, progress and cancel.
- [ ] Widget tests for onboarding, the shell/router first-run redirect, the destination picker, the conflict dialog and the Recycle Bin.
- [ ] Split the overloaded `StorageDisconnectedFailure` into distinct failures.
- [ ] Log when a listing skips an unrepresentable name; index-backed paging; SAF document-id cache.
- [ ] Launcher icon; release build configuration (signing, R8 rules, release APK in CI).
- [ ] Validate SAF byte I/O on a device for a >500 MB file and a cancelled transfer; fall back to chunked streaming over an `EventChannel` if `/proc/self/fd` re-open fails.

## F. Known risks and open questions

| Risk | Note |
|---|---|
| FTP code never compiled or run | First CI run will likely find compile errors; budget one fix batch. |
| Self-signed certificate | FTP clients and the browser will warn. The fingerprint is shown in the app so it can be checked. Some clients that reject self-signed certificates may need plain FTP on a trusted network. |
| Passive-port range (default 50000–50050) | Routers, firewalls and phone hotspots between the two devices must allow it. |
| Foreground service on aggressive OEMs | The user's phone is a Xiaomi (MIUI); battery managers may kill the server. Needs an OEM-lab pass. |
| SAF large-file I/O | Unproven on a device (see section E). |
| Android background limits | `START_NOT_STICKY`: the server does not restart itself after being killed. |
| Everything is uncommitted | A disk problem would lose the FTP work. Committing locally (not pushing) is safe under the push rules; do that once the review in section A is done. |
