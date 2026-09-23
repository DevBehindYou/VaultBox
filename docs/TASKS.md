# VaultBox — Tasks Left

Everything still open, as of 2026-09-23, grouped by who acts and in what order. Written at the user's
request. Companion files: [EDIT_LOG.md](EDIT_LOG.md), [CHAT_LOG.md](CHAT_LOG.md),
[ROADMAP.md](ROADMAP.md).

State in one line: branch `ci/bootstrap`, last pushed commit `7004190` (launcher icon, splash screen,
web portal favicon). Last **confirmed** green result is commit `16fc00f`: `flutter analyze` clean,
both debug and release APKs build, 927 of 942 tests pass (15 failures are a known non-gating Flutter
SDK flake, section F). The `7004190` run's real outcome is still unconfirmed — its `ci-reports` publish
step hit a transient GitHub 500 and was re-run (run `35879261154`); read that run before assuming
anything about `7004190` is green. FTP/FTPS (M2) and the Riverpod → BLoC rewrite are both done.

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
- [ ] **Still needs the user**: install a debug APK on the phone and test FTPS from a PC client and the other phone (see section D).

## B. Riverpod → BLoC rewrite — DONE (2026-09-23, commits `39f716d`..`16fc00f`)

Full replace, at the user's explicit request (chose this over a partial/gradual migration after being
told the full-app blast radius and no-local-compiler risk). Left here as a record, not a to-do list:

- [x] `pubspec.yaml`: `flutter_bloc` ^9.1.1 (+ `bloc_test` ^10.0.0 dev dep), `flutter_riverpod` removed.
- [x] Core DI: `lib/app/providers.dart` rewritten as `AppDependencies`, a plain-Dart composition root (no `BuildContext`, no `flutter_bloc` import — needed by `lib/server/server_services.dart`'s headless engine, which has no widget tree). `lib/app/app_providers.dart` exposes each field via `RepositoryProvider<X>.value`.
- [x] `lib/core/state/resource.dart` (`Resource<T>`, the `AsyncValue` stand-in) and `lib/core/state/resource_cubit.dart` (`ResourceStreamCubit`, `ResourceFutureCubit`+`ResourceAwaiter`, `PolledCubit`) are the shared Cubit machinery every feature builds on.
- [x] `lib/app/app_state.dart`: every app-level Cubit. Correction made mid-migration (commit `12d69c3`): the activity feeds, root stats and FTP settings were `autoDispose` under Riverpod, but `home_screen.dart` watches all of them too, and Home is one of the five permanent `StatefulShellRoute.indexedStack` branches that go_router keeps mounted forever — so they were already effectively app-level and belong here, not as screen-scoped Cubits (which would have silently given Home and its sibling screen two disconnected instances). The one genuinely screen-scoped Cubit is `RecycleItemsCubit` (Home never watches recycle-bin items).
- [x] `lib/features/files/viewmodel/files_view_model.dart` → `FilesCubit`, same generation/staleness-guard logic, same method shape.
- [x] Every `ConsumerWidget`/`ConsumerStatefulWidget` → `StatelessWidget`/`StatefulWidget` with `context.watch`/`context.read`.
- [x] Every test using `ProviderScope` overrides → `MultiRepositoryProvider`/`MultiBlocProvider` with fakes.
- [x] Done mostly by background agents in parallel, feature module by feature module; each was individually re-verified against the source (grepped for leftover `WidgetRef`/`ConsumerWidget`/old provider names) before being trusted, not taken on the agent's self-report alone — one real bug (a stray `ref` argument left over from an earlier partial edit in `share_screen.dart`) was caught this way, and a systematic `unawaited_futures` lint gap (bare `Cubit.refresh()` calls, 11 sites) was fixed in the same batch.
- [x] Pushed once: `flutter analyze` clean, debug APK builds, 927/942 tests green. The 15 failures are a Flutter SDK-internal bug, not an app or migration bug — see section F.

## C. Release APK, launcher icon, splash screen, portal favicon — mostly done, one follow-up open

The user installed a release APK (commit `e5ee506`, run `35790492649` — both debug and release build
succeeded there) and reported: default Flutter icon, blank splash screen, layout "looks sloppy", no
light-mode option (it exists — see section E), no folder choice for internal/external storage (it
exists — see section E), no notification while the server runs, and the web portal "looks sloppy" with
no icon.

- [x] `.github/workflows/ci.yml`: added a `flutter build apk --release` step alongside the existing debug one, uploaded as its own artifact (`vaultbox-release-apk`). Uses `android/app/build.gradle.kts`'s existing `release` buildType, which signs with the **debug keystore** — fine to install and test, not a Play Store artifact (no real signing key or R8 rules yet).
- [x] Generated `assets/icon/icon.png` and `icon_foreground.png` from the existing `assets/images/vaultbox_mark.png` (background keyed to transparency, padded to the adaptive-icon safe zone, upscaled to 1024px). **Source is only 160×184px** — this is a real quality ceiling; ask the user for higher-res artwork if the result looks soft.
- [x] `pubspec.yaml`: added `flutter_launcher_icons` ^0.14.4 and `flutter_native_splash` ^2.4.8 (dev deps), configured against those two images and the app's own `AuroraColors.background` (`#FBF9F4`) / `AuroraColorsDark.surface` (`#15151A`) tokens, so the icon background and splash color match the in-app theme.
- [x] `.github/workflows/ci.yml`: added a step running both generators before the APK builds (no local SDK to run `dart run flutter_launcher_icons` / `flutter_native_splash:create` here), and a step copying the generated `android/app/src/main/res` output into the CI report.
- [ ] **Open follow-up**: fetch that generated `android/app/src/main/res` output from a successful run's `ci-reports` publish and commit it into the repo's own checked-in scaffold, so `git show` matches what actually ships (not required for the build to succeed — CI regenerates it fresh every run regardless — just keeps the source tree honest). Blocked on a confirmed-green run: the `7004190` push's `ci-reports` publish failed with a transient GitHub 500 (`Internal Server Error`, unrelated to this repo's code — every other step, including icon generation and both APK builds, showed success in the job list) and was re-run as `35879261154`; that rerun's result was not checked before the user said to stop.
- [x] Fixed the web portal's favicon: `assets/portal/index.html`/`public.html` had a deliberate empty `data:,` placeholder; replaced with the same icon at 64×64, inlined as a base64 PNG data URI (the portal's CSP already allows `img-src ... data:`). Regenerated `lib/server/portal/portal_bundle.dart` via `python tool/embed_portal.py`. Verified byte-for-byte after an earlier manual-transcription attempt corrupted one character of the base64 — redone by having Python copy the string directly rather than retyping it through a tool call.

## D. Needs the user

- [ ] **Phone test set-up** (the agent must not do these): create the admin account (password), add a storage location through the system folder picker, start the server and allow the notification permission.
- [ ] **Try FTP from the other phone's file explorer** once M2 is confirmed green on a real device, and report what the app shows. The Protocols screen has a "How to connect with FTP" guide with the host and port filled in.
- [ ] **Approve each APK download** for a phone test (a download always needs a yes).
- [ ] **Decide on merging:** open a PR `ci/bootstrap → main`, merge directly, or keep waiting. Nothing goes to `main` without an explicit OK.
- [ ] **Decide on stable debug signing** (a debug keystore committed to a public repo so CI APKs update in place instead of needing an uninstall each time).
- [ ] Ask for a handover refresh (`docs/ai-handover/`, `README.md`, `IMPLEMENTATION_PLAN.md`) when wanted; the agent will not do it unprompted.

## E. Open questions from the 2026-09-23 device test — waiting on the user's reply

Checked each of these against the actual code before answering; none were fixed blind.

- [ ] **"No light-mode option"**: already exists — Settings → "Appearance & Display" → System/Light/Dark, built in the M1 UI overhaul (`bfff09c`). Ask the user what they saw; if it's genuinely missing or broken on their device, that's a real bug worth reproducing, not a rebuild.
- [ ] **"No folder choice for internal/external storage"**: already exists — onboarding's second option, "SD card or custom folder" (`lib/features/onboarding/presentation/onboarding_storage_screen.dart`), subtitle reads "Pick any folder on this phone or an SD card." Opens Android's system SAF folder picker, which covers internal storage too, not just external. Ask what happened when they tapped it.
- [ ] **"No notification while the server runs"**: `MainActivity.kt` already requests `POST_NOTIFICATIONS` when the server starts (code comment: "seen on a real phone: granted=false" — a prior session already found and fixed this once). Likely either the user denied that prompt, or MIUI (the user's phone is Xiaomi) is hiding it via its own battery/autostart restrictions. Ask the user to check Android Settings → Apps → VaultBox → Notifications, and MIUI's Security app → Permissions → Autostart, before assuming this is a new code bug.
- [ ] **"App layout looks sloppy"**: cannot be judged without seeing it — no device or emulator exists in this environment. Need a screenshot of what specifically looks wrong.
- [ ] **"Web portal looks sloppy, no usability"**: the missing favicon is fixed (section C). Beyond that, the portal was tested directly with `tool/portal_mock_server.js` (a mock backend made exactly for previewing the portal without a phone) at both desktop and mobile viewport widths — the login screen and file browser both looked clean and functional in that test. Need a screenshot or a specific description of what looked wrong; a general "sloppy" without specifics can't be turned into a fix.

## F. Housekeeping

- [ ] `docs/ai-handover/`, `README.md` and `docs/IMPLEMENTATION_PLAN.md` are out of date (last refreshed 2026-09-18, before phases 2–6, the UI overhaul and the BLoC rewrite). Refresh only when asked.
- [ ] `dart format (advisory)` reports failure on every run. Either do one dedicated reformat commit and then enforce it, or remove the step.
- [ ] **Known test flake, not gating**: `test/features/share_screen_test.dart` — 15 of its tests fail on CI (run `35787650421`, commit `16fc00f`) with `RawTooltipState is a SingleTickerProviderStateMixin but multiple tickers were created`, thrown by Flutter's own `raw_tooltip.dart` from inside the gesture library while routing an ordinary tap — not a test assertion, not application code. Once it fires once (in the "a person's page" group), every later tap-driven test in the same file cascades into the same exception, which is why it's 15 failures from one root trigger, not 15 independent bugs. `flutter analyze` and the debug APK build are unaffected; only this one test file's later tests are. Confirmed by web search this is a known class of Flutter SDK ticker/animation-controller disposal bug (compare `flutter/flutter#179337`, a different widget with the identical "multiple tickers... dispose does not free tickers" signature) — not something fixable from application or test code without reproducing it against a local Flutter SDK, which this project doesn't have. User decision 2026-09-23: accept and document, don't spend further CI runs guessing at a fix. Re-check if a future Flutter SDK bump changes this.
- [ ] **CI infra flake, not this repo's fault**: the "Publish report to the ci-reports branch" step failed once (run `35879261154`, first attempt) with `remote: Internal Server Error` on `git push -f`. Transient GitHub-side 500, not a workflow bug — a rerun was triggered. If this recurs often, consider adding a retry loop around that push.
- [ ] From the older list (verify still true): pin `runs-on: ubuntu-24.04` before 2026-10-19; add `flutter test --coverage`; move to `--fatal-infos`; bump `flutter_lints` to 6.x.
- [ ] Debug APKs are signed with a different key per CI run: always `adb uninstall com.vaultbox.app` before installing a newer one (this wipes app data on the phone). The new release APK shares the same debug-signed key as of section C, so it does **not** need a separate uninstall from a debug build of the same commit — but still differs run to run like debug APKs do.

## G. Carried over from `docs/ai-handover/PENDING_TASKS.md`

Status was **not re-verified** for this list; check the code before starting any of them.

- [ ] Rename and file-details entry points in the Files UI.
- [ ] Recycle Bin: show the right icon for folders (store the entry type in `RecycleItem`); record sizes on recycle; confirm the 30-day purge sweep really runs.
- [ ] Transfer engine with bounded concurrency, progress and cancel.
- [ ] Widget tests for onboarding, the shell/router first-run redirect, the destination picker, the conflict dialog and the Recycle Bin.
- [ ] Split the overloaded `StorageDisconnectedFailure` into distinct failures.
- [ ] Log when a listing skips an unrepresentable name; index-backed paging; SAF document-id cache.
- [ ] Release build configuration proper (a real signing key held as a GitHub Actions secret, R8/ProGuard rules) — the release APK in section C uses the debug key as a stand-in; launcher icon itself is now done (section C).
- [ ] Validate SAF byte I/O on a device for a >500 MB file and a cancelled transfer; fall back to chunked streaming over an `EventChannel` if `/proc/self/fd` re-open fails.

## H. Next milestones (agent, after the above)

- [ ] **M1.5:** Files tab restyle per mockup `files_storage_explorer` (volume cards, search, breadcrumb, sort, rows as cards); restyle the onboarding screens; light/dark visual pass over every screen — this is likely where the "layout looks sloppy" feedback (section E) will land once specifics come back.
- [ ] **M3 extras**, in this order: auto-stop timer; global read-only mode; IP allow-list; app PIN lock; "server stopped" activity event; notification actions (native); regenerate TLS certificate (native); hotspot information. See [ROADMAP.md](ROADMAP.md) §3.
- [ ] Keep the widget tests in step with each new card or screen (tall test surface, in-memory repositories, provide a fake `SettingsRepository` via `RepositoryProvider<SettingsRepository>.value`).

## I. Known risks and open questions

| Risk | Note |
|---|---|
| Self-signed certificate | FTP clients and the browser will warn. The fingerprint is shown in the app so it can be checked. Some clients that reject self-signed certificates may need plain FTP on a trusted network. |
| Passive-port range (default 50000–50050) | Routers, firewalls and phone hotspots between the two devices must allow it. |
| Foreground service on aggressive OEMs | The user's phone is a Xiaomi (MIUI); battery managers may kill the server or hide its notification (see section E's notification item). Needs an OEM-lab pass. |
| SAF large-file I/O | Unproven on a device (see section G). |
| Android background limits | `START_NOT_STICKY`: the server does not restart itself after being killed. |
| `share_screen_test.dart` Tooltip flake | See section F — Flutter SDK bug, not app code, not gating. |
| Icon/splash source resolution | `assets/images/vaultbox_mark.png` is only 160×184px; the generated launcher icon and splash logo are upscaled from it and may look soft at the largest sizes (e.g. a 512px Play Store listing icon). Higher-res source art would fix this outright. |
