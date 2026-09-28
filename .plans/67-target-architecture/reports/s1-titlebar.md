# s1 — Titlebar merge landing status

Verdict: implemented + witnessed in 61416361 (array/topbar-merge, 2026-09-13), NEVER merged to array/integration. Worktree clean. No preview app ever built from it (0721 Preview binary lacks --window-chrome-check string). Integration HEAD 1451c030 still: styleMask [.titled,.closable,.miniaturizable,.resizable] at ContinuumApp.swift:4800; fixed 38pt WorkspaceTopBarView row at :10082-10104; zero occurrences of titlebarAppearsTransparent/fullSizeContentView/titleVisibility.

Mechanism in 61416361: workspaceWindowStyleMask adds .fullSizeContentView; applyMergedTitlebarChrome sets titlebarAppearsTransparent, titleVisibility .hidden, titlebarSeparatorStyle .none; systemTitlebarHeight measured via NSWindow.frameRect(forContentRect:styleMask:); top bar hoisted to sibling of NSSplitView; WorkspaceTopBarView.trafficLightInset 76 (0 in fullscreen), min height 28, mouseDownCanMoveWindow true. Witness --window-chrome-check (asserts content spans frame, title hidden, bar at x=0 touching top, split view starts where bar ends, label clears traffic lights >=12pt, fullscreen inset toggles). Registered in run-matrix.sh after --workspace-top-bar-check.

Why not landed: .plans/65-release-0.7.21-coordination.md treated it as "existing feature owned by someone else"; Sol review APPROVE with caveats (fullscreen check simulates delegate callbacks, drag only checks mouseDownCanMoveWindow); "Not landed; no real fullscreen/window-drag/taste QA. Preserve original ownership." Never a red leg; a process hold the release never returned to.

Merge risk: git merge-tree --write-tree → ONE conflict in scripts/run-matrix.sh (both inserted run_app_check lines in the same region). ContinuumApp.swift and WorkspaceTopBarView.swift auto-merge cleanly.

Ticket: land array/topbar-merge onto integration; resolve the one-line matrix conflict; manual QA real fullscreen enter/exit + real window drag (pre-Tahoe 28pt vs Tahoe 32pt titlebar); build preview from merged branch; run full matrix.
