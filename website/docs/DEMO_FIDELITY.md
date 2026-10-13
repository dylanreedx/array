# Demo fidelity to the Mac app

The Swift/AppKit sources and native captures under [`.plans/72-launch-night/qa/app`](../../.plans/72-launch-night/qa/app) define the UI. The website is a scripted HTML/SVG/CSS illustration. It never launches agents, executes terminal commands, or changes a visitor's files.

## One continuous workspace

`GuidedWorkspace` renders six persistent hero articles: three agents, a board, an editor, and a terminal. The same nodes land in a full viewport canvas with native workspace chrome and sidebar. The historic article IDs `note` and `browser` now identify board and editor. No video, replacement tree, React hydration, or required visitor interaction drives the story. `guidedSnapshot` derives all narrative state from current scroll progress; direct jumps and reverse scroll reproduce the same content.

The older `MacWorkspace`, browser, note, and Companion compositions remain source fixtures and are not the homepage's UI authority.

## Native geometry and hierarchy

| Surface | Source authority | Current HTML interpretation |
| --- | --- | --- |
| Workspace | `WorkspaceTopBarView.swift`, `WorkspaceSidebarView.swift`, `AgentInboxView.swift`, `CanvasShortcutRailView.swift` | Full viewport canvas, 46px topbar, 280px desktop sidebar, compact native rows and 28px shortcut rail. No rounded mock window or marketing heading strip. Sidebar selection follows the focused agent. |
| Agent | `AgentTileHeaderView.swift`, `AgentTranscriptListView.swift`, `AgentComposerView.swift`, `AgentComposerFooterView.swift`, AgentUI `Metrics.swift` | Native outer title strip, two-line body header with 15px name, small status dot, elapsed time and branch chip; transcript, compact activity row, composer, shared provider/model/effort and Send/Stop footer. State icons and colors follow the current status. |
| Working glyph | Native orbital thinking indicator | 18px three-node geometry, two tilted elliptical planes and a 7.2-second cycle, sampled in 96 keyframes. Only the transcript tail carries the live gyro; the compact row uses the native static status icon. It advances while scroll pauses and stops when complete, reduced, hidden or offscreen. |
| Board | `KanbanTileNSView.swift`, `KanbanColumnView.swift`, `KanbanCardView.swift`, `BoardTaskDetailController.swift` | To Do / Doing / Done lanes, 248px lane width and 38px headers, drag grip, wrapped task title, notes, linked metadata, assignee dropdown and Add task. The native-style detail panel contains Saved, description and Markdown controls, checklist, status and assignee. It opens at canvas level rather than inside a transformed tile. |
| Editor | `CodeEditorHostView.swift` and bundled CodeMirror resources | Native titlebar accessories, filename, Files control, language label, line-number gutter and source-token colors. Code changes and active lines are seekable. Mobile wraps the source and follows line 14 within the document. |
| Creation | `LaunchProfilePalette.swift` | “Add or jump… ⌘K” and an intentionally condensed native Command Center example. No invented floating creation toolbar. |
| Zone | `ZonePresentation.swift`, `CanvasNSView.swift` | Project-bound zone with the native title/home hierarchy, containing all six managed surfaces. |

The main tile geometry, typography and glyphs follow their native source. This remains an interpretation: transcript content, elapsed clocks, terminal checks, board tasks and editor source are fixtures; the 2% context ring and location label are examples; HTML choice controls stand in for AppKit popovers. The website does not reproduce native virtualization, every context menu, or every keyboard interaction. Do not describe it as a live provider session or a literal screenshot of the app.

Use the native `12 → 10 → 8 → 6` nested-radius ladder and hairline boundaries. State colors remain semantic: blue for active work, amber for attention and green for completion. Color/geometry authority includes [`DesignTokens.swift`](../../Sources/ContinuumRevivedAgentUI/DesignTokens.swift) and [`Metrics.swift`](../../Sources/ContinuumRevivedAgentUI/Metrics.swift).

## Motion and responsive fidelity

The hero retains its original floating paths and supporting copy. Independent elastic tile landings resolve into the native canvas by progress `.26`. Camera paths keep moving within beats and visit agents, approval, board detail, editor and checks before the final wide view. Settled text uses 2D transforms to avoid starting-zoom raster blur.

Mobile camera framing prioritizes a readable subject. The board detail is unscaled and fully visible; the editor is narrower and wraps source while retaining its titlebar. Reduced Motion presents all six cards in ordinary page flow, with stacked board lanes and no continuous gyro animation. A no-JavaScript explanation and download remain accessible.

Current implementation: [`GuidedWorkspace.tsx`](../src/components/demo/GuidedWorkspace.tsx), [`AgentTile.tsx`](../src/components/demo/agent/AgentTile.tsx), [`AgentGyroModel.ts`](../src/components/demo/agent/AgentGyroModel.ts), [`NativeBoardTile.tsx`](../src/components/demo/board/NativeBoardTile.tsx), [`NativeEditorTile.tsx`](../src/components/demo/editor/NativeEditorTile.tsx), and [`guided-demo.ts`](../src/lib/guided-demo.ts). Visual captures, continuity witnesses and performance reports for this pass are under [`.plans/72-launch-night/qa/impact-demo`](../../.plans/72-launch-night/qa/impact-demo).
