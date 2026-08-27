# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->


## Reference Implementation: ../comelit (Python)

**There is a prior, working Python implementation of this system at `/Users/ebowman/src/comelit`.
Consult it before designing or implementing any Comelit-facing feature.** This Swift app is a
re-implementation of a subset of it; much of the protocol knowledge here was won the hard way
there, through live reverse-engineering against real hardware.

It is a FastAPI + vanilla-JS webapp (`app.py`, `static/index.html`) over a `comelit/` package:

| Area | File | What it covers |
|---|---|---|
| OAuth2 + PKCE login, token cache & refresh | `comelit/auth.py` | The auth flow this app's `ComelitAPI`/`TokenManager` mirror |
| Endpoint discovery, open-gate | `comelit/client.py` | REST shapes, endpoint filtering |
| **Live door-camera video over WebRTC** | `comelit/video.py`, `comelit/webrtc_page.html` | The hardest part of the whole system — see below |
| HTTP surface | `app.py` | `/api/endpoints`, `/api/open/{gate}`, `/api/video/stream` (MJPEG) |
| Tests | `tests/` | `test_auth`, `test_client`, `test_video`, `test_ui`, `test_app` |

### The video pipeline was extremely hard to get working — read the notes before touching it

Door-camera video is NOT a simple WebRTC client. An `aiortc` implementation completed signaling,
ICE, and DTLS successfully and still received **zero RTP video packets**. The door station
appears to fingerprint the WebRTC stack and only sends real media to a genuine libwebrtc
implementation. The working solution drives a **headless Chromium via Playwright** as a real
libwebrtc client, then scrapes frames from a `<canvas>` as JPEGs and serves them as MJPEG.

Load-bearing details, all discovered empirically:

- Signaling is a **single round trip, no trickle ICE**: `PUT
  /servicerest/devicecom/endpoint/<ENDPOINT_ID>/rtc/offer` with `{"sessionId": uuid4, "offer": <full
  SDP with all candidates inline>}` → `{"answer": <SDP>}`. Wait for `iceGatheringState === 'complete'`
  before sending.
- `addTransceiver('audio', recvonly)` **before** `('video', recvonly)` — the door's answer generation
  is sensitive to m-line order.
- Chromium needs `--force-webrtc-ip-handling-policy=default`, or mDNS `.local` ICE candidates make
  `rtc/offer` return HTTP 500.
- The door streams for only **~28–30s per session**, then stops; a new session needs a fresh cloud
  round trip.
- The bearer token is deliberately kept in Python and never handed to the browser page.

### `bd memories` in ../comelit is the real archive

`/Users/ebowman/src/comelit` has its own beads database with **~28 memories**, many documenting
video dead ends in detail — and several are explicit *corrections superseding earlier theories*.
When researching a Comelit behavior, run `bd memories <keyword>` **in that repo** and prefer the
latest correction over any earlier claim. Start here:

```bash
cd ../comelit && bd memories video
```

Key ones: `comelit-video-solved-2026-08-25-the-door` (the fingerprinting conclusion),
`comelit-video-libwebrtc-fingerprint-theory-confirmed-on-2026`,
`comelit-door-video-liveness-the-door-siwl-sends` (the ~30s limit),
`comelit-video-black-screen-dies-at-30s-bug` (STUN hostname resolution in headless Chromium),
`comelit-video-protocol-captured-live-signaling-is-one`, and the several
`comelit-video-*-disproven`/`-correction-*` entries recording what does NOT work.

**Do not re-derive any of this by experiment.** If a Comelit question looks like it needs live
testing against the hardware, check `../comelit`'s memories first — it has very likely already
been tested there, and repeating a failed approach costs hours.

## Build & Test

_Add your build and test commands here_

```bash
# Example:
# npm install
# npm test
```

## Architecture Overview

_Add a brief overview of your project architecture_

## Conventions & Patterns

_Add your project-specific conventions here_
<!-- BEGIN domestique (managed) -->
# Orchestration policy

This session is the **orchestrator**. Your job is planning, delegation, and review — not implementation.

## Roles
- **You (main session, planning model):** decompose work, hold the plan, delegate implementation and review, adjudicate the results, decide what's next. Write code yourself only for trivial one-line edits.
- **`implementer` subagent (Sonnet):** executes one bounded task at a time in its own context and reports back a summary.
- **`reviewer` subagent (Opus):** independently verifies a completed task in a fresh context — inspects the real diff, reads the changed files, runs the tests — and reports a pass/fail verdict against the bead's done-criteria. A stronger, non-peer check than the implementer. Does not fix anything; reviewing is its only job.

## Work tracking: beads
- The plan of record lives in beads (`bd`), not in markdown TODO lists.
- Decompose a goal into an epic + bounded tasks with dependencies using `/decompose`.
- Select the next unit of work with `bd ready` — it returns only unblocked, actionable tasks.
- Record durable insight with `bd remember "<insight>"`. Do not create MEMORY.md files.

## Writing briefs
Plans, bead descriptions, and delegation briefs are executed by a separate model with no access to your reasoning. When you write them:
- Write numbered steps; each step names an action, a target file/symbol, and an acceptance criterion.
- Spell out edge cases and error handling — do not leave them implicit.
- Flag ambiguities explicitly rather than resolving them silently.

## Delegation loop
1. `bd ready` → pick the highest-priority unblocked task.
2. Delegate it to the `implementer` subagent with a precise brief and the bead id.
3. When the implementer returns, delegate verification to the `reviewer` subagent with the same bead id and its done-criteria. The reviewer inspects the real diff, reads the changed files, and runs the tests in a fresh context — judging the work against the done-criteria, not against the implementer's summary — and returns a pass/fail verdict.
4. Adjudicate. Weigh the reviewer's verdict against the implementer's summary: if they agree the work is done, close the bead and commit its changes (one commit, bead id in the message); if the reviewer reports gaps, reopen the bead or file a follow-up and route the fix back to the implementer. Read the diff yourself only when the two reports conflict or the verdict is ambiguous — delegating the review is the point.
5. **Stop and report to the human before dispatching the next task.** Do not drain the queue unattended unless explicitly told to.

## Unattended epic mode (/goal)
- The default remains **stop-and-report between beads** (rule 5 of the Delegation loop above). Nothing changes that by itself.
- A `/goal <epic-id>` invocation is the **only** thing that authorizes continuous, unattended dispatch across an epic's beads. That authorization is scoped to the named epic, expires the instant the epic completes or any stop condition fires, and never carries over to another epic or a later session.
- Unattended runs happen on a **dedicated epic branch** and never commit to the default branch — the human reviews and merges that branch by hand; the loop never merges or pushes.
- The core invariants still hold even while unattended: **one bead in flight at a time, one commit per bead, and never close a bead the reviewer didn't pass.**
- For the full loop mechanics and the complete list of stop conditions, see `.claude/commands/goal.md` — they are not restated here.

## Discipline
- One task in flight at a time. Bounded WIP.
- Subagents return summaries, never full file dumps. Your context is the constraint — keep it lean, don't re-read large outputs.
- Do not spawn agent teams for this sequential pipeline. Subagents only.
- At session end ("land the plane"): file any loose discovered work as beads, then export and commit (`bd export`, then commit `.beads/`). `bd export` writes the git-tracked `.beads/*.jsonl` — that JSONL is the versioned snapshot. There is no `bd sync`; bd is Dolt-backed now, and `bd dolt commit` records local Dolt history only (`.beads/dolt/` is gitignored, so it never affects a clean tree).
<!-- END domestique -->
