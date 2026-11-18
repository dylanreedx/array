# Memory audit: Array and everything it spawns

Measured 2026-11-16 03:58–04:20 UTC on Dylan's Mac. Prod Array 0.7.52, pid 3532.
At the time: memory_pressure 34% free, swap 12.06 of 13.3 GB used.
Read-only, using `footprint` (counts compressed and swapped pages; RSS was
meaningless with swap this full — claude CLIs read 0.5 MB RSS each).

## Ranked table

| # | What | Count | Footprint | Owner / note |
|---|------|------:|----------:|--------------|
| 1 | Booted iOS simulators | 2 (351 procs) | **5.27 GB** + 270 MB Simulator.app | `2E3B…` (Savoro-search-anything-ios, 2.0 GB): opened by an agent through `array_device_open`, then `array_device_close`. **No preview bridge running; still booted.** `7E35…` (Savoro iOS review fixes, 3.3 GB): booted by a Codex agent's own `simctl boot` for `xcodebuild test`. |
| 2 | Managed claude CLIs | 15 | **3.17 GB** (avg 211 MB) | One per managed agent with a live session. 3 belonged to agents Array showed as *ready*; 2 of those ran a background shell job (a build loop, a `swift build`), which correctly holds the session. |
| 3 | Array itself | 1 | **2.28 → 2.36 GB** in ~7 min (~2.5 MB/min at the time) | 1.75 GB Malloc Small, 161 MB Malloc Large, ~230 MB graphics (IOSurface 82, IOAccelerator 63, unmapped graphics 85), 33 MB CG Image. Heap census pending (see below). |
| 4 | Transient check binaries spawned by helpers | 1 seen | **5.3 GB** | `.build/debug/Array --agent-record-archive-check --agent-record-archive-measure-store=default` — one check loading the real 2,670-record store. Transient, but at swap-full it pushes everything else out. |
| 5 | Builds (swift-frontend, swift-build, xcodebuild, esbuild/wrangler) | ~8 | ~1.9 GB | Agent work, transient. |
| 6 | Codex CLIs | 6 | 625 MB (avg 104 MB) | + 6 `codex-code-mode-host` at 13 MB = 77 MB. |
| 7 | WebKit (browser tiles) | 4 content + 3 GPU + 3 net | ~270 MB | One content process at 139 MB, the rest 28–39 MB. Small today. |
| 8 | array-workspace-mcp | 21 | 107 MB (5 MB each) | One per CLI; dies with its CLI (witnessed: reaped with 27955). |
| 9 | tmux server + login/zsh shells | ~20 | ~40 MB | Ghostty surfaces live inside Array's footprint. |
| 10 | Orphans (ppid 1) of Array-launched work | ~20 | ~35 MB | Old vite/wrangler/node dev servers and two 30-day-old `pi` check shims. Small. |

fseventsd (3 GB) is owned by 165B88FC and not counted here.

### Witnessed: the idle reaper works

Idea (a) "hibernate idle agents" **already ships** as D3 in `AgentSupervisor`:
`scheduleIdleReap` stops a runner `defaultIdleRunnerTimeout` = **600 s** after
its turn ends, unless `hasBackgroundWork` (shell job, subagent, schedule). The
next message resumes the same session (resume-first). Observed live: agent
`5A04D28F` went ready at ~03:55:37; its claude CLI (27955, 209 MB) and its MCP
child ended at 04:05:3x. The two ready agents whose CLIs survived each had a
running background shell job, which is the intended exception.

So the remaining CLI cost is (i) agents mid-turn (most "working" leads are
waiting on helpers inside a turn and cannot hibernate) and (ii) the 10-minute
tail after each turn.

## Research

- **Ghostty.** `scrollback-limit` is bytes per surface, allocated lazily in
  page-sized chunks from a pool ([config](https://ghostty.org/docs/config/reference),
  [PageList.zig](https://github.com/ghostty-org/ghostty/blob/main/src/terminal/PageList.zig)).
  Occlusion (`ghostty_surface_set_occlusion`, which Array already calls in
  `GhosttyTerminalView`) stops drawing and rebuilds but does **not** free GPU
  resources ([renderer/Thread.zig](https://github.com/ghostty-org/ghostty/blob/main/src/renderer/Thread.zig));
  only `ghostty_surface_free` does. Array does not set `scrollback-limit`, but
  its terminals run in tmux so Ghostty holds little history. Lesson for
  Array's own transcripts: page-sized, lazily faulted, bounded storage — which
  is what D69121D9's retention work is doing.
- **Claude Code.** Many public reports of RSS growth in long or idle sessions,
  often native, not V8 heap; killing and resuming (`claude -c`) restores a
  normal footprint ([#18859](https://claudeissues.com/issue/18859-bug-memory-leak-in-long-running-idle-claude-code-sessions),
  [#33543](https://claudeissues.com/issue/33543-memory-leak-4-2-gb-rss-after-3-5-minutes-native-memory-dominates-v8-heap),
  [#67433](https://claudeissues.com/issue/67433-bug-off-heap-memory-leak-rss-grows-400-500-mb-min-while-idle-reaches-multi-gb)).
  Mirrors, not github.com; treat as indicative. Supported env vars that can
  trim work: `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`,
  `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, `CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING`
  ([env vars](https://code.claude.com/docs/en/env-vars)). No `NODE_OPTIONS`
  heap cap would help a native leak. The prompt cache is server-side, so a
  resumed process does not lose it.
- **Codex.** Rust CLI is small (~100 MB here); reported growth is in MCP child
  trees ([write-up](https://codex.danielvaughan.com/2026/04/18/subagent-mcp-resource-leak-process-trees/)).
- **Other tools** (Conductor, Crystal, Claude Squad, Vibe Kanban) isolate by
  worktree; Claude Squad keeps a tmux session per agent alive. None found that
  documents idle hibernation — Array's D3 reaper is already ahead of them.
- **WebKit.** `WKPreferences.inactiveSchedulingPolicy = .suspend` (macOS 14+)
  freezes a web view outside a window, but suspension keeps its memory resident
  ([Apple](https://developer.apple.com/documentation/webkit/wkpreferences/inactiveschedulingpolicy-swift.enum));
  only tearing down the view frees it.

## Ideas, against the measurements

| Idea | Measured target | Estimated saving | Verdict |
|------|----------------|------------------|---------|
| (e) Shut down simulators Array booted once no viewer wants them | 2.0 GB now (`2E3B…`); 2–3.3 GB per device | **2–3 GB per abandoned device** | **Build first.** Array never shuts down a device; `device.close` answers `simulatorLeftRunning: true`, and a parked tile keeps wanting its device forever. |
| (a) Hibernate idle agents | already shipped (600 s) | Lowering to 180 s frees ~210 MB per agent for 7 extra minutes per turn; maybe 0.4–1 GB at a time in a busy hour | **Build second, as a setting.** Expose the timeout; keep 600 s by default until measured. |
| Checks loading the real store | 5.3 GB transient | 5 GB peaks | Report to the archive owner (09CDBF04); not mine. |
| Array malloc (transcripts, records) | 1.75 GB small malloc, growing | — | Owned by D69121D9 (transcript retention). Census below for them. |
| (b) Suspend browser web content | ~270 MB total | < 200 MB | Not worth it now; `.suspend` does not free memory. |
| (c) Drop off-screen renderer surfaces | ~230 MB graphics in Array | < 150 MB, and risks visible picture swaps | Skip. |
| (d) Intern repeated strings | 0.7.47 census: CFString 745 MB + StringStorage 632 MB, mostly the file index, which is fixed | Unknown until the new census | Re-rank after the census. |
| (e2) Reap orphan helpers | ~35 MB | tiny | Not worth code; note the 30-day-old `pi` shims from checks. |
| Agent-booted simulators (`simctl boot` from a shell) | 3.3 GB | 3 GB | Array cannot prove it owns these. Suggest an agent standard: shut down what you boot. |

## Heap census

Not taken. The one allowed `heap 3532` waited for 180 s of user idle that
never came before the session ended (the Mac then restarted). Array's 1.75 GB
of small malloc is still unranked; whoever owns transcript retention
(D69121D9) should take the census on the next long idle and compare it with
`~/array-scratch/live-memory/heap.txt` (0.7.47).

## Built (branch `array/memory-everywhere`)

1. `80de2371` feat(ios-preview): shut down unviewed simulators Array booted.
   Settings > Advanced, **off by default**. Only devices this process booted;
   2 min grace; a returning preview boots the device again; shutdown runs
   through the retirement queue, so a tile that comes back mid-shutdown waits.
   Witness `--ios-preview-reclaim-check` (6 cases) GREEN; RED with the reclaim
   disabled ("an unviewed simulator Array booted was not shut down").
   Known risk, which is why it stays off: an agent running `xcodebuild test`
   on an Array-booted simulator outside the preview tool while its tile is
   parked would lose the device mid-run.
2. `02e478a1` feat(agents): make the idle-session stop time a setting.
   Settings > Agents, default unchanged at 10 min, read at each turn end.
   Witness `--agent-presence-check` section idle-setting GREEN.

Not built: string interning (needs the census), browser suspension and
off-screen surface release (small measured targets), orphan reaping (~35 MB).
