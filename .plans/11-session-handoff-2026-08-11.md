# Handoff — 2026-08-11 (0.4.3 → 0.4.7 + unreleased)

Read this before touching the command center, the agent tile chrome, or the
model pickers. It records what shipped, what is still open, and — most
usefully — **four traps that made verification lie**.

## Released today

| Version | Build | What |
|---|---|---|
| 0.4.3 | 9 | ⌘K command-center redesign; semantic completions + fuzzy `@` file navigation; codex occupancy from the rollout log; camera-move chrome redraw fix |
| 0.4.4 | 10 | Codex transcript rehydration; closed agents reachable from ⌘K (History) |
| 0.4.5 | 11 | Workspace sidebar REMOVED; every tile-less agent reachable from ⌘K; managed agents inherit the Home you are working in; iOS build repaired |
| 0.4.6 | 12 | ⌘K floats (was rendering as a full-height edge panel); provider headers in ⌘K's model step; top bar ☰ removed |
| 0.4.7 | 13 | Settings' two-pane model picker lists EVERY provider behind per-provider headers |

Next build number is **14**. Ledger: `docs/VERSIONING.md`.

## Unreleased on `array/integration`

- `8fdb6c1` — managed agent tile named after the model it runs (was the literal
  `"GPT-5.6"` in `TileSpawner`, in both the tile title and the bootstrap line).
  **Not yet released; needs a matrix run + 0.4.8.**

## The four traps (why checks passed while the app was broken)

These cost most of the session. Each is the same failure in a different costume:
**a witness that does not drive production passes while production is broken.**

1. **A check that builds its own host.** ⌘K rendered as a right-edge full-height
   panel for hours while `--palette-duplicate-root-check` stayed green, because
   the check builds a plain `NSView` host and never touched the real window's
   `contentView`. Production's `contentView` was the **NSSplitView**, which
   adopts any subview as a *pane* and overwrites its frame — discarding the
   palette's computed centred 660×520 float. Fixed by returning a plain
   container from `makeWorkspaceContentView`; the mount check now asserts the
   content view is **not** an `NSSplitView`.
2. **Fixing one of two surfaces.** "Only Anthropic models" was reported four
   times. Nothing was ever filtered (backend `.pi`, `allowedProviders: nil`,
   catalogue 16 anthropic + 7 openai-codex). It was VISIBILITY, in **two
   different controls**: ⌘K's flat model step (fixed 0.4.6) and Settings'
   two-pane `ProviderModelPickerView` (fixed 0.4.7). Fixing one and declaring
   victory is what caused reports 2–4.
3. **Targeted checks cannot see the iOS gate.** The iOS build was red from 0.4.3
   to 0.4.5 (`Process` and `homeDirectoryForCurrentUser` in shared Core, which
   compiles into the iOS target). No `Array --*-check` flag compiles Core for
   iOS. Only `scripts/run-matrix.sh` covers it.
4. **Separate check EXECUTABLES.** `ContinuumRevivedPaletteChecks` is its own
   product; the app's `--palette-*-check` flags never run it. It went red on a
   positional action-order assertion and only the matrix caught it.

**The habit that actually worked:** build the dev app and look at it.
`scripts/dev-app.sh`, then `screencapture`, then read the PNG. Two screenshots
found what a day of green checks missed.

**Do NOT drive the GUI with `osascript` keystrokes.** Focus can move between
`open -a` and the keystroke; a stray `agent` prompt was typed into an unrelated
Ghostty/tmux Claude session this way.

## Open items

1. **Duplicate codex rollout locators, conflicting policies.** DECISION NEEDED.
   `CodexRolloutTelemetry.rolloutURL` (shipped 0.4.3, pinned by
   `CodexAgentBackendChecks`) **abstains** when a thread matches in both
   `sessions/` and `archived_sessions/`. `CodexRolloutLocator` (shipped 0.4.4,
   used by the transcript reader and state reader) lets the **active tier win**,
   reasoning that archiving transiently duplicates. Both are witnessed; the
   locator's policy is arguably better in practice. Collapsing them changes
   shipped behaviour and rewrites a pinned witness — Dylan's call.
2. **36 ComponentLab baselines, unblessed.** The documented KNOWN-RED. Held at
   exactly 36 through every release today; the two `chrome.topbar` images the ☰
   removal changed were blessed individually after reviewing their diffs. Do NOT
   run `CONTINUUM_UPDATE_BASELINES=1` — it would sweep the 36 in with them. Some
   of the 36 are now genuine 0.4.3 composer/completion changes rather than old
   drift. Diffs (magenta = changed) under `qa-runs/*/ui-baselines/`.
3. **`wip/pre-0.4.3`** still holds the composer pasteboard intake work. Its
   command-center and codex-rehydration parts are shipped, so that branch is
   mostly superseded.
4. **Context gravity is not wired** into `ManagedAgentSpawnHomeResolver`'s
   precedence at the call site — the rung passes nil and is skipped, not
   defaulted. `.plans/07-managed-agent-home-inheritance/`.
5. **pi is invisible to a GUI-launched app without PATH augmentation.** `pi` is
   a Node script; `node` lives under nvm. `PiAgentRunner.liveExtraDirs()`
   expands nvm version bins, which is what makes the catalogue probe work — a
   thin environment fails with `env: node: No such file or directory`. Keep that
   in mind before "simplifying" the probe environment.

## Where the important pieces live

- Command center: `Sources/ContinuumRevivedCore/LaunchPaletteModel.swift`
  (rows, categories, presentation) + `App/LaunchProfilePalette.swift` (surface,
  provider headers in the model step).
- Tile-less agents (History / Needs You): `TilelessAgentPaletteRow`; membership
  comes from `InboxSort.section(for:now:)` — never re-derive it.
- Settings model picker: `Canvas/AgentComposer/ProviderModelPicker.swift`
  (`headeredItems`, rail jumps rather than filters).
- Window mount: `ContinuumApp.makeWorkspaceContentView` — returns a PLAIN
  container on purpose (trap 1).
- Managed tile naming: `TileSpawner.spawnManagedAgent` +
  `ContinuumApp.renameManagedAgentTileForModel`.

## Witnesses retired BY INVERSION (not deleted)

Re-introducing the sidebar fails a check rather than shipping:

- `--workspace-sidebar-default-visible-check` — mount must produce NO sidebar,
  one split subview, a full-width content pane, and a non-`NSSplitView` content
  view.
- `--workspace-sidebar-shell-check` — the toggle must NOT be palette
  discoverable.
- `--menu-contract-check` — the View menu must NOT offer the item.
- `ContinuumRevivedPaletteChecks` — searching "workspace sidebar" must return
  nothing.
