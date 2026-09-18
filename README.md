# VaultBox

Turns an Android phone into a secure personal storage server / mini-NAS.
Local-first file manager, with an optional authenticated HTTPS + WebDAV + REST
server on top.

Full analysis, scope classification and phase plan: **`docs/IMPLEMENTATION_PLAN.md`**.
Read that before changing architecture.

---

## Status — read this first

Phase 0 (foundation) and the first half of Phase 1 (storage abstraction +
local file manager) are written. **Nothing in this repository has been
compiled, analyzed, or test-run yet**, because the environment it was authored
in had no Flutter/Dart SDK and no network route to Google's SDK servers.

Treat the first successful local run of the commands below as the real Phase 0
exit gate. Expect to fix things on that first pass — that's the plan, not a
surprise.

### Three things to verify first, before anything else

1. **`android/` does not exist yet.** It was deliberately not hand-written: a
   correct Gradle wrapper / AGP / Kotlin version triple is exactly the kind of
   version-sensitive artifact that should be generated, not typed from memory
   (KB vol2 §13.1 — "one wrong pair = cryptic sync failures"). Run
   `flutter create .` in this directory once; it generates `android/` and
   `ios/` around the existing `lib/` without touching it. Two Kotlin files
   are pre-staged under `android/app/src/main/kotlin/com/vaultbox/app/` for
   the SAF native bridge (see point 3) — `flutter create .` generating its
   own default `MainActivity.kt` alongside them is expected and fine; they
   live in a separate `storage/` subpackage so there's no filename collision.

2. **Riverpod 3.x API surface.** Checked against riverpod.dev's actual 3.0
   migration guide this build (not left as a guess) — see
   `files_view_model.dart`'s doc comment and IMPLEMENTATION_PLAN.md's R-12.
   The one thing that wasn't re-verified: that `flutter_riverpod: ^3.0.0` in
   `pubspec.yaml` actually resolves cleanly with everything else pinned here.

3. **The SAF native bridge is a first draft, not a verified one.** Pigeon's
   spec (`pigeons/storage_api.dart`), the Dart-side backend
   (`saf_storage_backend.dart`, fully unit-tested), and a Kotlin
   implementation draft (`SafStorageHostApi.kt`) all exist — but `dart run
   pigeon` has never actually been run (it needs `android/` to exist first,
   see point 1), so the Kotlin file's method signatures are this session's
   best-faith prediction of what gets generated, flagged as such in three
   places including that file itself. Reconcile before wiring it up.

---

## Setup

```bash
flutter create .          # generates android/ + ios/ around existing lib/
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # Drift codegen
dart run pigeon --input pigeons/storage_api.dart            # SAF native bridge codegen
dart format .
flutter analyze
flutter test
```

The codegen step is not optional once Drift tables and the Pigeon bridge land —
`*.g.dart` files are generated, not committed.

---

## What works today

- **Onboarding** — Welcome → Choose Storage → Ready. The one live storage
  option is the app's own private directory (real, writable, no native code
  needed); SD card / custom folder is shown but disabled until the SAF bridge
  lands.
- **Local file manager** — browse, page through large directories, sort,
  multi-select, create folder, rename, delete to Recycle Bin, **copy and
  move** (destination picker + conflict resolution: Replace / Keep Both /
  Skip, chosen once per batch).
- **Recycle Bin** — delete, browse what's in it, **restore**, and **delete
  forever** with explicit confirmation — all backed by a real (Drift/sqlite)
  database, so it survives a process restart.
- **Storage abstraction** (`StorageBackend`) with two real implementations:
  in-memory (tests/UI) and direct filesystem path.
- **Path-traversal-safe path model** (`StoragePath`) — rejects `..`, encoded
  and double-encoded traversal, absolute paths, backslash escapes, control
  characters, and copying a folder into itself.
- **Item-isolated batch operations** — one bad file never aborts the rest;
  results report "46 completed · 1 skipped · 1 failed".
- **Copy-verify-delete ordering** on every move — the source is never removed
  before the destination is confirmed.
- **Aurora Glass design system** — tokens, light + dark themes, shared widgets.

## What is deliberately not built yet

Server (Foreground Service, HTTPS, WebDAV, REST), users/ACL, sharing, Vault
encryption, FTPS, a transfer queue (copy/move run inline today, correct but
not yet bounded-concurrency/cancellable). Every one has a phase in the
implementation plan. The Share / Activity / Settings tabs show honest
placeholders naming their phase rather than fake-functional UI (kickoff §77).

**SAF (the real "pick any folder" storage option) is fully drafted, not
built-and-verified.** `SafStorageBackend` is a complete `StorageBackend`
implementation, unit-tested wherever pure Dart can test it. What's still
needed is running the real toolchain — Pigeon codegen, then reconciling the
pre-staged Kotlin implementation against what actually gets generated, then
wiring `MainActivity` — all human-run steps this sandbox couldn't perform.
Onboarding's SD-card option stays disabled until that's done.

---

## Architecture in one screen

```
View (features/*/presentation)
  ↓ watches
ViewModel (features/*/viewmodel — Riverpod Notifier)
  ↓ calls
UseCase (domain/usecases — batch orchestration, safety ordering)
  ↓ calls
Repository (domain/repositories — interface; data/repositories — impl)
  ↓ calls
StorageBackend (domain/repositories — interface; data/services — impl)
```

Non-negotiables, all from the technical docs:

- Every file operation in the app, from any protocol, goes through
  `StorageBackend`. No protocol package owns its own filesystem code (ADR-004).
- Client-supplied paths are never trusted. `StoragePath.parse` is the only way
  in (doc §42).
- Never delete the only valid copy of user data before its replacement is
  verified (doc §26).
- Recycle Bin is the default delete target; permanent delete is explicit
  (ADR-012).
- Never log a secret (doc §57).
- Streamed I/O only — never `readAsBytes()` on a user file (kickoff §12).

## Layout

```
lib/
├── app/          composition root, router, shell
├── core/         design tokens + widgets, errors, logging, utils
├── domain/       entities, value objects, repository interfaces, use cases
├── data/         repository + backend implementations (incl. Drift, SAF)
├── platform/     native bridge — AndroidStorageHost + its Pigeon adapter
└── features/     onboarding, home, files, share, activity, settings
pigeons/          Pigeon spec — generates the Dart+Kotlin storage bridge
android/          pre-staged Kotlin SAF implementation (rest generated by
                  `flutter create .` — see Setup)
test/
├── domain/       path security, batch isolation, move/restore/delete safety
├── data/         backend contract suite, Drift repos, SAF backend (metadata)
└── features/     widget tests, backed by in-memory fakes throughout
```
