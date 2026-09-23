# VaultBox — Roadmap

Where the project is going, in order. Written on 2026-09-21 at the user's request. It builds on the
original phase table in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) §F and reflects what has
actually happened since. Companion files: [EDIT_LOG.md](EDIT_LOG.md), [CHAT_LOG.md](CHAT_LOG.md),
[TASKS.md](TASKS.md).

VaultBox turns an Android phone into a personal storage server that other devices on the same network
reach through a browser portal, WebDAV or FTP/FTPS. Everything runs inside the app, files stay in the
storage locations the person picked, and nothing is ever opened to the internet.

## 1. Phase status against the original plan

| Phase | Scope | Status |
|---|---|---|
| 0 — Foundation | Layout, Riverpod, go_router, design tokens, Drift, Pigeon | **Done** |
| 1 — Storage and local file manager | Storage backends (memory, direct path, SAF), browse/copy/move/delete/restore, Recycle Bin, import | **Done.** SAF byte I/O for very large files is not yet proven on a device. |
| 2 — Server host | Foreground service, headless Dart engine, state to the UI | **Done** |
| 3 — HTTPS portal and auth | TLS, admin login, sessions, browser portal | **Done** |
| 4 — WebDAV | Class 1+2 at `/dav/` | **Done** |
| 5 — Users and sharing | Roles, folder grants, share/upload links, QR | **Done** |
| 6 — Activity and diagnostics | Transfers, clients, events, diagnostics, support bundle | **Done** |
| UI overhaul (M1) | Mockup-faithful design, light/dark, settings hub | **Done** (`bfff09c`, CI fixes in `6587038`) |
| State management rewrite | Riverpod → `flutter_bloc`, full replace at the user's request | **Done** (`39f716d`..`16fc00f`), confirmed green: analyze clean, both APKs build, 927/942 tests (15 known non-gating flake) |
| 9 — FTPS (pulled forward as M2) | FTP / FTPS server and UI | **Done**, compiled, tested, green on CI (`6052175`, `2ffdaf0`) — not yet confirmed on a real device |
| 7 — Security hardening | Throttling, tokens, secret storage, headers | **Partly done** inside phases 3–6 (Argon2id, throttling, sessions, Keystore, CSP/HSTS); rest below |
| 8 — Vault and privacy | `.nomedia`, camouflage, encrypted Vault | Not started |
| 10 — Production hardening | Performance, OEM lab, accessibility, localization, release | **Launcher icon and splash screen done** (`7004190`, real content pending a CI-outcome confirmation); release APK builds in CI (debug-signed, not a real release key yet); rest not started |

## 2. Near term

### M2 — FTP / FTPS — done on CI, needs a device confirmation
Compiled, tested and green (see [TASKS.md](TASKS.md) section A). Still needs: install a debug APK and
confirm FTPS actually works from a PC client (FileZilla/WinSCP) and the user's other phone's file
explorer — nothing has touched real hardware yet.

### Device-test follow-up (in progress)
The user's first real-device pass over a release APK found the app icon, splash screen and web portal
favicon genuinely missing — now fixed (`7004190`, pending a CI-outcome confirmation — see
[TASKS.md](TASKS.md) state-in-one-line). Several other reports (light mode, storage folder choice,
server notification) turned out to already exist in code; two (general layout, portal "usability")
are waiting on a screenshot or more specific description from the user before anything can be built —
see [TASKS.md](TASKS.md) section E.

### M1.5 — restyle the rest to match the mockups
- Files tab: volume cards, search bar, breadcrumb and sort row, rows as cards (mockup `files_storage_explorer`).
- Onboarding screens (welcome, storage, admin, ready) in the new design.
- A dark-theme and light-theme visual pass over every screen, including Recycle Bin, Share, Activity.

### Phone test round (needs the user)
After the user creates the admin account, adds storage through the picker and starts the server, test
from the PC: portal login, upload/download, WebDAV mount, share and upload links, Activity tab, then FTP.

### Land the work on `main`
Ask the user whether to open a PR from `ci/bootstrap` (or merge). Nothing goes to `main` without their OK.

## 3. M3 — extra functions (from the user's "research online and add more functions")

Ordered roughly by value for effort. All are Dart-only unless noted.

| Feature | Notes |
|---|---|
| Auto-stop timer | Server stops itself after N hours; logs a "server stopped" event. |
| Global read-only mode | A config flag enforced in `StorageGate`, so every protocol obeys it. |
| IP allow-list | Only listed addresses/subnets may connect; enforced once, in the listeners. |
| App PIN lock | PIN hashed in settings, lock on resume. Protects the app UI, not the server. |
| Regenerate TLS certificate | Needs native work in `TlsIdentityStore`; shows a new fingerprint and signs everyone out. |
| Notification actions | The foreground-service notification already has a "Stop" action (`ServerForegroundService.kt`); a "copy address" action would still need adding (native). |
| Hotspot information | When the phone is the hotspot, show the address others should use. |
| "Server stopped" and configuration-change events | Fill gaps in the Activity feed. |

Candidates to evaluate later (not decided): local-network discovery (mDNS), per-user quotas and upload
size limits, bandwidth limits, scheduled start/stop, two-factor sign-in for the portal, audit-log
export, a battery-optimisation prompt for aggressive OEMs.

## 4. Later phases

### Phase 7 — security hardening (remainder)
API tokens for scripts, secret storage review, IP allow-list and read-only mode (above), stricter
session controls, a security review of the FTP and public-link surfaces, dependency audit.

### Phase 8 — Vault and privacy
`.nomedia` handling so files stay out of the gallery, "camouflage" options, an encrypted Vault format with
a key hierarchy, and the tests that protect data during move and encrypt (the plan's top data-loss risk).

### Phase 10 — production hardening
- Release pipeline: `flutter build apk --release` already runs in CI (`e5ee506`), but signs with the
  debug keystore — still needed: a real signing key held in GitHub Actions secrets (never committed),
  R8/ProGuard rules for Drift and Pigeon.
- Stable debug signing so CI APKs update in place (needs the user's OK: it puts a debug keystore in a public repo).
- Performance: index-backed paging and server-side sort, SAF document-id cache, a real transfer engine with bounded concurrency and cancel.
- OEM lab: foreground-service survival on Xiaomi/MIUI and other aggressive battery managers, including whether its notification actually shows (device-test finding, 2026-09-23 — see [TASKS.md](TASKS.md) section E).
- Accessibility pass, localization, coverage in CI, `flutter_lints` bump. Launcher icon and splash screen are done (`7004190`) — icon quality is capped by the 160×184px source image; ask the user for higher-res art if it looks soft.
- Refresh `README.md`, `IMPLEMENTATION_PLAN.md` and `docs/ai-handover/` (only when the user asks).

## 5. Deliberately not planned

| Item | Why |
|---|---|
| SFTP | There is no server-side SSH library in Dart (`dartssh2` is client-only). FTPS and WebDAV cover the same need. |
| SMB | Out of scope for a Dart-only server; WebDAV mounts in the same file managers. |
| Internet exposure | VaultBox never opens a router port or relays traffic; local network only. |
| Anonymous FTP | Every connection signs in and sees only its own folders. |
| Active-mode FTP (`PORT`/`EPRT`) | Lets a client point the phone at another machine; passive mode does everything modern clients need. |

## 6. Working principles that shape the roadmap

- The build machine is GitHub Actions; nothing is installed locally, so each slice is written carefully, reviewed by reading, and pushed once.
- Every protocol reaches files through the same `StorageGate` and `FileTransfer`; a new door must reuse them.
- Encrypted by default; anything unencrypted is an explicit, warned opt-in restricted to private networks.
- The user does the steps that involve their passwords, system permission dialogs and account creation.
