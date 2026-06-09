# Platform Bug-Bash Backlog

Status: captured from overnight/follow-up platform-breaker agents. This repo is currently on `feat/phase-6-core-data-model` with a dirty worktree; do **not** implement more here until branch strategy is decided.

Canonical source artifact: `.pi/agent-runs/triage-lead-20260606T122818Z-956421/final.md`

Good source breaker artifacts:

- `.pi/agent-runs/platform-breaker-20260606T024634Z-dd5ac8/final.md` — browser focus/forms/scroll
- `.pi/agent-runs/platform-breaker-20260606T024634Z-221cab/final.md` — resize/drag/cursor/hit testing
- `.pi/agent-runs/platform-breaker-20260606T024634Z-54ca2e/final.md` — terminal focus/scroll/drag
- `.pi/agent-runs/platform-breaker-20260606T024634Z-fd7d63/final.md` — file/file-tree UX
- `.pi/agent-runs/platform-breaker-20260606T024634Z-aaf7d4/final.md` — canvas viewport/zoom/pan/defaults
- `.pi/agent-runs/platform-breaker-20260606T024634Z-f3f403/final.md` — palette/shortcuts/text-input conflicts
- `.pi/agent-runs/platform-breaker-20260606T122433Z-170b0c/final.md` — anti-false-positive QA audit
- `.pi/agent-runs/platform-breaker-20260606T122451Z-cd5500/final.md` — persistence/relaunch/state corruption
- `.pi/agent-runs/platform-breaker-20260606T122524Z-832732/final.md` — performance/crash/resource hazards

Bad/stale coordinator-chatter runs to ignore for backlog purposes:

- `.pi/agent-runs/triage-lead-20260606T024643Z-c6a92b/`
- `.pi/agent-runs/triage-lead-20260606T122139Z-67da98/`
- `.pi/agent-runs/platform-breaker-20260606T122139Z-*/`

## Priority backlog

| Rank | Title | Severity | Confidence | Area | Likely files | QA oracle | Difficulty | Recommended order |
|---:|---|---|---|---|---|---|---|---|
| 1 | Browser navigation state is saved but not restored on relaunch | major | confirmed | browser / persistence | `TileSpawner.swift`, `BrowserTileNSView.swift` | Seed Canvas metadata URL A + BrowserState URL B; relaunch; assert runtime loads B and title/chrome source-of-truth is correct. | M | First: user-visible persistence loss, clear repro |
| 2 | Relaunch/overlap z-order and hit-test ignore `zIndex` | major | confirmed | canvas / persistence | `CanvasNSView.swift`, `ContinuumApp.swift`, `CanvasEngine.swift` | Seed overlapping tiles with array order conflicting with `zIndex`; relaunch; assert top subview + `tileId(at:)` are max-z tile. | M | Fix before focus/input tests relying on top tile |
| 3 | Browser URL Enter/Escape focuses non-focusable host instead of WKWebView | major | confirmed | browser / focus | `BrowserTileNSView.swift`, `BrowserRuntime.swift`, `WKWebViewBrowserRuntime.swift` | Invoke URL-field Enter/Escape in QA window; assert final responder is WKWebView/content responder, not URL field or plain host. | S | High UX impact, small fix |
| 4 | Tile bring-to-front reparenting on every mouseUp can drop browser/terminal focus | major | likely | browser / terminal / canvas | `ContinuumApp.swift`, `CanvasNSView.swift`, `GhosttyTerminalView.swift` | Overlap two browser/terminal tiles; click lower content; after mouseUp assert first responder remains clicked runtime and typed sentinel lands there. | M | After z-order fix |
| 5 | Palette duplicate subview leak when Cmd-K pressed while already visible | major | confirmed | palette | `LaunchProfilePalette.swift`, `ContinuumApp.swift` | Press Cmd-K N times without Escape; assert exactly one palette root exists and memory/subview count is bounded. | S | Quick high-confidence fix |
| 6 | Palette close does not restore previous first responder | major | confirmed | palette / focus | `LaunchProfilePalette.swift` | Focus note/browser/terminal field → Cmd-K → Escape; assert previous semantic responder restored and typing continues there. | M | Pair with palette duplicate fix |
| 7 | Close button / title bar / content edge clicks are stolen by resize hit zones | major | confirmed | hit testing / resize | `TileNSView.swift`, `TitleBarView`, `CornerOverlayView` | Pixel-map hit tests: close button top pixels hit `NSButton`; edge points either visibly resize or content remains reachable. | M | Fix before broad UX polish |
| 8 | File preview size gate overflows for >2GB files and may attempt huge read | critical | confirmed | file | `FilePreview.swift` | Create sparse 3GB file; `FilePreview.load` must return too-large before full read/allocation. | S | Small, critical safety fix |
| 9 | File tree large-scan performance hazards: O(n²) queue, snapshot flood, no caps, MainActor rebuilds | major | confirmed/likely | file-tree / perf | `FileTreeScanner.swift`, `FileTreeViewModel.swift`, `FileTreeTileNSView.swift` | Generate 50k–100k node tree; assert scan time, snapshot count/size, RSS, and key-to-render latency stay under thresholds/caps. | L | Needs perf harness first |
| 10 | File tree search hides nested matches behind collapsed ancestors | major | confirmed | file-tree | `FileTreeOutlineModel.swift`, `FileTreeTileNSView.swift` | Collapsed `Sources/App.swift`; search `App.swift`; assert visible outline row includes matching file, not only ancestor. | M | User-visible, deterministic |
| 11 | File-tree search can be lost on quick close before debounce commits | major | confirmed | file-tree / persistence | `FileTreeTileNSView.swift`, `ContinuumApp.swift` | Change search field, immediately flush/close; reload state; assert query persisted. | S | Pair with search work |
| 12 | File-tree missing/corrupt sidecar silently restores wrong root | major | confirmed | file-tree / persistence | `TileSpawner.swift`, `FileTreeState.swift` | Seed canvas `.fileTree` tile with missing sidecar; relaunch; assert recoverable missing-state UI or preserved root. | M | Requires source-of-truth decision |
| 13 | Spawn cascade / drop-at-edge can place new tiles mostly offscreen | major/minor | likely | canvas / spawning | `TileSpawner.swift`, `CanvasEngine.swift`, `CanvasNSView.swift` | Simulate N spawns and edge drop; assert each new tile/header has minimum visible intersection in viewport. | M | After z-order/layout oracle |
| 14 | Persisted viewport/tile frames trusted without validation | major | confirmed/likely | canvas / persistence | `CanvasState.swift`, `ProjectStore`, `ContinuumApp.swift`, `CanvasEngine.swift` | Load fixtures with zoom 0/negative/tiny/huge and invalid frames; assert clamped safe viewport/frame and recovery affordance. | M | Important relaunch recovery |
| 15 | Global Cmd hotkeys steal browser/terminal/text-native shortcuts | major | confirmed/likely | shortcuts / focus | `ContinuumApp.swift`, focus policy | Matrix over note URL/WKWebView/terminal: synthesize Cmd-K/Cmd-1..4; assert reserved/pass-through policy. | M | Needs product policy |
| 16 | Unbounded hotkey spawning can create unlimited runtimes/views | major | likely | canvas / perf | `ContinuumApp.swift`, `TileSpawner.swift` | Inject 200 spawn hotkeys; assert cap/rate limit or bounded memory/latency slope. | M | Policy needed: cap vs throttle |
| 17 | Terminal/browser/file scroll QA only proves hit-test classification, not actual scrolling | major/minor | confirmed | QA / scroll | `ContinuumApp.swift`, `GhosttyTerminalView.swift`, `WKWebViewBrowserRuntime.swift` | Synthesize precise scroll over content; assert page `scrollY` or terminal scroll counter changes and canvas viewport does not. | M | QA harness before scroll fixes |
| 18 | Autonomous QA flow selection and pass/fail semantics are false-positive prone | major | confirmed | QA | `qa/run-autonomous.sh`, `qa/flows/*.sh`, `ContinuumApp.swift`, `Package.swift` | `--flow X` must execute X; external/in-process flows emit JSON assertions and fail/skip, not unconditional pass; perf checks included. | L | Foundational |
| 19 | No true two-leg relaunch persistence smoke | major | confirmed | QA / persistence | `ContinuumApp.swift`, `qa/flows`, QA harness | Leg A mutates state/exits; Leg B relaunches same root and asserts browser URL, z-order, file-tree root, viewport/frame invariants. | L | Highest-value QA harness |
| 20 | Git status probe output/timeout can hang or consume huge memory | major | likely | file-tree / git | `FileTreeGitStatusProbe.swift` | Fake `git` emits >100MB or ignores SIGTERM; assert output cap + hard kill within timeout+grace. | M | Perf/safety follow-up |

## Recommended implementation order

1. Build relaunch/layout/focus QA oracles for z-order, browser restore, browser URL focus, and palette duplicate/restoration.
2. Fix small confirmed issues: file preview overflow, browser URL focus, palette duplicate leak.
3. Fix persistence blockers: browser restore source-of-truth, z-index restore/hit-test, viewport/frame sanitation.
4. Fix hit-test/focus instability: bring-to-front reparenting and resize-zone stealing.
5. File-tree correctness: search visibility, debounce flush, missing sidecar behavior.
6. Perf/stress work: file-tree scale, unbounded spawns, git probe, long-line file preview.
7. QA platform cleanup: enforce `--flow`, remove unconditional passes, include perf checks, add two-leg relaunch smoke.

## Parallelization plan

Can run concurrently:

- Palette fixes + tests.
- File preview overflow fix.
- Browser URL focus fix.
- QA `--flow` enforcement work.
- File-tree search visibility/debounce exploration.

Serialize:

- Z-order restore/hit-test before bring-to-front focus tests.
- Browser restore source-of-truth before browser title/profile restore decisions.
- Shortcut interception only after product policy for reserved vs pass-through commands.
- File-tree perf fixes after stress harness defines thresholds.

## Branch/worktree hygiene

Current branch from `git branch --show-current`:

```text
feat/phase-6-core-data-model
```

Current dirty status includes app UX files, agent definitions, QA scripts, docs, and artifacts. Do not continue implementation in this branch until deciding one of:

1. keep this branch as an evidence/scratch branch;
2. move backlog/agent docs to the correct branch;
3. return to `main` or a clean feature branch and recreate/cherry-pick only desired fixes.

No git staging/commit/stash/checkout has been performed.

## Key risks

- AppKit/WKWebView first-responder identity can be indirect; tests should assert semantic owner or typed sentinel, not only brittle raw object identity.
- Global Cmd shortcuts, Cmd-scroll over terminal, empty-file previews, and title-bar resize semantics need product policy before fixing.
- Scroll and WebKit typing oracles need DOM-ready waits/counters to avoid flakes.
- Offscreen placement is allowed in an infinite canvas, but new spawn/relaunch should guarantee visible/recoverable affordance.
- Perf thresholds need machine-tolerant budgets or relative caps.
