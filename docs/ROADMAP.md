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
| UI overhaul (M1) | Mockup-faithful design, light/dark, settings hub | **Pushed** (`bfff09c`); small CI fixes pending locally |
| 9 — FTPS (pulled forward as M2) | FTP / FTPS server and UI | **In progress**, code written locally, never compiled |
| 7 — Security hardening | Throttling, tokens, secret storage, headers | **Partly done** inside phases 3–6 (Argon2id, throttling, sessions, Keystore, CSP/HSTS); rest below |
| 8 — Vault and privacy | `.nomedia`, camouflage, encrypted Vault | Not started |
| 10 — Production hardening | Performance, OEM lab, accessibility, localization, release | Not started |

## 2. Near term

### M2 — finish FTP / FTPS (in progress)
Fix the known `AUTH TLS` ordering bug, verify the never-compiled code against the real APIs, write the
protocol tests (raw-socket client, generated test certificate), commit, push once, fix CI in one batch.
Then confirm on hardware: FileZilla or WinSCP from a PC, and the user's other phone's file explorer.
Details: [TASKS.md](TASKS.md) section A.

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
| Notification actions | Stop / copy address from the foreground-service notification (native). |
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
- Release pipeline: release signing with a secret key held in GitHub Actions secrets (never committed), R8 rules for Drift and Pigeon, `flutter build apk --release` in CI.
- Stable debug signing so CI APKs update in place (needs the user's OK: it puts a debug keystore in a public repo).
- Performance: index-backed paging and server-side sort, SAF document-id cache, a real transfer engine with bounded concurrency and cancel.
- OEM lab: foreground-service survival on Xiaomi/MIUI and other aggressive battery managers.
- Accessibility pass, localization, launcher icon, coverage in CI, `flutter_lints` bump.
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
