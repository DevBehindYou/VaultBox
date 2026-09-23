# VaultBox — Chat Log

A condensed record of the conversation between the user and the AI agent (Claude Code), session by
session: what was asked, what was decided and what happened. Written on 2026-09-21 at the user's
request. It is a summary, not a verbatim transcript; short user messages are quoted exactly. The full
transcript lives on the user's machine only, under `~/.claude/projects/…/c3650b8d-….jsonl`, and is not
part of the repository. Times are UTC, taken from the transcript.

Companion files: [EDIT_LOG.md](EDIT_LOG.md), [ROADMAP.md](ROADMAP.md), [TASKS.md](TASKS.md).

## Standing rules from the user (still binding)

| Rule | The user's words (or close) | Consequence |
|---|---|---|
| No local SDK | "I don't have enough storage in my device to install the Flutter/Dart SDK and Android SDK. So, use alt for that like GitHub workflow to build and test the app." | Never install Flutter/Dart/Android SDK locally. GitHub Actions is the only build and test machine; results are read from the `ci-reports` branch. |
| Few pushes | "Don't push to git to test every time, it will consume the GitHub workflow limit." | Commit locally as often as useful, push only at a milestone, review new code by reading before pushing, fix all CI failures in one batch. |
| Docs only on request | "Don't handover the docs overtime, only i tell you to do so." | `docs/ai-handover/` is not refreshed routinely. The files in this folder exist because the user asked for them on 2026-09-21. |
| Keep moving | "Keep working and automatically move the next phase, we will run the mobile test after phase 6." | Build phase after phase; the full phone test happens after phase 6. |
| Branch safety | (agreed on day one) | Work only on `ci/bootstrap`; never push to `main`; no PR or merge without the user's OK; the repository is public, so no secrets. |
| Phone rules | User's rooted Android 14 phone (adb `5ff095c7f80a`) | Keep reads app-scoped; do not alter the device with root; do not tap system permission dialogs; do not create accounts or type passwords (the user does); ask before any download; `adb uninstall` before installing a newer debug APK (signing keys differ per run). |
| Reply style | `/caveman ultra` (2026-09-19) | Terse replies in chat; normal prose for commits, docs and memory. |

---

## Session 1 — 2026-09-18 (15:19 – ~21:56): analysis, CI bootstrap, first phone test

**Request:** "Analyze VaultBox project's every file and start building the app carefully and accordingly", together with a long protocol asking for a complete AI-agent handover package.

**What happened**

1. The agent read every source file and found real defects by inspection (same-folder Replace data loss, path decoding, null dereferences, database inside the file root, a synchronous Pigeon call) and confirmed the README's "never compiled" was literally true.
2. No Flutter/Dart on the machine. The agent offered a 1.8 GB SDK download; the user declined (rule above) → decision: **GitHub Actions is the build machine**, with a `ci-reports` branch as the log channel.
3. The user made the repo public ("I have made the repo public."), installed the GitHub CLI ("I have also installed the GitHub CLI."), asked which option to pick in the login prompt, and finished `gh auth login` ("Done its connected."). The user had also pushed everything to `main` (`37f1d60`); the agent branched `ci/bootstrap` from it.
4. CI runs #1–#7 took the project from "cannot resolve dependencies" to green (100 → 111 tests), with the APK building. Fixes are listed in [EDIT_LOG.md](EDIT_LOG.md).
5. "I have my phone with Rooted USB debugging and you check the app whit my phone if i connect it." The agent installed the CI APK over adb, drove the app with screenshots (the many image messages), found a dark-mode contrast bug and a debug-signing mismatch, and fixed the first. Persistence across cold restart worked.
6. "Move to next phase." → SAF wired in, "Add files" built. "Continue". "Sure, perform the Phone test, then move to next phase." → second device round with screenshots. "go". "Yes move to phase 3."

**Outcome:** green CI, first device test passed, handover package written, phase 3 started.

## Session 2 — 2026-09-19 (09:05 – ~18:03): phases 2–4, then phase 5

**Requests:** "Continue" (several times). At 13:49 the user switched the reply style with `/caveman ultra`. Around 13:43 the user gave the push-limit rule.

**What happened**

- **Phase 2:** foreground service + headless Dart engine + Pigeon state stream (`aabe0f0`).
- **Phase 3:** auth core (Argon2id, sessions, throttle), HTTPS with a Keystore-protected self-signed certificate, admin account, plain-HTTP opt-in, login/files API, download tickets, the browser portal.
- **Phase 4:** WebDAV (class 1+2) over a shared `StorageGate`/`FileTransfer` layer.
- **Phase 5 started:** roles, folder grants, share links, public pages.
- Found on the phone: notification permission not requested; server card said nothing was exposed while it was. Both fixed.
- The agent had been pushing after every small fix (about ten runs in a few hours); the user objected and the push-limit rule was recorded.

## Session 3 — 2026-09-19 (18:21) – 2026-09-20 (~13:52): phases 5–6, CI log fixes, clean-up

**Requests:** "Continue"; "Yes, go ahead" (permission to download and install the CI APK); several phone screenshots; `@logs_96148747072.zip` "Here is the workflow error log file, fix the issues."; "Try again"; "For now clear the cache and stuff but not the important stuff." (The user also sent "Stop the process for now." at least once earlier in the project; the agent stopped each time.)

**What happened**

- Phase 5 finished (Share tab, people screens, QR, link pages) and phase 6 built (Activity tab, Settings, Diagnostics, support bundle).
- CI on `d2e236a` failed some tests; the user supplied the failing-log zip; fixes landed as `7af7515`: **708 tests pass, analyze clean, APK builds**. CI was changed to print failures only so the report keeps every one.
- The APK from run `35509703865` was installed on the phone; Home, Activity, Settings, Diagnostics and Share were checked on the device. The rest of the phone test needs the user to create the admin account, add storage through the system picker and start the server.
- Clean-up: the agent deleted its own scratch APK folders, screenshots and logs (~1.2 GB) and kept the repo, memory, scripts and the user's Downloads zip.

## Session 4 — 2026-09-20 (14:30 – …): UI overhaul and FTP

**Request (14:43, with six screenshots — another phone's "Add storage" list, and VaultBox's Settings, Home, Files, Share and Activity screens):**

> "Okay, I can see that there is no server folder location option. Like, if we set up the server, what is the location of the file storage, or what is the folder name for both internal storage and external storage separately? Also, there is only the http and https server option; where is the FTP, SFPT, or other option? Like, if I want to set up the FTP file storage on my other phone through File Explorer, how can I do that (example in the image)? Also, the UI/UX seems clustered and does not look good and seems empty. Are you not following the UI/UX mockup I have given to you? The settings tab feels empty. Like, where is the security stuff? Go research online and add more functions in the app. Fix the app layout and introduce light mode."

**Questions the agent asked, and the user's answers**

| Question | Answer |
|---|---|
| Download the two design fonts (Patrick Hand, JetBrains Mono)? | Yes. |
| Which protocols? | **FTP + FTPS now; skip SFTP and SMB.** (SFTP is not possible in plain Dart: `dartssh2` is a client only. WebDAV already works in their other phone's explorer.) |
| Build order? | UI first, then FTP, then extras. |

**What happened**

- **M1 (UI) pushed as `bfff09c`:** fonts, light/dark/system theme, header on every tab, rebuilt Home, Settings hub with Protocols & Network, Storage & Volumes (the storage-location question), Security & Sessions, Appearance. CI: 820 pass, 1 fail, 14 warnings — fixed locally, not yet pushed.
- **M2 (FTP/FTPS) written locally, not compiled:** server, settings, UI card, guide sheet, providers, tests for the UI. Design and file list are in [EDIT_LOG.md](EDIT_LOG.md).
- Research-derived extras were planned for M3 (see [ROADMAP.md](ROADMAP.md)).
- The conversation ran out of context more than once and was continued from summaries.

## Session 5 — 2026-09-21: pause and documentation

- Mid-review of the FTP session code the user said: "Stop the process for now." The agent stopped and reported state, including one bug found in review (`AUTH TLS` ordering).
- Then: "For now write the edits logs, chat logs, future roadmaps and tasks left, for this project in /docs folder." → this folder: `EDIT_LOG.md`, `CHAT_LOG.md`, `ROADMAP.md`, `TASKS.md`, `README.md`. Nothing was committed or pushed for it (docs-only pushes do not trigger CI).

---

## Decisions that came out of the conversation

| # | Decision | Why |
|---|---|---|
| 1 | CI is the build machine; no local SDK | The user's disk cannot hold it. |
| 2 | Logs go to a `ci-reports` branch | Readable with plain `git`, no token; repo is public. |
| 3 | Own typed Pigeon picker instead of `file_picker` | The plugin was days old and changing shape; the bridge already existed. |
| 4 | Foreground service owns the server (ADR-006) | Android kills Activities, not services with a notification. |
| 5 | HTTPS default; plain HTTP is a warned opt-in that answers private networks only | Safety on the LAN. |
| 6 | One `StorageGate` + `FileTransfer` for API, WebDAV and FTP | A rule cannot hold on one door and be missing on another. |
| 7 | FTP: explicit FTPS recommended, implicit FTPS optional, plain FTP warned and private-network only; passive mode only; no anonymous access | Encrypt by default; prevent "bounce" attacks. |
| 8 | SFTP and SMB skipped | No server-side SSH in Dart; SMB out of scope. WebDAV/FTPS cover the use case. |
| 9 | Design system "Aurora Glass" from the user's mockups, with a light/dark/system choice | The user asked for mockup fidelity and light mode. |
| 10 | Batch pushes, one CI read per milestone | Protect the GitHub Actions allowance. |
