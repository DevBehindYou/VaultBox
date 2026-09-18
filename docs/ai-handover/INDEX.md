# AI Project Handover

## Project
VaultBox (Flutter/Android phone-as-NAS) — `github.com/DevBehindYou/VaultBox`

## Last Updated
2026-09-18 — Session 1. Latest green commit `4bd1af5` on branch `ci/bootstrap` (CI run 35366984098).

## Handover Purpose

This directory contains the project state and AI-session context required for another AI agent to continue development without reviewing the entire previous conversation.

## Recommended Reading Order

1. HANDOVER.md
2. PROJECT_CONTEXT.md
3. CURRENT_STATE.md
4. CHANGES_MADE.md
5. ERRORS_AND_FIXES.md
6. PENDING_TASKS.md
7. NEXT_AGENT_INSTRUCTIONS.md

## Documents

| File | Purpose |
|---|---|
| HANDOVER.md | Executive handover |
| PROJECT_CONTEXT.md | Project goals, requirements, user corrections, constraints |
| SESSION_HISTORY.md | Chronological work history |
| CURRENT_STATE.md | Verified implementation state, environment, git/CI state |
| CHANGES_MADE.md | Changes performed (problem → cause → fix → verification) |
| FILES_CHANGED.md | File-level modification record |
| ERRORS_AND_FIXES.md | Bugs, errors, diagnoses, fixes, failed approaches |
| COMMANDS_AND_LOGS.md | Commands, run table, verbatim log excerpts, how to read CI |
| ARCHITECTURE.md | Existing architecture vs proposed improvements |
| DECISIONS.md | Technical decisions (this session + inherited) |
| TESTING_STATUS.md | What was tested where, and the gaps |
| PENDING_TASKS.md | Prioritised remaining work + new risks |
| NEXT_AGENT_INSTRUCTIONS.md | Exact continuation instructions, the CI loop, do-not-repeat list |

## One-paragraph orientation
The code compiles, analyzes clean, passes 108 tests and builds a debug APK — **only in GitHub Actions** (the user cannot install SDKs). It has never run on a device. Results are readable via `git fetch origin ci-reports`. Work is on `ci/bootstrap`, not yet merged. Start with PENDING_TASKS P0.
