# Project Context

## Project Description

**VaultBox** turns an Android phone into a secure personal storage server / mini-NAS.
It is a **local-first file manager** that always works standalone, with an *optional*
authenticated HTTPS portal + WebDAV + versioned REST API (and later, optional FTPS) served
from an Android Foreground Service over the same storage.

Repository: `https://github.com/DevBehindYou/VaultBox` (**public** as of 2026-09-18 — the user
made it public during the session so CI results could be read without credentials).
Default branch `main`. License: see `LICENSE`.

## Main Goal

Build the app **carefully and in the phase order already laid out** in
`docs/IMPLEMENTATION_PLAN.md` (Phase 0 foundation → Phase 10 production hardening). The
existing code covers Phase 0 and roughly half of Phase 1 and had **never been compiled**.

## User Requirements

These are the user's own instructions this session, in order (do not reinterpret them):

1. *"Analyze VaultBox project's every file and start building the app carefully and accordingly."*
2. A full **AI-agent handover protocol** was requested (this `docs/ai-handover/` directory is
   that deliverable; the protocol asks for zero-loss continuity, no secrets, and honest
   VERIFIED / UNTESTED labelling).
3. **Hard environment constraint (user statement):** *"I don't have enough storage in my device
   to install the Flutter/Dart SDK and Android SDK. So, use alt for that like GitHub workflow
   to build and test the app."*
4. *"I have made the repo public."*

### User corrections

| # | What the agent did / proposed | User's correction | Rule going forward |
|---|---|---|---|
| 1 | Asked to download the Flutter SDK (1,842 MB zip) to `C:\Users\temp\dev\flutter` so it could compile and test locally. | Declined: no room for Flutter/Dart **or** the Android SDK. Use GitHub Actions instead. | **Never install or download an SDK/toolchain locally.** All compile/analyze/test/build verification runs in GitHub Actions. |
| 2 | Agent found the repo private (anonymous API 404) and planned around a private-repo log channel. | User made it public. | Anonymous GitHub REST reads now work for run/job/step status. |

## Functional Requirements

Source of truth is `docs/IMPLEMENTATION_PLAN.md` §B–§D and
`vaultbox_full_app_ui_ux_design/android_personal_storage_server_ui_ux_design_specification.md`
(56 KB, 49+ numbered sections). Summary:

- **MVP required:** onboarding (storage → admin → ready), local file manager
  (browse/create/copy/move/rename/delete/restore/multi-select), `StorageBackend` abstraction
  (Memory + DirectPath + SAF), Recycle Bin, Foreground-Service server host, HTTPS portal +
  auth, WebDAV, basic users/roles/ACL, shares + QR, transfer queue, activity/audit,
  diagnostics, light/dark theme, storage-disconnect recovery.
- **MVP optional:** REST API + scoped tokens, search index, thumbnails/preview,
  hide/camouflage, appearance/accessibility depth, support-bundle export.
- **Post-MVP:** Vault (AES-256-GCM), FTPS, SFTP, SMB, sync, snapshots, scheduled backups,
  Tailscale/WireGuard, transcoding, dedup, Internet exposure.
- **Rejected:** RAID, distributed storage, arbitrary SSH shell, SQL exposure, root-required
  features, AI features, plugin architecture, extra themes beyond light/dark.
- **Navigation:** exactly 5 permanent destinations — Home, Files, Share, Activity, Settings.
  Everything else is contextual (sheets/dialogs/sub-routes).

## Non-Functional Requirements

### Performance
Streamed I/O only — never `readAsBytes()` on a user file. Paged/virtualised directory listing
(target: responsive at 10,000+ files; `FileRow` is fixed-height with `itemExtent`). Bounded
transfer concurrency (not built yet). Granular Riverpod state so progress ticks don't rebuild lists.

### Security
- Every client-supplied path goes through `StoragePath.parse` (rejects `..`, encoded and
  double-encoded traversal, absolute paths, backslash tricks, control chars).
- `DirectPathStorageBackend` re-checks confinement after resolving (`p.isWithin`) as a second gate.
- Never delete the only valid copy before its replacement is verified (copy → verify → delete).
- Recycle Bin is the default delete target; permanent delete is explicit + confirmed.
- Never log secrets (`AppLogger.redact` is a safety net only).
- Planned: Argon2id/scrypt password hashing, TLS by default with no silent downgrade, hashed
  share/API tokens, Vault = AES-256-GCM with Keystore-backed keys. Hide ≠ Camouflage ≠ Vault —
  never call camouflage "encrypted".

### Accessibility
Status is never colour-only (glyph + text + colour). 48×48 dp minimum touch targets. Dock lens
animation respects Reduce Motion (`MediaQuery.disableAnimations`).

### Reliability
Item-isolated batch results ("46 completed · 1 skipped · 1 failed") — one bad file never aborts
a batch. Temp → verify → commit writes.

### Compatibility
Android 10+ (API 29+) target per the plan. SAF for arbitrary folders/SD cards. OEM background
restrictions are a known documented risk (Phase 2 concern).

### Maintainability
MVVM, one `StorageBackend` interface (ADR-004), strict analyzer settings
(`strict-casts/inference/raw-types`), no `print()` in production code, manual (non-codegen) Riverpod providers.

### UI/UX
**Aurora Glass** design system (`vaultbox_full_app_ui_ux_design/aurora_glass/DESIGN.md`): warm
paper canvas `#F0EEE9`, 1.5 px ink borders instead of shadows, lavender→pink Aurora gradient
reserved for primary/hero actions, Epilogue (display) / Inter (UI) / JetBrains Mono (technical,
tabular figures). 80 HTML+PNG mockups exist as *wireframe material*, not a 1:1 build list.
Home must stay thin (status, one endpoint, storage meter, one transfer line, one clients line,
warning slot) — **not** the mockup's 6-card dashboard.

## Platforms

Android (primary, Flutter). Future: browser-served web portal (Phase 3+, separate surface).
No iOS/desktop targeting. `flutter create` was only ever asked to generate `android/`.

## Technology Stack

Flutter **3.47.4** stable / Dart **3.13.3** (pinned in CI; matches Google's current stable as of 2026-09-11),
Kotlin (native SAF bridge), Drift (SQLite), Riverpod 3, go_router, Pigeon.

## Frameworks / Libraries

Resolved-version facts checked against pub.dev on 2026-09-18 (see `pubspec.yaml` for constraints):

| Package | Constraint | Notes |
|---|---|---|
| `go_router` | ^18.0.1 | 5-tab `StatefulShellRoute.indexedStack` |
| `flutter_riverpod` | ^3.0.0 (latest 3.4.3) | Notifier + constructor-injected family arg; `ref.mounted` guards |
| `drift` / `drift_dev` | ^2.34.x (latest 2.35.0) | needs `build_runner` |
| `drift_flutter` | ^0.3.1 | pulls `sqlite3_flutter_libs ^0.6.0+eol` (no-op stub) |
| `path_provider`, `path`, `uuid`, `logging` | see pubspec | |
| `pigeon` (dev) | ^29.0.1 (latest 29.0.2) | SAF bridge codegen |
| `flutter_lints` | ^5.0.0 (latest 6.0.0) | not bumped, to avoid lint noise |

## Services / APIs

None external. Planned local server: single listener `https://host:8443/` fronting portal,
`/dav/`, `/api/v1/`, `/s/` (shares), `/health/`. WebDAV over HTTPS is the primary mountable
protocol (ADR-003); FTPS optional (ADR-009); plain FTP off by default; SFTP post-MVP.

## Database

Drift/SQLite via `AppDatabase` (`lib/data/db/app_database.dart`), schema v1: tables
`storage_roots`, `recycle_items`. Metadata only — large files never go in SQLite.
File is `vaultbox.sqlite` in `getApplicationDocumentsDirectory()`.

## Authentication

Not implemented (Phase 3). No credentials exist anywhere in the repo.

## Storage

- `MemoryStorageBackend` (tests/UI), `DirectPathStorageBackend` (real FS, app-private dir),
  `SafStorageBackend` (complete Dart side; native side unreconciled — see CURRENT_STATE).
- Recycle Bin bytes live at `/.vaultbox/recycle/<id>__<name>` inside the *same root*; metadata in Drift.

## Deployment

None. Build artefact = debug APK from CI (`vaultbox-debug-apk`, 14-day retention).

## Minimum Supported Versions

Dart SDK constraint in `pubspec.yaml`: `>=3.6.0 <4.0.0`. Android minSdk target 29 (from the plan;
the generated scaffold's actual `minSdk` is whatever Flutter 3.47.4's template sets — **verify**).

## Known User Preferences

- Wants careful, incremental, verified progress; wants the handover to be exhaustive
  ("optimise for continuity, accuracy, traceability").
- Prefers not to have things installed on the machine; uses GitHub as the build/test machine.
- Uses git user `DevBehindYou`. The user commits/pushes to `main` themselves (they pushed the
  initial project as commit `37f1d60` "Push" mid-session).

## Explicit User Constraints

- **No local SDK installs/downloads** (see correction #1).
- Do not push to `main`; work on branches (this session: `ci/bootstrap`).

## Things the User Specifically Does NOT Want

- Local Flutter/Dart/Android SDK installation.
- (Inherited from the plan/kickoff docs) fake-functional UI: controls that look live but do
  nothing; a 20-widget dashboard Home; per-protocol code owning its own filesystem logic.

## Documents referenced by the plan but NOT in the repo

`docs/IMPLEMENTATION_PLAN.md` cites an `Android_Personal_Storage_Server_Documentation/` set
(29 files: "doc §NN", "kickoff §NN", "KB vol2 §NN", ADR-001…012). **It is not in this repository**
and was not available to this session. Section numbers in code comments therefore cannot be
cross-checked here. If the user has that folder, ask for it before Phase 2.
