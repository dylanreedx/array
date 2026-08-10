# Improvement backlog

Small, self-contained improvements — each is one focused session or less.
Bigger designed work gets a numbered plan file (see `01-provider-cli-backends.md`).
Program history: `docs/38-tickets/95-go-live.md`. **Shipped state: 0.3.0 (build 5),
live on arrayapp.dev 2026-08-10; next release is build 6.** `main` ==
`array/integration`, tree clean. Dylan is **daily-driving Array Dev and
reporting what he notices** — "we are so close to using it as a daily driver".
Work is unreleased and accumulating for build 6.

**Start here:** the NEXT UP section below (agent close/delete + history tab) is
his most recent report and is not started.

## Unreleased on `array/integration` (all of this rides build 6)

Dylan is dogfooding these in Array Dev (`~/Desktop/Array Dev.app`, rebuilt and
relaunched after each change) and reporting what he notices. None of it is in a
release yet.

- **Drag-drop non-image files** (`61983d8`, plan `04`): md/pdf/xml/txt/code drop
  or paste onto a composer as `@/path` references the agent Reads; images still
  embed. Gaps in the plan: codex's `workspace-write` sandbox may refuse a file
  dropped from outside the project; PDF-read parity varies by harness.
- **Status row correctness** (`92c07da`): the row had no clock — elapsed froze at
  the last event and jumped. Added a 1s tick while a live phase shows, made a
  ready session with no active turn authoritative over stale observations, and
  made idle/unknown render as SILENCE rather than a "Ready"/"Unknown" chip.
- **Live status on the prism gyro** (`204b2ac`): live work (thinking/reading/…)
  now rides the gyro at the transcript tail with its elapsed; the footer keeps
  only attention states (waiting/failed/interrupted) and is silent otherwise.
  Split by KIND because the gyro is absent exactly when a failure happens.
  Three latent layout bugs surfaced and were fixed: the context meter had no
  size constraints (collapsed to 0pt), toggling an arranged subview's visibility
  never re-laid the row out (context label stuck at 4pt), and the activity label
  could neither truncate nor yield so it crushed the context reading.
- **Context meter actually fills** (`6629c0b`): the ring had NEVER worked — it
  required `.providerSessionStats`, which nothing emits. Window size now comes
  from pi's models-store `contextWindow`; occupancy from the last turn's prompt
  tokens, composed per provider (claude sums cache counters, codex must not,
  pi abstains). Stale readings show their number, not the word "stale".
  **Limitation:** last-turn accurate, does not climb mid-turn — no harness
  reports usage until turn end.

## NEXT UP — Dylan-named, 2026-08-10, not started

**Closing/deleting an agent behaves weirdly; the sidebar fills with agents that
have no tile.** In his words: *"close/deleting agents seem weird, they go to
unconfirmed... they should be deleted for the most part, there could be a
recovery tab, history tab, to see closed previous sessions and to open and
resume the tile, but i see so many agents in my sidebar but i dont have that
many tiles opened"*.

Two things to separate before designing:
1. **Closing a tile ≠ deleting an agent.** Today closing appears to leave the
   agent record alive and merely UNOBSERVED, which the inbox renders as
   "Unconfirmed" (an unobserved agent is unconfirmed, never working — that rule
   is deliberate, see `ContinuumApp.swift` ~21887 and P3.4's frozen clock at
   ~22018). So the sidebar accumulates rows for agents whose tiles are gone.
   Dylan's expectation: closing should mostly DELETE.
2. **He wants the recoverable ones somewhere else** — a history/recovery tab
   listing closed sessions, from which a tile can be reopened and resumed.
   Transcript resume already exists (plan `03`), so reopening has a foundation.

Starting anchors: `AgentStatusVocabulary.unconfirmed`
(`Sources/ContinuumRevivedAgentUI/AgentInboxRow.swift:250`, applied at :940),
`unconfirmedFreeze` (`ContinuumApp.swift:3190`, used ~7530), the inbox row
builder, and whatever the tile-close path does to the agent record (find it
before assuming — the delete/close seam was NOT located in this pass).

Design questions for Dylan when it starts: does closing delete immediately or
soft-delete into history; what happens to the provider session file and the
composer draft; is history per-project or global; does reopening resume the same
session id or fork a new one.

### Follow-ups these opened

- **pi occupancy abstains.** `AgentContextOccupancy` returns nil for
  `.piMessageUsage` because pi's docs don't say whether `input` already includes
  cache. Verify against a real pi run and add it — until then pi-run agents get
  no ring even though the window size is known.
- **Live (mid-turn) context reading** would need per-delta accounting; nothing
  provides it today. Only worth it if the last-turn reading feels stale in use.
- **Effort-picker truncation** is still unconfirmed (see below).

## Recently shipped (0.3.0, 2026-08-10)

- Agent-harness picker (Claude Code / Codex / pi) + codex & claude CLI backends
  (`01`, `02`); transcript resume (`03`).
- Fixes: markdown tables render (was "Unsupported content: unknown"); context
  meter shows token counts for claude/codex (was "unknown"); rehydrated tool
  cards show the command (was opaque "Bash"); custom-folder Home updates the
  header.
- **Effort-picker truncation (#4): HARDENING ONLY, unconfirmed.** Could not
  reproduce in a headless test; footer now declares fill intent in the Send row.
  If it still truncates in 0.3.0, get the tile WIDTH from Dylan and reproduce.

## Verification debt

- **Clean-machine pass** (release-blocking, needs a second Mac/account): install
  0.2.2 from arrayapp.dev fresh — witnesses Gatekeeper, first-run onboarding on a
  true fresh profile, next release's real-feed update. Colleague #1's install
  effectively runs it; collect their report.
- **Component-lab pixel baselines re-bless** (~36 stale, KNOWN-RED): supervised
  `CONTINUUM_UPDATE_BASELINES=1` run with Dylan reviewing image diffs. Don't
  re-bisect — verified pre-existing at `566e615`.
- **agent-supervisor-check naming flake** (KNOWN-RED): pre-existing at `566e615`
  and re-verified pre-existing on 2026-08-10 by stashing all work and rerunning.
  It is NOT always the "different message each run" flake — on 2026-08-10 it
  failed identically on repeat runs with `a prompt equal to a model id produced
  an identifier-shaped display name`. Fixing it un-gates everything behind it.
- **A THIRD red leg hides behind the supervisor one** (found 2026-08-10): the
  matrix halts at `--agent-supervisor-check` (line 230 of ~402), so ~110 legs
  never run in a normal invocation. On one run where the supervisor leg happened
  to pass, the matrix reached an ssh/tmux leg that then failed with
  `TmuxSession.swift:54: Fatal error: tunnel reach path not yet wired` +
  `ssh-wrapped LaunchProfile should create real tmux session …`. Almost
  certainly environmental (ssh-to-localhost in this shell), but it is UNVERIFIED
  and nobody has been seeing it. **To verify the legs past the halt, run them
  directly** — the recipe used all session:
  `awk 'NR>230 && /^run_app_check \.build\/debug\/Array --/{print $3}' scripts/run-matrix.sh`
  then run each with `CONTINUUM_PROJECT_ROOT`/`CONTINUUM_APP_SUPPORT` temp dirs,
  passing `-continuum.terminal.tmux.enabled NO -continuum.terminal.tmux.path ''`
  for every flag EXCEPT `--terminal-tmux-*` / `--terminal-theme-fidelity-check`
  (run-matrix.sh omits those args for exactly those legs; forcing tmux off makes
  them fail spuriously). All 110 were green after every change this session.
- **`--agent-location-live-check` is not in the matrix** and needs a multi-fixture
  launch env (`CONTINUUM_LOCATION_LIVE_EXTERNAL`, plus an "inside" fixture it
  asks for next). It fails at its precondition without them; not a regression.
- **Skipping the baseline leg** to reach the rest: `CONTINUUM_SKIP_UI_BASELINES=1
  scripts/run-matrix.sh`. To prove a UI change added no baseline regressions,
  diff the failing-render list against pre-change HEAD (stash, rebuild, rerun
  `--component-lab-check`, compare) rather than trusting the count — the count
  was 88 all session, and an early abort can make it read as 0.
- **matrix-inventory drift → Array rename** (RESOLVED 2026-08-09): the committed
  `docs/38-tickets/90-agent-ux/matrix-inventory.txt` still listed
  `.build/debug/continuum-revived` legs while run-matrix.sh had moved to
  `.build/debug/Array` — the matrix's FIRST leg had been red since the identity
  cut (undocumented, not one of the two KNOWN-REDs). Re-blessed with
  `CONTINUUM_UPDATE_MATRIX_INVENTORY=1`. If it recurs, that means a binary rename
  landed without a re-bless again.
- **iOS shared-Core break** (RESOLVED 2026-08-09): `AgentModelCatalog`'s probe
  spawned `Process` ungated, reding the iOS matrix leg since the catalog landed.
  Now `#if os(macOS)`. Watch for the same trap in any new Core file that shells out.

## How this phase runs (worked well — keep doing it)

Dylan is using Array as his daily driver and reporting what he notices. The loop
that has been working: he names a symptom → investigate in the code before
theorising → state the diagnosis and the design decision, asking only when the
answer changes what gets built → implement with a witness → teeth-verify →
matrix → commit → rebuild AND relaunch `~/Desktop/Array Dev.app` so he can look
at it immediately. He runs Array Dev from the **Desktop**, not `~/Applications`.

**The witness trap, hit three times in one session — check for it every time.**
A probe that re-derives what production derives will pass while production is
broken. Concretely: (1) the drag-drop witness rebuilt the prompt itself instead
of driving `composerRequestedSend`, and stayed green when the send assembly
dropped file references; (2) the tick witness read the row's elapsed before and
after a repaint, but both reads hit the same view object, comparing the new
value to itself; (3) the QA seam `qaApplyCompactStatusFacts` skipped the footer
filter production applies, so it witnessed a surface no user sees. **Always
drive the real entry point, and capture values BEFORE the mutation.** Every fix
this session was teeth-verified by reverting the specific change and confirming
the specific assertion fired — do that, not a vibes check.

**Measure before theorising about layout.** Two guesses at the context-label
squeeze cost a build cycle each; one env-gated frame dump found it immediately
(`4 × 11 pt` = exactly the 176 device px the failure reported). Failure messages
now print widths and the drawn string — keep that habit.

## Picker / composer polish

- Keyboard provider switching in the model picker (left/right between rail and
  pane; today the rail is click-only).
- Search field in the picker (t3 parity — worthwhile once catalogues grow).
- Show unauthed providers in the rail as disabled with a sign-in tooltip (today
  the rail only lists authed providers, so anthropic is invisible until login).
- Provider glyph in the composer trigger (t3 parity; today title+chevron only).
- Context-window column in picker rows (pi's models-store has the data).

## Onboarding

- Async probes: the two `pi auth check` subprocesses run synchronously on
  panel-open/re-check (~1s main-thread hitch). Move to background with
  "checking…" placeholders.
- Managed-agent-without-pi UX: a spawn with no pi should point at Environment
  Setup instead of a raw failure.
- Surface tmux silent degradation (persistence quietly off when tmux missing)
  as an env-check consequence line.
- Ticket 42 (claude notification-hook consent): build the installer/consent
  store; its home in the panel is reserved.

## Parked for Dylan's review

- Three unmerged `agent/luna-max-implementer-20260809T130553Z-*` tip commits
  (live-tile projection prototypes).

## Bigger designed work

- `04-drag-drop-files.md` — **SHIPPED 2026-08-10** (unreleased, rides build 6).
  Drag-drop md/pdf/xml/txt as `@/path` references the agent's Read tool fetches;
  images stay embedded. Remaining questions (codex `workspace-write` sandbox for
  out-of-project drops, PDF-read parity) are recorded in the plan and were left
  open deliberately.
- `03-transcript-rehydration.md` — **SHIPPED 2026-08-10** (MVP: resume shows the
  prior transcript behind a "Previous session" boundary, read from the provider
  session file and replayed as events; display-only, never re-synced). Fast-follows
  NOT built: the collapse/disclosure "summary that expands" grouping, and
  expand-to-see tool OUTPUT (the reader has the on-disk result; only the command
  is surfaced today).
- `02-codex-backend-and-toggle.md` — **SHIPPED 2026-08-10** (codex CLI backend so
  pi isn't required + a three-way Agent Harness toggle in Settings that live-filters
  the model dropdown: pi/Claude Code/Codex, codex↔openai, claude↔anthropic).
  Sandbox = `workspace-write` (one-line flip to `danger-full-access` if Dylan wants
  claude parity). Remaining: codex has no token streaming (reply lands whole);
  formal `ManagedAgentBackend` protocol extraction; a tool-approval dock for all
  harnesses.
- `01-provider-cli-backends.md` — **claude backend SHIPPED 2026-08-09**
  (anthropic models run on the user's own Claude Code login, no pi, no extra
  usage; routing + translator + runner + catalogue union + onboarding +
  witnesses). REMAINING: codex CLI backend (low priority — no teammate uses
  codex), the formal `ManagedAgentBackend` protocol extraction, and a
  tool-approval dock for both backends. Compliance research recorded in-plan.
