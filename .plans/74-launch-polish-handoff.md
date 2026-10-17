# Launch polish — handoff

Written 2026-10-16 by the coordinating session (array-03) for the session that
continues from here. Branch: `array/launch-polish`, which already contains
every commit that was on local `array/integration` up to `814438bc`
(merged in `376d4ac9`). Nothing from this program has been pushed.

## What landed

Each item has a witness that was RED on the code before it and GREEN after,
registered in `scripts/run-matrix.sh` and the matrix inventory.

| Area | What changed | Witness |
|---|---|---|
| Navigation | Hold-⌥ Quick Jump opens over a focused composer/editor (0.7.27's `5b57c60b` gated it off); ⌥-chords the text owns pass through; fast ⌥+label restored off text; ⌥+arrow dock works in the mounted scene (`599126a2` had emptied its lookup); a leader opened with no focused surface no longer strands the broker | `--nav-overlay-visible-check`, `--composer-key-routing-check`, `--leader-snap-check`, `--leader-modal-recovery-check` |
| ⌘K | New Claude Code / Codex / Pi agent rows regardless of the default harness; harness travels with the model id; not-ready harness shown with its reason | `--palette-agent-harness-check`, `--managed-agent-model-spawn-check` |
| Settings | In-window modal (no NSWindow/NSPanel); SwiftUI grouped Form; new sidebar IA (Tiles group, iPhone always listed); one registry feeds rows and word-prefix search; follows the window appearance | `--settings-modal-check`, `--settings-search-check`, CoreChecks `--settings-schema-check` |
| Agent tile | Fresh agents show 0% or an empty ring, never "?"/"0"; titles generated at send (titler sees 8000 chars, not the 240-char label) | `--ui-geometry-check`, `--agent-display-name-check` |
| Sidebar | "✓ All set?" is a real button on the meta line; arrow cursor; throbber back on working rows; subagent groups fold by default with tucked cards; Settle closes the tile (Undo restores tile and zone neighbours); one History shelf | `--settle-closes-tile-check`, `--inbox-parent-fold-check`, `--throbber-timeline-check` |
| Canvas | Every spawn saves before its zone settles (the "couldn't be saved" toast); only changed tiles are sent; slide-between insertion vs centre/⌥ swap | `--spawn-arrange-commit-check`, `--tile-insert-slide-check` |
| Transcript | Markdown tables as an NSTextTable grid; shell rows name the command across Codex/Claude/Pi, no exit code on success; "Show shell commands in transcripts" setting (off = nothing stored) | `--transcript-rhythm-check`, `--shell-tool-row-check` |
| Chrome | Every border ≤ 0.5pt (one shared hairline); toast hairline + shadow; zone cancel menu clear of the toolbar; Sharp/Default/Rounded corner style everywhere | `--border-census-check`, `--corner-style-check`, `--zone-cancel-menu-check` |
| Top bar | Sidebar icon, workspace title menu (switch/new/rename/delete), save dot, ⌘K search icon; shared `ChromeIconButton` | `--top-bar-icons-check` |
| CLI updates | Settings › Agents shows versions; Update runs the owner's own command (never sudo, never a guessed prefix), verifies by re-reading `--version`; opt-out switch; version-change notice | CoreChecks `--cli-install-owner-check`, `--cli-update-runner-check`; `--cli-update-settings-check` |
| Other | Reveal in Finder for notes/files (menu, ⌘K, ⌥⌘R); sound master on by default (events stay off) | `--reveal-in-finder-check`, `--agent-awareness-check` |

## Decisions Dylan made in this program

- Settings is an in-app modal, not a separate window.
- One History shelf; Settle closes the tile.
- Sound master on by default; iPhone page always shown.
- Shell commands kept locally behind a setting, default on.
- CLI updates: output in the app, checks on with an opt-out.

## Still open — Dylan's call

1. **Claude CLI fixture.** `scripts/capture-cli-fixtures.sh check` is the
   matrix's only real red: claude self-updated to 2.1.302 and has no recorded
   sample. Recommended: first make the capture use production's argv (it omits
   `--input-format stream-json --replay-user-messages --include-hook-events
   --forward-subagent-text`; codex is captured via `exec` but production uses
   app-server), then record. Recording runs one tiny real turn on his login —
   ask first.
2. **UI baselines.** Borders, corners, top bar, throbber, tables, menus all
   changed the committed baselines. Generating new ones takes the screen;
   accepting them is Dylan's to trigger, never an agent's.
3. **⌘K and History.** Settled agents still appear as live "Open X" rows in
   the Command Center rather than under its History category. Suggested: move
   them.
4. **Push.** Nothing is pushed. Show the exact commits before any push.

## Known gaps

- Real CLI update commands and the npm/brew/pi.dev response shapes are only
  tested against fakes.
- The website demo still draws the old text top bar.
- Columns don't slide (zones have no flow direction); only rows do.
- The iPhone pane is still the old AppKit view embedded in Settings.

## Benches

`.worktrees/` holds this program's benches: nav-palette, agent-tile-fixes,
settings-rebuild, canvas-layout, transcript-shell, chrome-polish,
agent-ui-polish, cli-updates, topbar-icons, decisions-pass, launch-polish.
All are merged into `array/launch-polish`; return them with
`git worktree remove` once it has landed. `scripts/benches.sh` reports them.

## Lessons recorded this session

- Never pipe `swift build` into `tail`: a failed build reads green and a stale
  checks binary falls into the bare CoreChecks run (it touched the default tmux
  socket once; prod survived).
- Three checks were green on the bug they claimed to guard (the composer
  leader, the "?"/"0" meter, the static throbber). Read what a witness asserts,
  not just that it passes.
