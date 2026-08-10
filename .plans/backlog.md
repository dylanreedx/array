# Improvement backlog

Small, self-contained improvements — each is one focused session or less.
Bigger designed work gets a numbered plan file (see `01-provider-cli-backends.md`).
Program history: `docs/38-tickets/95-go-live.md`. Shipped state: 0.2.2 (build 4);
next release is build 5.

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

- `01-provider-cli-backends.md` — **claude backend SHIPPED 2026-08-09**
  (anthropic models run on the user's own Claude Code login, no pi, no extra
  usage; routing + translator + runner + catalogue union + onboarding +
  witnesses). REMAINING: codex CLI backend (low priority — no teammate uses
  codex), the formal `ManagedAgentBackend` protocol extraction, and a
  tool-approval dock for both backends. Compliance research recorded in-plan.
