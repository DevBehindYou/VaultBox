# VaultBox — Implementation Plan

Prepared from: `Android_Personal_Storage_Server_Documentation/` (29 files) and
`stitch_full_app_ui_ux_design/` (80 screen mockups + Aurora Glass design system).

This document is the analysis gate required before coding (kickoff §79). It is a living
document — update it when architecture or scope decisions change materially.

---

## A. Existing Repository Assessment

There is no pre-existing VaultBox codebase. This is a greenfield build. What exists today:

- Two source packages only: the technical documentation set and the Stitch-generated
  UI/UX mockups (HTML/Tailwind + PNG screenshots, one folder per screen state).
- No `pubspec.yaml`, no `android/` Gradle project, no Dart source, no tests.
- **Toolchain constraint (environment-specific, not a project fact):** the sandbox this
  plan was written in has no Flutter/Dart SDK installed and no network path to Google's
  SDK distribution servers (only github.com, pypi.org, npmjs.com, crates.io and similar
  are reachable). `flutter pub get`, `dart run build_runner`, `flutter analyze`,
  `flutter test` and `flutter build` cannot be executed here. Every file below is written
  to compile and behave correctly under the pinned versions in §E, but has not been
  machine-verified by this session — run the commands in `README.md` in a real Flutter
  environment before trusting it further. This gates how much of Phase 0's "exit: tests
  green" criterion could actually be satisfied in this session (see §G, risk R-9).

## B. Documentation Understanding

**Product.** Turn an Android 10+ (API 29+) phone into a local-first personal storage
server / mini-NAS: local file manager always works standalone; an Android Foreground
Service optionally serves the same storage over an authenticated HTTPS portal, WebDAV,
a versioned REST API, and (later, optional) FTPS. Three complexity tiers — Simple /
Advanced / Developer — are reached through progressive disclosure, not separate apps.

**Architecture.** MVVM (View → ViewModel → optional UseCase → Repository → Service/
Adapter), Flutter/Dart for everything cross-platform, Kotlin only for what genuinely
needs Android platform APIs (Foreground Service, SAF/ContentResolver, NSD, Keystore,
power/network callbacks). Every file operation — local, HTTP, WebDAV, FTPS, Vault —
must go through one `StorageBackend` interface; no protocol package is ever allowed to
own the data/storage model directly (ADR-004). The Android Foreground Service, not the
Flutter `Activity`, owns server lifecycle (ADR-006).

**Storage.** SAF-backed (`content://` URIs via `ACTION_OPEN_DOCUMENT_TREE`) and
direct-path backends are both first-class; a `StoragePath(rootId, normalizedSegments)`
value object replaces raw strings everywhere so a client path can never be trusted
directly. Metadata (users, ACL, shares, sessions, transfers, audit, Recycle Bin, cached
file index) lives in Drift/SQLite; large user files never do.

**Server/network.** One secure listener (`https://host:8443/`) fronting the web portal,
`/dav/`, `/api/v1/`, `/s/` (shares) and `/health/`. WebDAV over HTTPS is the primary
mountable protocol (ADR-003); FTPS is optional and gated behind a client-compatibility
test pass; plain FTP is off by default; SFTP is explicitly post-MVP (ADR-009).

**Security.** Argon2id/scrypt password hashing (never bare SHA-256), path + action ACL
evaluated server-side for every protocol, TLS by default with no silent downgrade,
high-entropy share/API tokens stored as verifiers, and a clear three-tier privacy model:
Hide (`.nomedia`, not security) → Camouflage (reversible obfuscation, weak privacy,
never called "encrypted") → Vault (AES-256-GCM authenticated encryption, Keystore-backed
key hierarchy). Every destructive/transformative operation follows
temp → verify → commit → (delete source only if configured) — never delete-before-verify.

**UI.** Aurora Glass design system (full tokens captured in `lib/core/design/`): a warm
paper-neutral canvas (`#F0EEE9`) with crisp 1.5px ink borders rather than shadows, a
lavender→pink Aurora gradient reserved for primary/hero actions, Epilogue for display
type, Inter for UI/body text, JetBrains Mono for anything technical (IPs, hashes, ports,
throughput — always tabular figures). Five permanent nav destinations only: Home, Files,
Share, Activity, Settings; everything else is contextual.

**Testing/perf/security gates.** Streamed I/O only (never `readAsBytes()` on large
files), paged/virtualized directory listing, bounded transfer concurrency, granular
Riverpod state so a 2% progress tick doesn't rebuild the file list, item-isolated batch
results, and an explicit MVP release gate (zero known auth/ACL bypass, zero path
traversal, no plaintext secrets in logs/DB, etc.).

## C. Scope Classification

**MVP Required (this build targets these first):**
Onboarding (storage → admin → ready), local file manager (browse/create/copy/move/
rename/delete/restore/multi-select), `StorageBackend` abstraction with Memory +
Direct-path + SAF implementations, Recycle Bin, Foreground Service server host, HTTPS
portal + auth, WebDAV, basic users/roles/ACL, shares + QR, transfer queue, activity/
audit, diagnostics, light/dark theme, storage-disconnect recovery.

**MVP Optional (build if time/architecture allows, never blocks the above):**
REST API + scoped tokens, search index, thumbnails/preview, hide/camouflage,
appearance/accessibility settings depth, support-bundle export.

**Post-MVP (explicitly deferred per doc):**
Vault (AES-256-GCM encryption) unless foundational storage/server is already stable;
FTPS (after HTTPS/WebDAV/storage are reliable); SFTP; SMB; desktop/phone sync; snapshots/
versioning; scheduled backups; Tailscale/WireGuard; media transcoding; deduplication;
remote/Internet exposure.

**Rejected / not building:**
RAID, distributed/multi-node storage, arbitrary SSH shell, full SQL server exposure,
root-required features, unrestricted cross-app storage access, automatic public Internet
exposure, AI functionality, plugin architecture, multiple themes beyond light/dark.

## D. Final Screen List

The mockup set contains **80 individual screen states** across onboarding, home,
files, share, activity, vault, settings, web portal, and Android-system reference
screens. Per kickoff §6/§7/§52, these are wireframe *material*, not a 1:1 build list.
Consolidation decisions:

1. **Navigation stays at exactly 5 permanent destinations** (Home, Files, Share,
   Activity, Settings), matching doc §8 exactly. Vault, Users, Diagnostics, WebDAV,
   FTPS, API, Storage, Logs, Clients, Security are reachable *from* these five, never
   as their own tab — this matches both the kickoff doc and `08_Navigation_...md`.

2. **Home is intentionally thinner than its own mockup.** `home_server_live/` shows six
   stat cards (Storage, Clients, Throughput, Active Queues, Node Health/temperature,
   Live Activity) plus the status header — that's the "20-widget dashboard" the kickoff
   doc explicitly warns against (§6, §69). The production Home keeps only what §69 asks
   for: status + start/stop, one endpoint (URL + QR + copy IP), storage-used meter,
   one active-transfer line, one connected-clients line, and a warning banner slot.
   Throughput and node temperature move to Server Details / Diagnostics, reachable via
   "Manage →", not shown by default. `home_starting_server`, `home_limited_server`,
   `home_server_stopped`, `home_no_network_offline` collapse into one `HomeScreen`
   driven by a `ServerState` enum, not four separate routes.

3. **Files consolidates seven mockups into one screen + contextual sheets:**
   `files_storage_explorer`, `files_folder_view`, `files_multi_select_state`,
   `files_sort_filter_sheet`, `search_files_metadata_index`, `new_folder_dialog_...`,
   `file_conflict_overwrite_resolution`, `move_copy_destination_picker`,
   `file_details_integrity_sheet`, `file_operation_queue`, `recycle_bin_safe_recovery`
   → one `FilesScreen` (breadcrumb + list, toggles into multi-select) with sort/filter,
   destination-picker, conflict, details and operation-queue as bottom sheets/dialogs,
   and Recycle Bin as a filtered view of the same screen, not a separate visual design.
   `file_preview_studio_select_014.dng` → generic file-preview route, not a bespoke
   "studio" screen.

4. **Share consolidates:** `share_pairing_center`, `create_share_select_resource_type`,
   `create_share_resource_permissions`, `create_share_link_ready_qr`,
   `share_details_access_management`, `add_user_folder_access_permissions`,
   `user_details_access_permissions` → one `ShareScreen` (list) + one `CreateShareFlow`
   (sheet stepper: target → permissions → expiry/password → done) + `ShareDetails` +
   a Users entry point reachable from Share, per doc §6 navigation map — not a
   standalone Users tab.

5. **Activity consolidates:** `activity_transfers`, `transfer_queue_active_jobs`,
   `connected_clients_active_sessions`, `client_details_session_inspector`,
   `activity_system_events_audit_log`, `failed_login_intrusion_audit_log`,
   `system_logs_real_time_console` → one `ActivityScreen` with a 3-way segmented control
   (Transfers / Clients / Events), matching doc §7 exactly. Raw log console stays one
   level deeper (Settings → Diagnostics), not promoted to Activity's default view.

6. **Settings consolidates ~20 mockups** (`server_settings`, `server_protocol_settings`,
   `webdav_protocol_settings`, `ftps_legacy_protocols`, `network_interface_binding`,
   `network_settings_static_ip_adapter_config`, `hotspot_ad_hoc_p2p_network`,
   `tls_certificates_security_settings`, `security_audit_active_sessions`,
   `api_tokens_developer_management`, `create_api_token_scopes_permissions`,
   `storage_locations_volume_health`, `storage_health_hardware_telemetry`,
   `add_storage_location_saf_directory_picker`, `settings_appearance_accessibility`,
   `system_diagnostics_health_check`, `diagnostic_results_auto_fix_center`,
   `high_risk_operations_keystore_reset`, `about_open_source_licenses`,
   `webdav_setup_helper_*` ×4) → one grouped `SettingsScreen` (Storage / Server / Network
   / Security / Sharing / API / Appearance / Diagnostics / About), each group opening
   its own sub-route. The four WebDAV client setup-helper guides (Windows/macOS/Linux/
   generic connect) become one `WebDavSetupHelperScreen` with a platform tab selector
   instead of four near-duplicate screens.

7. **Vault is a Files sub-destination, not a tab:** `vault_locked_state`,
   `vault_unlocked_management`, `move_to_vault_encryption_modal`,
   `vault_encryption_in_progress`, `hide_privacy_camouflage_sheet` → `/files/vault/*`
   routes, built in Phase 8 per roadmap — not in the initial screen build.

8. **Web portal screens** (`web_portal_secure_login`, `web_portal_desktop_files_storage`,
   `web_portal_mobile_browser_view`, `web_portal_https_configuration`,
   `public_share_page_selects_final`, `public_share_mobile_browser_view`,
   `upload_request_send_files_to_storage_node`, `upload_request_mobile_browser_view`,
   `session_expired_safe_resume`) describe the *browser-served* surface (Phase 3+), not
   the Flutter app — tracked but out of this plan's Flutter screen list.

9. **`storage_disconnected_recovery_alert`, `android_system_battery_optimization`,
   `android_system_notification_foreground_shade`** are system-level states rendered
   contextually (banners/dialogs/OS notification content), not routed screens.

10. **`splash_initializing_node_storage`, `qr_pairing_connection_details`,
    `server_details_live_endpoints`** map directly to `Splash`, the QR sheet opened from
    Home, and `Home → Server Details` respectively — kept as designed.

**Resulting production route list** (matches `08_Navigation_...md` almost exactly;
deltas noted above):

```text
/onboarding/{welcome,storage,admin,security,server,ready}
/app/home  (+ server details, QR, clients, transfers, storage sheets)
/app/files/{root/:rootId, browse/:rootId/*, search, preview/:id, details/:id, recycle}
/app/files/vault/*                       (Phase 8)
/app/share/{new, :shareId, users, users/:userId}
/app/activity/{transfers, clients, events, logs}
/app/settings/{storage, server, web, webdav, network, security, api, appearance,
                diagnostics, about}
```

## E. Package List

| Package | Purpose | Why necessary | Alternative considered | Risk |
|---|---|---|---|---|
| `flutter_riverpod` | ViewModel/DI/async state | Doc-mandated (§00, §03); AsyncNotifier maps cleanly onto MVVM ViewModels | Provider, Bloc | Low — widely used, active |
| `go_router` | Declarative nav, shell routes, deep links | Doc-mandated; needed for 5-tab shell + nested feature routes + future web URL routing | Navigator 2.0 hand-rolled | Low |
| `drift` + `drift_flutter` | Metadata DB (users/ACL/shares/sessions/transfers/audit) | Doc-mandated; reactive streams fit Riverpod well; never stores large files | sqflite raw, ObjectBox | Medium — requires `build_runner` codegen step every schema change (see §A toolchain note) |
| `pigeon` | Typed Dart↔Kotlin bridge for SAF/FGS/NSD/Keystore | Doc-mandated over ad-hoc MethodChannel strings; keeps native contract typed and testable | Hand-written MethodChannel | Low, but also requires local codegen |
| `path` | Path segment manipulation for `StoragePath` normalization | Standard, tiny, no native deps | Hand-rolled string splitting | Very low |
| `uuid` | ID generation for entities (`IdGenerator` service in doc §03) | Doc lists `IdGenerator` as a first-class service | `crypto`-based custom | Very low |
| `cryptography` | Vault AES-256-GCM (Phase 8, not this slice) | Doc-recommended candidate (§04, §12) | `pointycastle` | Deferred — not pulled into Phase 0/1 build |
| `flutter_secure_storage` | Small secret/config storage, not key material itself | Doc-recommended (§04) | Manual Keystore-only | Deferred to Phase 3 (auth) |
| `logging` (or a small hand-rolled structured logger) | Structured logs per §16/§20 (`no print() in production code`) | Needed from Phase 0 so the habit is never "add later" | `logger` package | Very low |
| `flutter_lints` | Analyzer/lint baseline | Doc-mandated strict analyzer (§04, §20) | Custom lint set | None |

**Deliberately not added yet:** `freezed`/`json_serializable` (doc-recommended, §04) —
the Phase-0/1 slice in this plan uses plain immutable Dart classes with manual
`copyWith` instead, specifically to avoid requiring a second codegen pipeline
(`build_runner` is already mandatory for Drift) before the project can be opened and
read. Freezed should be introduced once the toolchain is verified locally — it is listed
in `pubspec.yaml` as a dev dependency placeholder with a comment, not silently dropped
from the architecture. `shelf`/`shelf_router`/`shelf_dav`/`ftp_server` are Phase 2–4/9
concerns (server runtime) and are out of scope for this Phase 0/1 delivery; pulling them
in now would violate kickoff §49 ("do we actually need this dependency *right now*").

## F. Implementation Order

Following doc §18 / kickoff §63 exactly, phase-by-phase. **This session delivers Phase 0
and the start of Phase 1** (storage abstraction + a working local file manager UI against
in-memory and direct-path backends). Everything from Phase 2 onward is scaffolded only
as routes/placeholders so navigation is coherent, per kickoff §77 ("Coming later" is
allowed, fake functional-looking buttons are not).

| Phase | Scope | Status after this session |
|---|---|---|
| 0 — Foundation | repo layout, MVVM skeleton, Riverpod, go_router, design tokens, Drift schema (uncompiled pending codegen), Pigeon contract stub | **Done** |
| 1 — Storage & local file manager | `StorageBackend` + Memory/DirectPath backends, `StoragePath`, capability model, browse/create/copy/move/rename/delete/restore, multi-select, Recycle Bin, transfer-queue skeleton | **Partially done** — see breakdown below |
| 2 — Native server host | Foreground Service, notification, headless Dart runtime, state stream | Not started (route/placeholder only) |
| 3 — HTTPS portal & auth | TLS, admin login, sessions, Flutter Web portal, ACL foundation | Not started |
| 4 — WebDAV | Adapter, methods, ACL, SAF-compatible layer, interoperability | Not started |
| 5 — Users & sharing | Users, roles, ACL UI, shares, QR, upload requests | Not started |
| 6 — Activity & diagnostics | Transfers/clients/events, logs, diagnostics, support bundle | Not started |
| 7 — Security hardening | Brute-force controls, API tokens, secret storage, headers | Not started |
| 8 — Vault & privacy | `.nomedia`, camouflage, Vault format, key hierarchy | Not started |
| 9 — FTPS | Adapter, TLS, passive config | Not started |
| 10 — Production hardening | Perf, OEM lab, accessibility, localization, release pipeline | Not started |

Within Phase 1 the doc's own feature order (§18) was followed: domain types →
repository interface → fake (`MemoryStorageBackend`) → ViewModel → UI → real backend
(`DirectPathStorageBackend`) → tests → docs. SAF is the one deferred piece: a real
`SafStorageBackend` needs the Pigeon-generated `AndroidStorageApi` host implementation in
Kotlin, which needs the Flutter/Pigeon toolchain this sandbox cannot run (§A). It is
written against the same `StorageBackend` interface with the native calls clearly marked
`// TODO(pigeon)` rather than faked to look functional.

## G. Risks

In addition to the project-level risk register already in doc `19_Risks_...md` (kept in
force unchanged — Android killing long-running servers, SAF/WebDAV package immaturity,
data loss during move/encrypt, OEM background restrictions, etc.), this build session
adds:

- **R-9 (process risk, this session only).** No Flutter/Dart toolchain or SDK-download
  network path is available in this sandbox. Code has been written carefully and
  reviewed by re-reading, but *not* compiled, analyzed, or test-run here. Treat the
  first local `flutter pub get && flutter analyze && flutter test` as the real Phase 0
  exit gate, not this session's completion. This is the single most important caveat in
  this plan.
- **R-10.** Drift and Pigeon both require `build_runner` codegen before the project
  compiles at all. Until that's run locally, `app_database.g.dart` and the Pigeon
  `.g.dart` outputs don't exist. This is normal Flutter workflow, not a defect, but it
  means "clone and run" needs one extra documented step (`README.md` covers it).
  Additionally note: the `20 min-old repo` risk is real for this specific plan — a
  freshly-scaffolded `android/` Gradle project was **not** hand-written here (see
  README) because a correct Gradle wrapper/AGP setup is exactly the kind of
  binary/version-sensitive artifact that's unsafe to hand-author; `flutter create .`
  must generate it once locally, after which the Kotlin/manifest files in this delivery
  drop in on top.
- **R-11.** The `SafStorageBackend` is architecturally complete (implements the full
  `StorageBackend` contract) but functionally a stub until the native Kotlin side exists
  (Phase 2 territory per the doc's own phase order, since SAF's persistent-URI-grant
  bridge is native work). Shipping only `DirectPathStorageBackend` + `MemoryStorageBackend`
  for Phase 1 is a deliberate scope cut, not an oversight — it still gives the "fast
  local file manager" milestone (kickoff §65) something real to run against (the app's
  own storage sandbox / any directory the user grants via `filePicker`-style access the
  OS already permits), while SAF's Android-11-plus root restrictions get the native
  bridge they actually need in Phase 2 alongside the Foreground Service work.


---

## H. Phase 1 Delivery Breakdown (end of build session 2)

**Written:**

| Piece | Where |
|---|---|
| `StoragePath` with full traversal rejection | `lib/domain/value_objects/storage_path.dart` |
| `StorageBackend` interface + documented paging contract | `lib/domain/repositories/storage_backend.dart` |
| `MemoryStorageBackend` (complete contract, not a stub) | `lib/data/services/memory_storage_backend.dart` |
| `DirectPathStorageBackend` (temp→rename commit, root confinement, errno mapping) | `lib/data/services/direct_path_storage_backend.dart` |
| `FileRepositoryImpl` (same-backend fast path, cross-backend streaming + size verify, Keep Both naming) | `lib/data/repositories/file_repository_impl.dart` |
| `CopyItems` / `MoveItems` / `DeleteItemsToRecycleBin` / `RestoreItems` | `lib/domain/usecases/` |
| Riverpod composition root + backend registry | `lib/app/providers.dart` |
| `FilesViewModel` (paged, sorted, multi-select) | `lib/features/files/viewmodel/` |
| Files screen, FileRow (fixed-extent), Home, shell + dock, router | `lib/features/`, `lib/app/` |
| Aurora Glass tokens, themes, shared widgets | `lib/core/design/` |
| Tests: path security, backend contract suite (runs against both backends), batch isolation, move safety, Files widget tests | `test/` |

**Written this session (build session 3):**

1. ~~Destination picker sheet~~ → `lib/features/files/presentation/destination_picker_screen.dart`.
   Reuses `filesViewModelProvider` read-only (no second selection model layered
   on top); root switcher shown only when more than one root exists.
2. ~~Conflict-resolution dialog~~ → `lib/features/files/presentation/widgets/conflict_dialog.dart`.
   Scope cut, documented on the widget itself: one upfront Replace/Keep
   Both/Skip choice covers the whole batch, not per-item resolution with an
   apply-to-all toggle. Wired into both Copy and Move in
   `files_screen.dart._runTransfer` — pick destination → `validateDestination`
   (blocks copying a folder into itself, via the new
   `StoragePath.isDescendantOfOrEqualTo`) → `findConflicts` → resolve if
   needed → run.
3. ~~Onboarding flow~~ → `lib/features/onboarding/`. Welcome → Choose Storage →
   Ready, three top-level go_router routes outside the shell (no dock during
   setup). **Scope cut, not a placeholder:** the only live storage option is
   the app's own private directory via `path_provider`
   (`onboarding_actions.dart`), verified with a real `createDirectory` probe,
   not a fake success. SD card / custom folder is shown, disabled, labelled
   "Phase 2" — kickoff §77 shape, not hidden and not faked. Both empty-storage
   surfaces (Home's storage card, the Files tab entry point) now have a real
   "Set up storage" button into this flow instead of a dead-end message.

**Written this session (build session 4):**

1. ~~Drift schema + `build_runner`~~ → `lib/data/db/app_database.dart`
   (`storage_roots`, `recycle_items` tables) + `DriftStorageRootRepository` /
   `DriftRecycleBinRepository`, now the *default* runtime implementation in
   `app/providers.dart`. The in-memory versions are demoted to test fakes
   (doc comments updated to say so) rather than deleted — doc §59 wants them
   kept as fast doubles, and the widget-test harness now overrides all three
   repositories explicitly (see below) so no test silently depends on a real
   database.
2. ~~Recycle Bin view + `RestoreItems` wiring~~ →
   `lib/features/files/presentation/recycle_bin_screen.dart`, reached from a
   new toolbar icon on `FilesScreen`. Restore only in this delivery —
   permanent delete from the bin (doc §27) is next, not silently dropped.
3. **Verified package versions against pub.dev instead of guessing** — the
   original `drift`/`drift_flutter`/`drift_dev` version pins in `pubspec.yaml`
   were stale guesses from before any package could be checked; corrected to
   what pub.dev actually shows (`drift_flutter: ^0.3.1`, `drift: ^2.34.0`,
   `drift_dev: ^2.34.2`) now that search was available. The `driftDatabase()`
   API shape and constructor pattern in `app_database.dart` are copied from
   drift_flutter's own documented example, not inferred from memory.
4. **R-12 resolved, not just documented** — checked Riverpod 3.0's actual
   migration guide. It confirmed the concern: `AutoDisposeFamilyNotifier` no
   longer exists in Riverpod 3.x; `Notifier`, `FamilyNotifier` and the
   `AutoDispose*` variants were fused into plain `Notifier`, and family
   notifiers now receive their argument through a constructor instead of a
   `build(arg)` parameter. `FilesViewModel` is rewritten to that shape
   (`class FilesViewModel extends Notifier<FilesState>` with
   `FilesViewModel(this.arg)`), and the same pass added `ref.mounted` guards
   after every `await` that resumes into a `state =` write — Riverpod 3.0
   also made touching a disposed provider's `ref`/`state` throw instead of
   silently no-op, which is a real hazard for a screen that can be popped
   mid-operation, not a hypothetical one.
5. **Found and fixed a staleness bug while writing the Recycle Bin's own
   test**, worth recording because of how it was found: restoring a file
   from the bin used to leave the `FilesScreen` you returned to showing the
   old listing, since nothing told its `FilesViewModel` to reload. Fixed by
   awaiting the Recycle Bin push in `_openRecycleBin` and reloading on
   return. This is the kind of gap that only a real end-to-end test (delete
   → open bin → restore → verify the file's back) catches — a unit test on
   `RestoreItems` alone would have passed throughout.

**Written this session (build session 5):**

1. ~~Permanent delete from the Recycle Bin~~ →
   `PermanentlyDeleteRecycled` use case, wired into `RecycleBinScreen` behind
   a named confirmation dialog (doc §27). Tested (including the "id already
   gone" no-op case).
2. ~~Pigeon `AndroidStorageApi` + `SafStorageBackend`~~ — the biggest single
   piece of work this session, landed as far as it honestly can without the
   real toolchain:
   - `pigeons/storage_api.dart` — the full Pigeon spec (tree grant, list,
     stat, create dir/file, delete, rename, fd-based read/write).
   - `lib/platform/adapters/android_storage_host.dart` — a hand-authored
     `AndroidStorageHost` interface, deliberately decoupled from Pigeon's
     generated types so it compiles and is unit-testable *today*, without
     codegen.
   - `lib/data/services/saf_storage_backend.dart` — the real
     `StorageBackend` implementation against that interface: path→documentId
     resolution by walking segments (SAF has no path addressing — doc §21/§23
     applies to the native side too, not just the wire protocol), directory
     recursion for copy, capabilities reported honestly
     (`supportsAtomicReplace: false` — SAF has no atomic rename-over-existing
     the way a real filesystem does, and that gap is documented in the code,
     not hidden).
   - `test/data/saf_storage_backend_test.dart` — covers everything testable
     in pure Dart (path resolution, list/stat/mkdir/rename/delete, directory
     copy recursion). Explicitly does NOT cover `openRead`/`openWrite`/file
     `copy`, because those depend on `File('/proc/self/fd/$fd')` backed by a
     real native file descriptor — un-fakeable from pure Dart, not
     un-tested by oversight. Said so in the test file itself rather than
     leaving the gap implicit.
   - `android/app/src/main/kotlin/com/vaultbox/app/storage/SafStorageHostApi.kt`
     — a real first-draft native implementation using standard
     `DocumentFile`/`DocumentsContract`/`ContentResolver` calls, plus a
     coroutine-based tree-picker bridge (`ActivityResultTreePickerLauncher`).
     Flagged prominently, twice, as needing reconciliation against whatever
     Pigeon's codegen actually produces once run — this was written against
     this session's own best understanding of the spec, not verified against
     generated output, which this sandbox cannot produce.
   - **What this does NOT include, on purpose:** the actual `dart run
     pigeon` run (needs `android/` to exist, which needs `flutter create .`
     first); `MainActivity`'s registration call; the
     `kotlinx-coroutines-android` Gradle dependency the Kotlin file needs.
     All three are one-time, human-run setup steps, documented at their
     point of need rather than guessed at.

**Not yet written, in the order it should be picked up:**

1. **Run the actual toolchain** — `flutter create .` → `dart run pigeon` →
   reconcile `SafStorageHostApi.kt` against the real generated interface →
   wire `MainActivity` → confirm on a real device that a SAF root can be
   added from Onboarding's now-enabled "SD card / custom folder" option.
   This is the one item on this list that isn't "write more code" — it's
   "prove the code already written is right," which needs a human with the
   real SDK.
2. **Transfer engine** — the centralized queue (doc §28). Local copy/move
   currently runs inline in the use case rather than through a queue with
   bounded concurrency, progress and cancel. Correct for single operations,
   insufficient once network transfers exist.
3. **Onboarding's SD-card option** — still shown disabled
   (`onboarding_storage_screen.dart`) pending item 1 above; flip it on once
   `SafStorageBackend` has a real native host behind it.

**Known risks carried into the next session:**

- **R-12 — RESOLVED.** Was: `FilesViewModel` used the Riverpod 2.x spelling,
  unverifiable at the time. Now checked against riverpod.dev's actual 3.0
  migration guide and fixed for real (see §H, session 4) — not just
  re-flagged as still-uncertain. `flutter_riverpod`'s pub.dev listing was
  also checked directly this session (latest stable 3.4.3, confirming the
  package and API generation this code targets both actually exist) rather
  than left as an unverified guess.
- **R-13.** `DirectPathStorageBackend` paging inherits the OS enumeration order,
  which is not guaranteed stable under concurrent modification (documented on
  the interface). Acceptable now; needs an index-backed cursor once the file
  index lands.
- **R-14.** Fonts (Epilogue / Inter / JetBrains Mono / Patrick Hand) are named
  in the type tokens but not yet registered as assets or via `google_fonts`, so
  the app currently renders in the platform default with correct metrics.
  Cosmetic, but it means the Aurora identity is not yet visually complete.
- **R-15.** Onboarding's only working storage option is the app's private
  directory (`getApplicationDocumentsDirectory()`), which the user never
  chose and cannot see in a normal file browser. This is a legitimate Phase 1
  stand-in (real, writable, no native code needed) but it is *not* the
  product experience doc §67 describes ("choose storage" implies the user's
  own folders) — treat this as resolved only once `SafStorageBackend` lands
  and the onboarding storage screen's second option goes live.
- **R-16.** `DeleteItemsToRecycleBin`'s `_ensureRecycleDirectory` and the new
  onboarding `.vaultbox` marker both rely on `createDirectory` throwing
  `PathConflictFailure` specifically for "already exists" — confirmed true for
  both backends in the contract tests, but any future backend implementation
  must preserve that exact failure type for this idempotency trick to keep
  working; a backend that throws a different failure for "already exists"
  would make onboarding fail on second launch.
- **R-17.** `test/data/drift_repositories_test.dart` uses
  `NativeDatabase.memory()`, which needs a resolvable libsqlite3 on whatever
  machine runs `flutter test` (usually present on macOS out of the box; may
  need `libsqlite3-dev` or equivalent on Linux). If this specific file fails
  to even load rather than failing an assertion, that's almost certainly the
  cause, not a bug in `DriftStorageRootRepository`/`DriftRecycleBinRepository`
  themselves — the other test files don't have this dependency.
- **R-18.** `AppDatabase`'s default constructor calls `driftDatabase(name:
  "vaultbox")`, which per drift_flutter's own docs opens
  `getApplicationDocumentsDirectory()/vaultbox.sqlite` — the same directory
  onboarding's "this phone" storage option writes user files into (see
  `onboarding_actions.dart`). Sharing one directory for both the database and
  user-visible files is fine functionally (different filenames, no
  collision), but it means a future SAF-backed "real" storage root should
  NOT reuse this same directory-resolution logic for its own bookkeeping —
  worth an explicit check when Phase 2 lands, not an assumption that it's
  already separated.
- **R-19.** `SafStorageHostApi.kt`'s method signatures (sync vs. `suspend
  fun`, exact enum constant names) are this session's best-faith guess at
  what `dart run pigeon` generates for the spec in `pigeons/storage_api.dart`
  — flagged in three places (the spec file, the Kotlin file's header, and
  here) rather than asserted as correct. Diff against the real generated
  `StorageApi.g.kt` before trusting any signature; the SAF call bodies
  underneath (DocumentFile/DocumentsContract/ContentResolver usage) don't
  depend on this and are standard, documented Android APIs.
- **R-20.** `SafStorageBackend`'s `openWrite` in replace mode truncates an
  existing SAF document in place — there is no SAF-native atomic
  temp-then-rename the way `DirectPathStorageBackend` gets from a real
  filesystem. A failed replace-mode write can leave old content gone and new
  content incomplete. `capabilities().supportsAtomicReplace` reports `false`
  specifically so callers don't assume otherwise, but nothing upstream
  currently *changes behaviour* based on that flag — worth revisiting once a
  SAF root is real and this stops being a theoretical gap. A real fix exists
  (temp sibling document + delete-old + rename-new) and is documented inline
  where the gap is, deferred rather than half-built.
- **R-21.** `SafStorageBackend._resolveDocumentId` walks one `listChildren`
  native call per path segment, every time — no caching. Fine for the
  shallow trees Onboarding + Files will hit first; will visibly slow down
  deep hierarchies. A documentId cache keyed by `StoragePath` is a
  contained, non-breaking follow-up (noted on the class itself, not just
  here).
