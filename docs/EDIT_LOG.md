# VaultBox — Edit Log

A chronological record of what was changed in the repository, by milestone, with the commit that
carries each change. Written on 2026-09-21 at the user's request. Companion files:
[CHAT_LOG.md](CHAT_LOG.md) (what was asked and decided), [ROADMAP.md](ROADMAP.md) (where the project
goes) and [TASKS.md](TASKS.md) (what is left).

## Where things stand

| | |
|---|---|
| Branch | `ci/bootstrap` (never merged to `main`; `main` still holds the baseline that could not compile) |
| Last pushed commit | `7004190` — launcher icon, splash screen, web portal favicon. |
| Last **confirmed** green commit | `7004190` (via rerun `35879261154`) — `flutter analyze` clean, both debug and release APKs build, icon/splash generation succeeded, 927/942 tests pass — 15 failures are the known Flutter SDK Tooltip/ticker bug in `share_screen_test.dart`, not gating (see `TASKS.md` section F) |
| Working tree | clean, fully committed |
| Database schema | Drift v6 |
| Toolchain | Flutter 3.47.4 / Dart 3.13.3, built and tested only on GitHub Actions (the user cannot install the SDKs locally) |

Timestamps below are dates from `git log`. The older handover package in `docs/ai-handover/` was last
refreshed on 2026-09-18 and is deliberately stale (the user asked for it to be refreshed only on
request); this log supersedes it for anything after that date.

---

## Foundation and Phase 1 — 2026-09-18

Built the storage layer and local file manager, then bootstrapped CI because no toolchain exists locally.

| Commit | Change |
|---|---|
| `ba4cc10`, `37f1d60` | Initial commit; the user pushed the whole tree to `main` mid-session. |
| `36d2abc` | `.github/workflows/ci.yml`: the workflow **is** the build machine. Every step runs with `continue-on-error`, a final gate fails the job, and logs plus generated files are force-pushed to a `ci-reports` branch so they can be read with plain `git fetch`. |
| `3df259f` | Dropped a direct `sqlite3_flutter_libs` pin that broke `pub get`. |
| `1e5c4c9` | Committed the generated Gradle/Android scaffold (Flutter 3.47.4 template). |
| `6d032c3` | Fixed the compile errors from CI run #2, added data-loss guards (same-folder Replace could destroy a file), literal path names (`StoragePath.child` no longer decodes real names). |
| `87673b9`, `89e2b38` | Files screen: overlapping reloads duplicated rows and could hang; dialog controller used after dispose. |
| `4bd1af5` | Kotlin SAF bridge reconciled with the real Pigeon output (`suspend fun`, `Dispatchers.IO` hop, persistable-flag bug that would have crashed, `startActivityForResult` picker) plus the Dart adapter. |
| `fc5f2f4`, `d7b93d5`, `53bcae4` | AI handover package in `docs/ai-handover/` (14 files); CI skips docs-only pushes (`paths-ignore: docs/**, **.md`). |
| `11720c5` | Dark-mode selected file row was light-on-light — found on the real phone. |
| `6dd7398` | Recorded the real-device test results. |
| `82716b2` | SAF wired into the app ("SD card or custom folder" selectable): `StorageRoot.rootDocumentId`, **schema v2**, honest SAF capabilities, `registerSafRoot()` with a real write probe, root switcher chips on the Files tab. |
| `82392d3` | "Add files": own typed Pigeon picker (`pickFilesToCache`) instead of a third-party plugin; streamed `ImportFiles` use case with size verification and Keep-both conflict handling. |
| `14bc737` | A failing source stream now fails the import instead of committing a truncated file. |

CI runs: #3 first APK build (97 of 100 tests passing), #5 first fully green (100 tests), #6 green with
Kotlin (108 tests), #7 green at the handover commit `fc5f2f4`; 111 tests after the dark-mode fix.

## Phase 2 — Server host — 2026-09-19

| Commit | Change |
|---|---|
| `aabe0f0` | An Android foreground service owns the server (ADR-006). Kotlin `ServerForegroundService` starts a **headless FlutterEngine** running Dart entrypoint `serverMain`; `ServerStateStore`, `ServerControlHost`; three Pigeon APIs (`ServerControlApi`, `ServerRuntimeApi`, `ServerStateListener`); manifest permissions. Home's server card became real (Start/Stop, live state). At this point the "server" was a loopback-only health listener. |
| `c3d54b4` | Pigeon FlutterApi is `suspend`; an `ExpansionTile` banner needs its own `Material`. |

## Phase 3 — HTTPS portal and authentication — 2026-09-19

| Commit | Change |
|---|---|
| `90a18bc` | Auth core in pure Dart: `Argon2idPasswordHasher` (19 MiB / t=2 / p=1, PHC strings, constant-time verify, runs in an isolate), `PasswordPolicy`, `SessionManager` (256-bit tokens, only SHA-256 stored, 30 min idle / 12 h absolute), `LoginThrottle`. Also asks for the notification permission (found on the phone: `POST_NOTIFICATIONS` was not granted). |
| `e24abc7` | HTTPS with a Keystore-protected self-signed identity: `TlsIdentityStore` (EC P-256, private key encrypted with an AES-256-GCM key in the Android Keystore), `ServerConfigStore`, `HttpsListener` (no HTTP fallback), `RequestRouter` with security headers. Home shows the certificate SHA-256 fingerprint and an off-by-default "Allow other devices on my network" switch. |
| `f5460d7` | Excluded duplicate BouncyCastle `META-INF` docs from the APK merge. |
| `095eef4` | Server card wrongly said nothing was exposed while network access was on — found on the phone. |
| `7d45ee1` | **Schema v3**: `accounts` table; `CreateAdminAccount` (validates before hashing, atomic first-admin insert); admin set-up onboarding step. |
| `dfcf0ae` | Plain HTTP as an explicit, warned opt-in on port 8080 that only answers private networks; HTTP and HTTPS start together or not at all. |
| `6cafc93` | Cleared three analyzer infos. |
| `9414f34` | Login/logout/me/roots/entries API; bearer tokens; decoy hash for unknown users; per-account and per-address throttling; 16 KiB body cap. |
| `623d348` | Downloads with `Range`, streamed uploads, folders, rename, move, copy, delete-to-Recycle-Bin; `.vaultbox` hidden from clients. |
| `3c02986`, `d77eb0e` | Import fix; a `Stream<Uint8List>` could not feed a `Stream<List<int>>` transformer (first real upload answered 500). |
| `f3363f7` | 15-minute download tickets (`/d/<ticket>`); fixes for `100%.txt` paths and open-ended ranges. |
| `48c3c6e` | Browser portal served from the phone: dependency-free page under a strict CSP, source in `assets/portal/`, embedded into Dart by `tool/embed_portal.py` (a test fails if they drift). |

## Phase 4 — WebDAV — 2026-09-19

| Commit | Change |
|---|---|
| `948e959` | Refactor: `StorageGate` (root lookup, path validation, hidden folder, read-only, `Authorizer`) and `FileTransfer` (ranged download plan, safe streamed upload) shared by every protocol; `StoragePath.parseDecoded` treats already-decoded input literally. |
| `29904e7` | WebDAV class 1+2 at `/dav/`: PROPFIND/PROPPATCH/GET/HEAD/PUT/MKCOL/DELETE/COPY/MOVE/LOCK/UNLOCK, Basic auth with a short-lived verified-login cache, owner-bound locks, quota properties, DELETE to the Recycle Bin. |
| `fdeb116`, `c8aabcf`, `a59aa62` | Tests for dot-segment handling over a raw socket. |

## Phase 5 — Users, roles, sharing — 2026-09-19

| Commit | Change |
|---|---|
| `955b10c` | Roles, enabled flag and `credentialVersion` on accounts; `AccessRule` folder grants; shares; `AclAuthorizer`; use cases (create/change password/enable/delete/set rules, create share). **Schema v4.** Sessions and WebDAV logins end when a credential version moves. Public link pages `/s/` and `/u/` with password unlock, use limits and upload requests. |
| `beee45f` | Share tab (links and people), add/edit person, make-a-link with QR, server QR sheet. |
| `a5c8664` | Widget tests for the Share tab and flows; hid the Home QR button for loopback-only servers; tightened the public upload size guard. |

## Phase 6 — Activity and diagnostics — 2026-09-20

| Commit | Change |
|---|---|
| `d2e236a` | Server writes what happens (sign-ins, refusals, link use, transfers) to the shared database via `ActivityLog` and `TransferMeter`; the UI polls every 3 s. **Schema v5** (`activity_events`, `transfer_log`, `client_sightings`). Activity tab, Settings, Diagnostics with plain-words checks and a support bundle that names no people, addresses, files or storage locations. Also: QR in a fixed-size box inside `AlertDialog`, authorizer test expectation, CI now prints failures only. |
| `7af7515` | Widget tests given a tall screen; router imports sorted. **First green CI of phases 3–6: 708 tests.** |

## UI overhaul (M1) — 2026-09-20 — `bfff09c`

Response to the user's complaint that the UI looked cluttered, empty and off-mockup.

- Bundled the design's fonts (Patrick Hand headings, JetBrains Mono labels), theme-aware colours through an `AuroraContext` extension, mockup-faithful cards.
- **Appearance & Display**: System / Light / Dark, handwritten headlines, gradients, density; stored in a new settings table (**schema v6**).
- App header on every tab (mark, tab name, server pill, shortcuts).
- Home rebuilt with real data: hero card with address, QR, LAN IP, uptime, protocol chips, storage capacity, tiles, live activity.
- Settings became a hub: **Protocols & Network**, **Storage & Volumes** (real volume, path, capacity, read/write test), **Security & Sessions** (checklist from real settings, sign people out everywhere, certificate), Appearance, Diagnostics.
- Native `VolumeStats` channel (`vaultbox/storage_stats`), `url_launcher` for Open Portal, `AccountRepository.revokeSessions`.
- CI result: 820 tests passed, 1 failed (theme test needed `pumpAndSettle` because `AnimatedTheme` lerps), 14 unused-import warnings.

---

## M1 fixes + M2 FTP/FTPS — 2026-09-23 — `6587038`, `6052175`, `2ffdaf0`

Picked up from where the prior session paused ("Stop the process for now."), with a large uncommitted,
never-compiled working tree.

### M1 follow-ups (fix the CI result above)

- Removed the unused `aurora_colors.dart` imports from: `router.dart`, `activity_screen.dart`, `recycle_bin_screen.dart`, `qr_sheet.dart`, `admin_setup_screen.dart`, `onboarding_ready_screen.dart`, `onboarding_welcome_screen.dart`, `diagnostics_screen.dart`, `add_person_screen.dart`, `create_share_dialog.dart`, `person_screen.dart`, `share_screen.dart`; removed an unused drift import in `drift_settings_repository.dart`.
- `test/features/appearance_screen_test.dart`: "colours follow light and dark" now `pumpAndSettle`s after each `pumpWidget`.

### M2 — FTP / FTPS (server side)

New files:

| File | Purpose |
|---|---|
| `lib/domain/entities/ftp_settings.dart` | `FtpMode` (explicit TLS, implicit TLS, plain), `FtpSettings` (off by default, port 2121, passive range 50000–50050), validation, `toMap`/`fromMap` (keys `ftp.*`, bad values fall back to defaults). |
| `lib/server/files/root_names.dart` | Unique, URL-safe names for storage locations (`RootNames`), shared by WebDAV and FTP. |
| `lib/server/tls_context.dart` | `buildTlsContext(certificatePem, privateKeyPem)`, shared by HTTPS and FTPS so there is one certificate fingerprint. |
| `lib/server/ftp/ftp_paths.dart` | Path resolution against the current folder; can never climb above `/`. |
| `lib/server/ftp/ftp_listing.dart` | `LIST` (unix `ls -l`), `MLSD`/`MLST` and `NLST` line formats, timestamps. |
| `lib/server/ftp/ftp_deps.dart` | `FtpDeps` (gate, files, delete, move, auth, activity) and `FtpLimits` (idle 5 min, data connect 30 s, data idle 60 s, TLS handshake 15 s, 3 wrong logins, 8 connections total / 4 per address). |
| `lib/server/ftp/ftp_session.dart` | One control connection: USER/PASS, AUTH TLS, PBSZ/PROT, FEAT, PASV/EPSV, LIST/NLST/MLSD/MLST, RETR/STOR/REST, DELE/RMD/MKD, RNFR/RNTO, SIZE/MDTM. |
| `lib/server/ftp/ftp_server.dart` | Listener for the three modes; refuses a TLS mode without a certificate; plain FTP only answers loopback/private clients. |

Design points: explicit FTPS refuses login until `AUTH TLS`; passive mode only (`PORT`/`EPRT` answer 502, so a client cannot aim the phone at another machine); in TLS modes data connections require `PROT P` and must come from the control connection's address; sign-in reuses the WebDAV authenticator (same Argon2id check, throttling and verified-login cache); the virtual tree lists the storage locations at `/`; every file operation goes through `StorageGate`/`FileTransfer`, deletes go to the Recycle Bin.

Modified server files: `server_services.dart` (shared `passwordAuth`, `FtpDeps`, `loadFtpSettings()`, `buildFtpServer()`), `server_main.dart` (starts FTP after the web listeners when enabled; reports an `ftp://` or `ftps://` endpoint; stops it if start fails), `https_listener.dart` (uses `buildTlsContext`), `webdav_handler.dart` (uses `RootNames`), `activity.dart` (`AccessVia.ftp`).

### M2 — FTP / FTPS (app side)

- `lib/features/settings/presentation/protocols_screen.dart`: new **FTP / FTPS card** — enable switch (needs an admin account; plain FTP asks for confirmation), mode selector (Explicit FTPS recommended, Implicit FTPS, Plain FTP with warning), port and file-transfer-range dialogs with validation, locked while the server runs, "How to connect with FTP" guide. The web-port dialog now refuses ports FTP uses.
- `lib/features/settings/presentation/ftp_guide_sheet.dart`: bottom-sheet guide with this phone's host, port and security mode filled in (another phone's file manager, FileZilla/WinSCP/Cyberduck, cameras and scanners, troubleshooting).
- `lib/app/providers.dart`: `ftpSettingsProvider`.
- `lib/features/home/home_summary.dart`, `home_screen.dart`: `protocolStatuses(..., {ftp})` and an FTP/FTPS chip when enabled.
- `activity_format.dart`, `activity_screen.dart`, `security_screen.dart`: FTP shown as an access route ("FTP", `Icons.dns_outlined`).
- `share_links.dart`: `shareLinkBase` only considers `http(s)` endpoints now that FTP endpoints exist.

### Tests changed or added (uncommitted)

- `protocols_screen_test.dart`: existing counts updated for the extra card ("Off" ×3, locked notes ×4, Change-button indexes); new **FTP group** (defaults, enabling, admin required, plain confirmation, implicit mode, port and range validation, web-port conflict, network-access hint, guide contents). Uses an `InMemorySettingsRepository` override.
- `home_server_test.dart`: settings override plus "FTP gets a chip once it is switched on".
- `home_summary_test.dart`: FTP chip cases.

### TLS upgrade fixes (commit `6052175`, then `2ffdaf0`)

- Fixed the stated race: `FtpSession._auth` now pauses the control-socket subscription **before** replying `234`, not after.
- Found a second, bigger bug while fixing the first: the code called `SecureSocket.secureServer(_control, tls, subscription: old)` — but neither `secureServer` nor `SecureSocket.secure` has a public `subscription:` parameter (confirmed against api.dart.dev). First CI compile (run `35766073072`) failed on exactly this. Real fix: pause the subscription and do nothing else — `dart:io` detaches the raw socket internally and re-delivers buffered bytes to the new `SecureSocket` on its own.
- Added the unit/protocol/TLS tests listed in `docs/TASKS.md` section A.

### CI results

- Run `35766073072` (commit `6587038`): `flutter analyze`, `flutter test`, `build apk` all failed — the `subscription:` compile error above, the only real defect found.
- Run `35766894505` (commit `2ffdaf0`): all green — **942 tests pass**, analyze clean, debug APK builds. `dart format (advisory)` still fails but doesn't gate (pre-existing, see `docs/TASKS.md` section D).

---

## Riverpod → BLoC rewrite — 2026-09-23 — `39f716d`..`16fc00f`

Full replace of `flutter_riverpod` with `flutter_bloc`, at the user's explicit request. Offered a
narrower scope first (new features only, or a gradual one-feature-at-a-time migration); the user chose
full replace despite being told the risk (whole-app blast radius, no local compiler).

### Core (commits `39f716d`, `12d69c3`)

- `lib/core/state/resource.dart`: `Resource<T>` (`ResourceLoading`/`ResourceData`/`ResourceError`), a
  drop-in stand-in for Riverpod's `AsyncValue` — same `.value`, `.when(loading:, error:, data:)`,
  `.maybeWhen(data:, orElse:)`, so most call sites needed only their receiver retargeted.
- `lib/core/state/resource_cubit.dart`: `ResourceStreamCubit` (former `StreamProvider`),
  `ResourceFutureCubit` + `ResourceAwaiter` mixin (former `FutureProvider`; `refresh()` replaces
  `ref.invalidate`, `current()` replaces `ref.read(x.future)`), `PolledCubit` (former `_polled()`
  helper backing the activity feeds; `refreshNow()` replaces `ref.invalidate` without disturbing the
  timer).
- `lib/app/providers.dart`: the old 71 `Provider<T>` declarations became `AppDependencies`, a
  plain-Dart composition root with **no** `flutter_bloc`/`BuildContext` dependency — required because
  `lib/server/server_services.dart`'s headless server engine has no widget tree and previously used
  Riverpod's `ProviderContainer` for exactly that reason. `lib/app/app_providers.dart` (new) exposes
  each field individually via `RepositoryProvider<X>.value` for the UI side.
- `lib/app/app_state.dart` (new): every app-level Cubit. **Correction mid-migration** (`12d69c3`,
  made before any feature module was touched): `home_screen.dart` watches the activity feeds, root
  stats and FTP settings too, and Home is one of the five permanent
  `StatefulShellRoute.indexedStack` branches go_router keeps mounted forever — so those Cubits
  (`autoDispose` under Riverpod) were already effectively app-level in the running app, and belong
  here rather than as screen-scoped Cubits, which would have silently split Home and its sibling
  screen into two disconnected instances. The one genuinely screen-scoped Cubit is
  `RecycleItemsCubit` (Home never watches recycle-bin items).
- `lib/features/files/viewmodel/files_view_model.dart`: the one real Riverpod `Notifier` →
  `FilesCubit`, same generation/staleness-guard logic (protects against two overlapping reloads on
  one instance), same method shape, dependencies constructor-injected instead of pulled via
  `ref.read`.
- `lib/app/router.dart`, `lib/app/app_header.dart`, `lib/main.dart`: converted by hand (foundational,
  small). `GoRouter` is now built once directly in `main()` rather than through a `Provider<GoRouter>`
  — it never changed reactively, so this drops an indirection without changing behaviour.
- `pubspec.yaml`: `flutter_bloc ^9.1.1` (+ `bloc_test ^10.0.0` dev dependency) replaces
  `flutter_riverpod`. Versions checked against pub.dev, not guessed.

### Feature modules (commits `e40b5fd`, `1bed74f`, `8848429`, `62b8e6d`, `16fc00f`)

Done mostly by background agents running in parallel, one per feature area (Files/Onboarding,
Home/Activity, Settings, Share), each briefed with the exact Cubit/RepositoryProvider API from the
core layer above. The user paused the session mid-run (four agents killed together); on resume, every
file each agent had touched was individually re-verified against the source before being trusted —
grepped for leftover `WidgetRef`/`ConsumerWidget`/old provider names rather than accepting an agent's
self-report at face value. This caught:

- A real bug in `share_screen.dart`'s `_ShareCard`: `onPressed: () => unawaited(_revoke(context, ref))`
  passed a second argument, `ref`, that no longer existed in the (already-converted-to-`StatelessWidget`)
  class — a leftover from an earlier partial edit. Fixed to `_revoke(context)`.
- A systematic `unawaited_futures` lint gap: `ref.invalidate(x)` was synchronous, but its replacement,
  `Cubit.refresh()`, returns `Future<void>` — 11 call sites across `admin_setup_screen.dart`,
  `protocols_screen.dart`, `security_screen.dart`, `storage_screen.dart`, `add_person_screen.dart`,
  `create_share_dialog.dart`, `person_screen.dart` and `share_screen.dart` were left bare (no
  `await`/`unawaited(...)`). Fixed in one batch, `unawaited(...)` around each.

### CI result — run `35787650421`, commit `16fc00f`

`flutter analyze` clean, debug APK builds, **927 of 942 tests pass**. The 15 failures are all in
`share_screen_test.dart`, all one root cause: `RawTooltipState is a SingleTickerProviderStateMixin but
multiple tickers were created`, thrown from inside Flutter's own `raw_tooltip.dart` while routing an
ordinary tap — a known class of Flutter SDK ticker/animation-controller disposal bug (compare
`flutter/flutter#179337`), not an assertion failure and not application code. Once it fires once,
every later tap-driven test in the same file cascades into the same exception. Investigated at length
(see `docs/TASKS.md` section E for the full note); the user decided to accept and document it rather
than spend further CI runs guessing at a fix, on the same terms as the pre-existing
`dart format (advisory)` non-gating step.

---

## Release APK, launcher icon, splash screen, portal favicon — 2026-09-23 — `e5ee506`, `7004190`

At the user's request ("Build the release APKs, i wall install an check them for now."), then in
response to device-test feedback on the result.

### Release APK (`e5ee506`)

- `.github/workflows/ci.yml`: added `flutter build apk --release` alongside the existing debug build,
  uploaded as its own artifact (`vaultbox-release-apk`). Uses the `release` buildType already in
  `android/app/build.gradle.kts`, which signs with the debug keystore (a Flutter-template default,
  never replaced) — fine to install and try, not a Play Store-ready artifact.
- CI run `35790492649`: both debug and release APKs built successfully. `flutter test` failed with the
  same known 927/942 Tooltip flake (see the section above); `dart format (advisory)` failed as always
  (non-gating). Release APK size: ~30 MB (vs. ~91 MB debug) — expected, AOT compilation and no debug
  info.

### Device-test feedback and fixes (`7004190`)

The user installed the release APK and reported: default Flutter app icon, no splash screen, "layout
looks sloppy", no light-mode option, no folder choice for internal/external storage, no notification
while the server runs, and the web portal "looks sloppy" with no icon. Each claim was checked against
the actual code/assets before any fix — not assumed:

| Claim | Finding |
|---|---|
| No app icon / splash | **Real** — still the unmodified Flutter template (`android/app/src/main/res/mipmap-*/ic_launcher.png`, `drawable/launch_background.xml`). Fixed (below). |
| Web portal has no icon | **Real** — `assets/portal/index.html`/`public.html` had `<link rel="icon" href="data:,">`, a deliberate empty placeholder. Fixed (below). |
| No light-mode option | **Already exists** — Settings → "Appearance & Display" → System/Light/Dark, built in `bfff09c` (M1). Not touched; asked the user what they actually saw. |
| No folder choice for internal/external storage | **Already exists** — `onboarding_storage_screen.dart`'s "SD card or custom folder" option opens Android's SAF picker, and its own subtitle already reads "Pick any folder on this phone or an SD card." Not touched; asked what happened when they tried it. |
| No server notification | **Has a fix already, likely a device setting** — `MainActivity.kt` requests `POST_NOTIFICATIONS` when the server starts (a fix from an earlier session, after finding `granted=false` on a real phone). Not touched; asked the user to check Android notification permissions and MIUI's battery/autostart restrictions before assuming a new bug. |
| Layout sloppy / web portal usability | **Unverifiable here** — no device or emulator in this environment. The web portal was previewed directly with `tool/portal_mock_server.js` (built for exactly this) at desktop and mobile widths and looked clean, icon aside. Asked the user for a screenshot rather than guessing at changes. |

Fixes for the two confirmed-real issues:

- `assets/icon/icon.png`, `icon_foreground.png` (new): generated from `assets/images/vaultbox_mark.png`
  with Python/PIL — background pixels within a distance threshold of the sampled corner color keyed to
  transparent (soft-edged, not a hard cutoff), cropped to content, padded into a square at the Android
  adaptive-icon safe zone (content filling ~66% of the canvas), upscaled to 1024px. The flattened
  `icon.png` composites that foreground onto `#FBF9F4` (`AuroraColors.background`) for the legacy/plain
  icon slot. **Source is only 160×184px** — flagged to the user as a real quality ceiling; a
  higher-resolution source image would sharpen the result.
- `pubspec.yaml`: `flutter_launcher_icons` ^0.14.4 and `flutter_native_splash` ^2.4.8 (dev deps,
  versions checked against pub.dev), both configured against the two generated images and the app's
  own `AuroraColors.background` (`#FBF9F4`) / `AuroraColorsDark.surface` (`#15151A`) tokens, so the
  icon background and splash color match the in-app theme exactly rather than being arbitrary.
- `.github/workflows/ci.yml`: added a step running `dart run flutter_launcher_icons` and
  `dart run flutter_native_splash:create` before the APK builds — no local SDK exists to run these
  generators here, so, like the Drift/Pigeon codegen already in this workflow, they run fresh every CI
  build from the checked-in source images and pubspec.yaml config. The generated
  `android/app/src/main/res/*` output is copied into the CI report so it can be committed back into the
  repo's own checked-in scaffold later (not required for the build itself, which regenerates it every
  run regardless — see `TASKS.md` section C for that open follow-up).
- `assets/portal/index.html`, `public.html`: the favicon placeholder replaced with the same icon,
  resized to 64×64 and inlined as a base64 PNG data URI (the portal's own CSP already allows
  `img-src ... data:`; the whole page is embedded as literal Dart string constants by
  `tool/embed_portal.py`, which has no mechanism to reference a separate binary asset file, hence the
  inlining rather than a normal `<img src="...">` file reference). **A first attempt at this edit
  manually retyped the base64 string through a tool call and corrupted one character** (found by
  comparing the embedded string against the source file byte-for-byte, not by visual inspection, which
  would not have caught it); redone by having a Python script copy the string directly from the
  generated file into the HTML rather than retyping it. Regenerated
  `lib/server/portal/portal_bundle.dart` from the corrected sources via `python tool/embed_portal.py`.

### CI infra flake

Run `35879261154`'s "Publish report to the ci-reports branch" step failed with `remote: Internal
Server Error` on `git push -f` — a transient GitHub-side 500, not a workflow or code defect (every
other step in that run, including the new icon/splash generator and both APK builds, showed success).
A rerun was triggered (`gh run rerun --failed`, same run ID) but its result was not checked before the
user asked to stop the session; see `TASKS.md` state-in-one-line for the exact unresolved status.

---

## CI confirmation + committed android resources — 2026-09-24

Resumed the session by reading the handover docs and re-checking CI state rather than trusting the
last session's unresolved note.

- Read `origin/ci-reports` at run `35879261154` (the `7004190` rerun): `summary.md` shows `pub get`,
  `build_runner`, `pigeon`, `flutter analyze`, icon/splash generation and both APK builds all
  `success`; only `flutter test` shows `failure`. Read `logs/test.log` directly — the failures are the
  same 15 `share_screen_test.dart` cases (927/942 pass), the already-documented Flutter SDK
  Tooltip/ticker bug, not a new regression. `dart format (advisory)` is `failure` as always (not
  gating). **`7004190` is confirmed green** by the project's own definition.
- Fetched `generated-android/res/**` from that same `ci-reports` tree and copied it over
  `android/app/src/main/res/` (the TASKS.md section C open follow-up). New files: adaptive icon
  (`mipmap-anydpi-v26/ic_launcher.xml`, `values/colors.xml`, `values-v31/styles.xml`,
  `values-night-v31/styles.xml`); updated in place: launcher mipmaps, splash drawables,
  `launch_background.xml`, `styles.xml`. `AndroidManifest.xml` content is unchanged (diff was CRLF
  noise only). Not required for CI to keep building (it regenerates these every run) — keeps `git show`
  honest about what ships.
- Updated `TASKS.md` and `ROADMAP.md` to drop the "pending confirmation" language on `7004190`.

---

## Notable bugs found and fixed along the way

- Same-folder Replace could destroy the only copy of a file (`6d032c3`).
- `StoragePath.child` decoded real file names; `100%.txt` threw an uncaught `ArgumentError` (`6d032c3`, `f3363f7`).
- SAF: illegal persistable-flag bit would have crashed; `@async` Pigeon methods are `suspend` (`4bd1af5`).
- Import committed a truncated file when the source stream failed (`14bc737`).
- First real HTTP upload answered 500 because of a stream variance mismatch (`d77eb0e`).
- Server card claimed "nothing is exposed" while network access was on (`095eef4`).
- `QrImageView` inside `AlertDialog` throws "LayoutBuilder does not support returning intrinsic dimensions" — fixed size box (`d2e236a`).
- Widget tests failed off-screen at 800×600 — give them a tall test surface.
- Dart `unawaited(context.go(...))` type error; null-aware list elements are not available with the SDK constraint `>=3.6.0`.
