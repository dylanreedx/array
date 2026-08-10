# Improvement backlog

Small, self-contained improvements — each is one focused session or less.
Bigger designed work gets a numbered plan file (see `01-provider-cli-backends.md`).
Program history: `docs/38-tickets/95-go-live.md`. **Shipped state: 0.3.0 (build 5),
live on arrayapp.dev 2026-08-10; next release is build 6.** `main` ==
`array/integration`. Dylan is in a "continuous improvements + tweaks" phase —
this is the menu; he picks what to run next.

## Unreleased on `array/integration` (rides build 6)

- **Drag-drop non-image files SHIPPED 2026-08-10** (`61983d8`, plan `04`):
  md/pdf/xml/txt/code drop or paste onto a composer as `@/path` references the
  agent Reads; images still embed. Not yet in a release — Dylan should dogfood
  it in Array Dev first. Known gaps recorded in the plan: codex's
  `workspace-write` sandbox may refuse a file dropped from outside the project,
  and PDF-read parity varies by harness.

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
- **agent-supervisor-check naming flake** (KNOWN-RED): timing flake, different
  message each run, pre-existing at `566e615`. Fixing it un-gates the context-seam
  assertions behind it.
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
