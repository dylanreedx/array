# Auto-layout-night: rules every helper follows

Lead: the agent that delegated you (auto-layout-night lead). Integration branch: array/auto-layout-night.

- NEVER call mcp__plan__* tools.
- Work ONLY in your own worktree (given in your brief). Never touch the main checkout
  (/Users/dylan/Documents/personal/Array itself), never `git stash` (repo-wide), never reset other branches.
- First step in a fresh worktree: `scripts/prepare-ghosttykit.sh` (ThirdParty/ is gitignored).
- BUILDS: every `swift build` goes through the team queue (max 2 concurrent on this Mac, a release is
  shipping tonight): `/tmp/aln/build.sh swift build --product ContinuumRevivedCoreChecks` (or `--product Array`).
  Run builds in the FOREGROUND and test the build's own exit code (never `swift build | tail`; a failed build
  leaves a stale binary). Never end your turn waiting on a background task.
- NO full matrix (scripts/run-matrix.sh), NO release-configuration builds, never touch /tmp/array-matrix.lock.
- Stop processes by PID only, never pkill by pattern. Never touch /Applications/Array.app or the default tmux socket.
- Never guess a --*-check flag: enumerate with
  `grep -oE '\-\-[a-z0-9-]+(-check|-probe)' Sources/ContinuumRevived/App/ContinuumApp.swift Sources/ContinuumRevivedCoreChecks/*.swift | sort -u`.
  App legs: `env -u ARRAY_AGENT_ID TERM=xterm-256color .build/debug/Array --x-check </dev/null`, with a disposable
  CONTINUUM_APP_SUPPORT temp dir. Do not run legs that take the screen (makeKeyAndOrderFront); offscreen only.
- Witnesses drive production and assert outcomes (CLAUDE.md principle 2). Perf claims are measured on the real
  path, not a seam with no production callers.
- Commits: local only, never push. Subject `type(area): description` (imperative, lowercase, no period, <72 chars).
  Dylan's identity (already configured). NO Co-Authored-By or any AI trailer.
- UI: Array's existing components only (ChoiceButton etc.), no one-sided borders, check light and dark.
- Rules for layout: no O(tiles) work per display cycle or per input event; no visible picture swaps (no frozen
  snapshots/crossfades standing in for real views).
- Report: when a milestone lands, write .plans/auto-layout-night/reports/<stream>.md IN YOUR WORKTREE (what changed,
  commits, numbers, checks run with exit codes, what failed and why) and commit it, then finish your turn with
  array_report. Do not message other helpers; only the lead.
- BOARD: at each milestone also post one short comment (commits with hashes, numbers before/after, decisions
  and why, anything rejected) with array_board_apply op comment on board 68A623C4-2B7D-4E3D-9529-E04427F16AFD,
  card 79EE3C01-2CD6-4A44-916D-D9520A8DD9B6 (query the board first for its revision; retry on revision_conflict).
  Never move the card.
- ARRAY MUST NOT CRASH (Dylan is AFK; /Applications/Array.app hosts every agent): never unset
  CONTINUUM_ARRAY_MANAGED_AGENT, never run crash witnesses; never pkill/killall by name ("Array" matches the live
  app) — PID only; never quit, signal or rebuild /Applications/Array.app; keep the 2-build cap (jetsam risk);
  any app you launch uses its own bundle id and CONTINUUM_APP_SUPPORT dir. Before scripts/dev-app.sh, quit any
  running preview instance by PID yourself. If anything makes Array hang or exit, stop and tell the lead.
- FLAG OWNERSHIP: check that a flag is registered in the binary you run. An unknown flag in
  ContinuumRevivedCoreChecks runs the WHOLE default suite, which touches the default tmux socket.
  --jelly-auto-layout-check is an APP flag (.build/debug/Array), not CoreChecks. Always set TMUX_TMPDIR
  (and unset TMUX/TMUX_PANE) for every CoreChecks run anyway.
- REGRESSION SET (all GREEN on array/auto-layout-night since 8b816859; they must stay green): --subagent-tile-zone-check,
  --leader-jump-check, --tile-reveal-work-check, --agent-local-file-link-check, --canvas-zoom-momentum-check,
  --spawn-placement-check, --spawn-sizing-check, --auto-layout-fanout-app-check, --zone-arming-check, --canvas-undo-check,
  --layout-commit-scope-check. Known pre-existing red, not ours: --agent-tile-click-focus-check.
- ON-SCREEN LEGS (put a real window on screen or take key focus): --spawn-placement-check, --canvas-undo-check,
  --leader-jump-check, --tile-reveal-work-check, --palette-zone-check, --agent-local-file-link-check,
  --palette-captures-keys-over-browser-check, and any leg whose source calls makeKeyAndOrderFront/orderFrontRegardless
  WITHOUT orderFrontOffscreenForChecks. Do NOT run these. The lead runs them only in his screen slots
  (05:00–05:25, 06:00–06:30) and will run them for you; list which ones your change needs.
