import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// A practical, in-app lab for the views and interactions used across Continuum.
// Unlike a static Storybook, the lab's center of gravity is *operating real
// components* — later phases add a live canvas sandbox (spawn/drag/resize real
// tiles) and an affordance inspector. This file is the shell + the static cards
// for behaviour-less chrome. Adding an entry = appending one `LabEntry`.

/// Shared app runtimes the lab can borrow (for live tiles in later phases).
@MainActor
struct LabEnvironment {
    let ghostty: GhosttyRuntimeContext?
    let browserEngine: BrowserEngineContext?
}

/// What the right-hand pane shows for a selected entry.
@MainActor
enum LabContent {
    /// A real chrome view built from a fixture, on a flat dark backdrop.
    /// `preferredSize` fixes the render size (centered); nil pins it to fill.
    case staticCard(preferredSize: NSSize?, make: () -> NSView)

    /// A supervised design-review surface. It remains interactive in Component
    /// Lab but has its own width/appearance baseline sweep, so it cannot silently
    /// alter the legacy static-card baseline catalogue.
    case reviewSurface(preferredSize: NSSize, make: () -> NSView)

    /// A live, interactive canvas you operate for real (spawn / drag / resize /
    /// zoom). `configure` seeds the initial tiles; the sandbox always provides a
    /// spawn toolbar + zoom controls. Fills the host.
    case canvasSandbox(configure: (LabSandboxContext) -> Void)

    /// A button that presents a real modal/panel (command palette, settings,
    /// project picker) near the lab window. `present` returns an object to retain
    /// for the panel's lifetime (nil for synchronous modals).
    case launcher(buttonTitle: String, present: (NSWindow) -> AnyObject?)
}

/// One catalog entry, grouped under a category in the left nav.
@MainActor
struct LabEntry {
    let id: String
    let category: String
    let title: String
    let summary: String
    let content: LabContent
}

enum AgentTranscriptReviewState: String, CaseIterable {
    case mixed
    case long
    case activeTool = "active-tool"
    case failedTool = "failed-tool"
    case approval
}

/// P4.10 supervised review states: the full-turn composer across its editing and
/// action states, the open choice/completion surfaces, and the compact freeform
/// variant. Menu states render the same `ChoiceListView` the anchored panel
/// presents, laid into the surface so both themes produce comparable images.
enum AgentComposerReviewState: String, CaseIterable {
    case empty
    case focused
    case multiline
    case long
    case working
    case modelMenu = "model-menu"
    case effortMenu = "effort-menu"
    case completion
    case compactEmpty = "compact-empty"
    case compactLong = "compact-long"

    var variant: AgentComposerVariant {
        switch self {
        case .compactEmpty, .compactLong: return .compactFreeform
        default: return .fullTurn
        }
    }
}

// MARK: - Fixtures

/// Canned models so cards render with realistic data and zero app state.
@MainActor
enum LabFixtures {
    static let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let altWorkspaceId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let selectedZoneId = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    static let selectedTileId = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    /// 12 characters from `PairingAlphabet.symbols`, so the pairing card renders
    /// realistic — and identical — data on every draw.
    static let pairingCredential = "K7M2QRTX9BDH"

    static func transcriptReviewDocument(_ state: AgentTranscriptReviewState) -> AgentDocument {
        func id(_ suffix: String) -> AgentNodeID {
            AgentNodeID(rawValue: "review-\(state.rawValue)-\(suffix)")!
        }
        func paragraph(_ suffix: String, _ inlines: [AgentInline]) -> AgentBlock {
            AgentBlock(id: id(suffix), revision: 1, kind: .paragraph, payload: .paragraph(inlines))
        }
        func entry(_ suffix: String, role: AgentEntryRole, blocks: [AgentBlock]) -> AgentEntry {
            AgentEntry(
                id: id("entry-\(suffix)"), revision: 1, role: role,
                provenance: role == .user
                    ? .localPrompt(promptID: "review-\(state.rawValue)")
                    : .providerItem(provider: "fixture", itemID: suffix),
                lifecycle: .finished, blocks: blocks
            )
        }

        let user = entry("user", role: .user, blocks: [paragraph("user-prompt", [
            .text("Make transcript streaming feel calm and readable, keep semantic copy exact, and preserve keyboard access."),
        ])])
        let assistantProse: [AgentBlock] = [
            AgentBlock(
                id: id("heading"), revision: 1, kind: .heading,
                payload: .heading(level: 2, content: [.text("A quieter transcript architecture")])
            ),
            paragraph("prose", [
                .text("I separated the provider stream from presentation, so "),
                .strong([.text("prose remains the reading path")]),
                .text(" while tools and artifacts keep explicit structure. The list updates by stable identity instead of rebuilding every row."),
            ]),
            AgentBlock(
                id: id("list"), revision: 1, kind: .list,
                payload: .list(.init(ordered: false)), children: [
                    AgentBlock(
                        id: id("list-item-1"), revision: 1, kind: .listItem, payload: .listItem,
                        children: [paragraph("list-item-1-text", [.text("Native selection and dual-format copy remain available.")])]
                    ),
                    AgentBlock(
                        id: id("list-item-2"), revision: 1, kind: .listItem, payload: .listItem,
                        children: [paragraph("list-item-2-text", [.text("Completed operations recede; active and failed work stay legible.")])]
                    ),
                ]
            ),
            AgentBlock(
                id: id("quote"), revision: 1, kind: .quote, payload: .quote,
                children: [paragraph("quote-text", [.text("The transcript should read like a document, not a wall of cards.")])]
            ),
            AgentBlock(
                id: id("code"), revision: 1, kind: .fencedCode,
                payload: .fencedCode(.init(
                    language: "swift",
                    code: "let shouldStick = wasNearBottom && !hasTextSelection\napply(latestSnapshot)\n",
                    isComplete: true
                ))
            ),
        ]
        let completedTool = AgentBlock(
            id: id("tool-completed"), revision: 1, kind: .toolCall,
            payload: .toolCall(.init(
                name: "Read transcript model", summary: "Inspected the reducer and renderer boundaries.", status: .completed
            ))
        )
        let plan = AgentBlock(
            id: id("plan"), revision: 1, kind: .plan,
            payload: .plan(.init(
                title: "Transcript review", status: .inProgress, steps: [
                    .init(title: "Stabilize semantic identity", status: .completed),
                    .init(title: "Review visual hierarchy", detail: "Owner review is the active gate.", status: .inProgress),
                    .init(title: "Build the native composer", status: .pending),
                ]
            ))
        )
        let diff = AgentBlock(
            id: id("diff"), revision: 1, kind: .diff,
            payload: .diff(.init(
                text: "opaque compatibility text",
                summary: "Refined transcript presentation",
                files: [
                    .init(displayName: "AgentTranscriptListView.swift", addedLineCount: 84, removedLineCount: 19),
                    .init(displayName: "AssistantProseRenderer.swift", addedLineCount: 31, removedLineCount: 8),
                ], canOpenReview: true
            ))
        )
        let notice = AgentBlock(
            id: id("notice"), revision: 1, kind: .notice,
            payload: .notice(.init(message: [.text("Streaming complete · 5,000 deltas coalesced without moving the reader.")], status: .completed))
        )
        let activeTool = AgentBlock(
            id: id("tool-active"), revision: 1, kind: .toolCall,
            payload: .toolCall(.init(
                name: "Run matrix", summary: "Building and checking the app bundle. This detail stays open while work is active.", status: .inProgress
            ))
        )
        let activeOutput = AgentBlock(
            id: id("output-active"), revision: 1, kind: .commandOutput,
            payload: .commandOutput(.init(text: "[42/57] Compiling AgentTranscriptListView.swift\n", status: .inProgress))
        )
        let failedTool = AgentBlock(
            id: id("tool-failed"), revision: 1, kind: .toolCall,
            payload: .toolCall(.init(
                name: "Verify snapshots", summary: "The light appearance snapshot changed unexpectedly.", status: .failed
            ))
        )
        let failedOutput = AgentBlock(
            id: id("output-failed"), revision: 1, kind: .commandOutput,
            payload: .commandOutput(.init(
                text: "FAIL: transcript review baseline differs at 320 pt\n", exitCode: 1, status: .failed
            ))
        )
        let error = AgentBlock(
            id: id("error"), revision: 1, kind: .error,
            payload: .error(.init(
                message: "The candidate snapshot does not match the approved transcript baseline.",
                code: "snapshot_mismatch", isRecoverable: true
            ))
        )
        let approval = AgentBlock(
            id: id("approval"), revision: 1, kind: .approval,
            payload: .approval(.init(
                requestID: "provider-command-git-push",
                prompt: [
                    .text("The provider paused before running "),
                    .code("git push origin overnight/agent-ux"),
                    .text(". This writes commits to the remote repository. Continue?")
                ],
                status: .pending,
                choices: ["Allow once", "Decline"]
            ))
        )

        let assistantBlocks: [AgentBlock]
        switch state {
        case .mixed:
            assistantBlocks = assistantProse + [completedTool, plan, diff, notice]
        case .activeTool:
            assistantBlocks = [paragraph("active-intro", [.text("The checks are still running; routine detail remains structured and readable.")]), activeTool, activeOutput]
        case .failedTool:
            assistantBlocks = [paragraph("failed-intro", [.text("One visual check needs attention before this phase can close.")]), failedTool, failedOutput, error]
        case .approval:
            assistantBlocks = [
                paragraph("approval-intro", [.text("A provider-enforced request pauses only this turn. Its context and available choices stay inline.")]),
                approval,
            ]
        case .long:
            let continuation = (1...12).map { index in
                paragraph(
                    "continuation-\(index)",
                    [.text("Review note \(index): stable semantic rows preserve reading position while additional provider output arrives.")]
                )
            }
            assistantBlocks = assistantProse + [completedTool, plan, diff, activeTool, activeOutput, failedTool, failedOutput, error, approval] + continuation + [notice]
        }
        return AgentDocument(version: 1, entries: [user, entry("assistant", role: .assistant, blocks: assistantBlocks)])
    }

    static func tile(kind: TileKind, title: String) -> Tile {
        Tile(
            id: UUID(),
            kind: kind,
            title: title,
            frame: TileFrame(x: 0, y: 0, width: 480, height: 320),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "shell", projectRelativeCwd: ".")
        )
    }

    static func workspaceEntries() -> [WorkspaceEntry] {
        [
            WorkspaceEntry(id: workspaceId, name: "Continuum", projectIds: [UUID(), UUID()], createdAt: epoch, updatedAt: epoch),
            WorkspaceEntry(id: altWorkspaceId, name: "Scratch", projectIds: [], createdAt: epoch, updatedAt: epoch)
        ]
    }

    static func topBarModel(save: WorkspaceDocumentSaveState, message: String?) -> WorkspaceTopBarModel {
        WorkspaceTopBarModel(
            currentWorkspaceId: workspaceId,
            currentWorkspaceName: "Continuum",
            projectCount: 2,
            zoneCount: 3,
            saveState: save,
            workspaces: workspaceEntries(),
            managementMessage: message
        )
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.6-inbox-list-view.md
    //
    // Every `InboxState` once, both `RowEmphasis` values, a HEADLESS agent, a
    // spawned child at depth 1, both branch states (isolated / shared) and both
    // attention marks — one fixture rather than one card per state, the precedent
    // `managed-agent.branch-chip` set for exactly this reason ("three states, side
    // by side, so the PNG baselines cover all of them"). A card per state would
    // have re-rendered the same list five times to vary one row.
    //
    // Ids are canned like every other fixture here: `InboxSort` breaks ties on
    // them, and a random UUID would reorder the card between two renders and make
    // its committed baseline flap.
    //
    // P3.8 added the workspace names, which NOTHING DRAWS — a row shows its project
    // chip and no second one. They are here because the scope dropdown offers one
    // entry per workspace, and the shape it has to be exercised on is the awkward
    // one: two workspaces over the same project, one workspace spanning two
    // projects, and a headless agent in neither (it has no tile, so no workspace).
    static let inboxAgentIds: [UUID] = (1...7).map {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000003%02X", $0))!
    }

    static func inboxRows() -> [AgentInboxRow] {
        func at(_ minutes: Double) -> Date { epoch.addingTimeInterval(minutes * 60) }
        return [
            AgentInboxRow(
                id: inboxAgentIds[0], title: "codex · migration review", projectName: "continuum",
                workspaceName: "Overnight", state: .approval, attention: .unread, model: "gpt-5.6-sol", role: "reviewer",
                branch: "agent/migration-review", isIsolated: true, createdAt: at(60)),
            AgentInboxRow(
                id: inboxAgentIds[1], title: "claude · matrix green", projectName: "continuum",
                workspaceName: "Overnight", state: .working, model: "claude-opus-5", role: "builder",
                branch: "main", elapsed: 254, createdAt: at(50)),
            AgentInboxRow(
                id: inboxAgentIds[2], title: "pi · session naming", projectName: "bannockburn",
                workspaceName: "Overnight", state: .input, model: "gpt-5.6-sol", branch: "main", createdAt: at(40)),
            AgentInboxRow(
                id: inboxAgentIds[3], title: "codex · flake hunt", projectName: "continuum",
                workspaceName: "Side", state: .failed, model: "gpt-5.6-sol", role: "debugger",
                branch: "agent/flake-hunt", isIsolated: true, createdAt: at(30)),
            AgentInboxRow(
                id: inboxAgentIds[4], title: "claude · docs sweep", projectName: "continuum",
                workspaceName: "Overnight", state: .ready, model: "claude-opus-5", branch: "main", createdAt: at(20)),
            // HEADLESS (P2A.6): no tile renders it, so it has no tile title — its
            // name is the one the `AgentRecord` owns. It is `woke`, which is the one
            // attention value that keeps a row at full strength in any state.
            AgentInboxRow(
                id: inboxAgentIds[5], title: "orchestrator", projectName: "continuum",
                state: .ready, attention: .woke, model: "claude-opus-5", role: "orchestrator",
                createdAt: at(10)),
            // Its child (P2D.4): depth 1, and `InboxSort` places it immediately
            // after its parent whatever it is doing.
            AgentInboxRow(
                id: inboxAgentIds[6], title: "claude · child worker", projectName: "continuum",
                workspaceName: "Overnight", state: .working, model: "claude-opus-5", role: "builder",
                branch: "agent/child-worker", isIsolated: true, elapsed: 8_460,
                depth: 1, createdAt: at(5), parentId: inboxAgentIds[5]),
        ]
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.7-slim-rows.md
    /// The clock the inbox cards' relative times are read from. Canned like every
    /// other fixture here: a parked row renders "12m ago", and a wall clock would
    /// make its committed baseline match for one minute and fail for the next
    /// fifty-nine. It sits 15 minutes after the newest agent was spawned, so every
    /// settled distance below is positive and small enough to read in whole units.
    static var inboxNow: Date { epoch.addingTimeInterval(75 * 60) }

    /// THE SAME SEVEN AGENTS as `inboxRows()`, with three parked. Deliberately the
    /// same list rather than a second one: the packet's verification is "baselines
    /// for card and slim variants of the SAME agent", so `chrome.agentInbox` and
    /// `chrome.agentInbox.parked` differ in exactly the lifecycles, and a diff of
    /// the two PNGs is the collapse.
    ///
    /// The three cover what the rule turns on: a settled `ready` row (the ordinary
    /// case), a settled `failed` one (collapsing is about being FINISHED WITH, not
    /// about being unimportant — and it is the row whose glyph carries an accent),
    /// and a snoozed one (whose time runs the other way, "in 25m"). The four left
    /// active are the witness for the other half — `ready`, `failed`, `working` and
    /// `approval` rows that stay full cards.
    static func inboxParkedRows() -> [AgentInboxRow] {
        func at(_ minutes: Double) -> Date { epoch.addingTimeInterval(minutes * 60) }
        let parked: [UUID: InboxLifecycle] = [
            inboxAgentIds[4]: .settled(at: at(63)),
            inboxAgentIds[3]: .settled(at: at(21)),
            inboxAgentIds[2]: .snoozed(until: at(100)),
        ]
        return inboxRows().map { row in
            guard let lifecycle = parked[row.id] else { return row }
            return AgentInboxRow(
                id: row.id, title: row.title, projectName: row.projectName,
                workspaceName: row.workspaceName, state: row.state,
                attention: row.attention, lifecycle: lifecycle, model: row.model, role: row.role,
                branch: row.branch, isIsolated: row.isIsolated, elapsed: row.elapsed,
                depth: row.depth, variant: RowVariant.forLifecycle(lifecycle),
                createdAt: row.createdAt, parentId: row.parentId)
        }
    }

    // Ticket: docs/38-tickets/90-agent-ux/P4.8-settled-tail-paging.md
    /// TWELVE SETTLED AGENTS — the first list in this file long enough to page, so
    /// the tail's footer is a view that exists at all. Ten are drawn and two are
    /// held, which is the state the footer only ever renders in.
    ///
    /// A separate fixture rather than more rows on `inboxParkedRows()`: that list is
    /// the subject of two committed baselines whose whole content is the card-vs-slim
    /// comparison, and lengthening it past the page limit would change both renders
    /// for a reason that has nothing to do with what they hold.
    ///
    /// All settled and nothing else, because the footer is a fact about the tail
    /// alone — an active block here would only push rows off the bottom of the
    /// surface, which is where the footer has to be visible.
    static func inboxPagedRows() -> [AgentInboxRow] {
        func at(_ minutes: Double) -> Date { epoch.addingTimeInterval(minutes * 60) }
        return (0..<12).map { index in
            // Ended one minute apart, newest first, so `mostRecentlyEndedFirst` has a
            // strict order to put them in and the page is not decided by a tie-break.
            let ended = at(70 - Double(index))
            return AgentInboxRow(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000004%02X", index))!,
                title: "claude · finished run \(index + 1)", projectName: "continuum",
                workspaceName: "Overnight", state: index == 3 ? .failed : .ready,
                lifecycle: .settled(at: ended), model: "claude-opus-5",
                branch: "agent/finished-\(index + 1)",
                variant: RowVariant.forLifecycle(.settled(at: ended)),
                createdAt: at(Double(index)))
        }
    }

    static func sidebarTree() -> SidebarTree {
        let alpha = SidebarZoneRow(
            zoneId: selectedZoneId, name: "continuum-revived", color: "#5B8DEF", navKey: "1", collapsed: false, projectId: UUID(),
            agentStatusRollup: SidebarAgentStatusRollup(working: 1, needsAttention: 1),
            tiles: [
                SidebarTileRow(tileId: selectedTileId, title: "claude · feature/login", kind: .terminal, agentStatus: .working),
                SidebarTileRow(tileId: UUID(), title: "shell", kind: .terminal, agentStatus: nil),
                SidebarTileRow(tileId: UUID(), title: "localhost:3000", kind: .browser, agentStatus: nil)
            ]
        )
        let beta = SidebarZoneRow(
            zoneId: UUID(), name: "notes", color: "#E0A458", navKey: "2", collapsed: false, projectId: nil,
            tiles: [SidebarTileRow(tileId: UUID(), title: "scratch.md", kind: .note, agentStatus: nil)]
        )
        return SidebarTree(workspaces: [
            SidebarWorkspaceRow(workspaceId: workspaceId, name: "Continuum", zones: [alpha, beta])
        ])
    }

    static func richSidebarTree() -> SidebarTree {
        let currentZone = SidebarZoneRow(
            zoneId: selectedZoneId, name: "continuum-revived", color: "#5B8DEF", navKey: "1", collapsed: false, projectId: UUID(),
            agentStatusRollup: SidebarAgentStatusRollup(working: 1, needsAttention: 1),
            tiles: [
                SidebarTileRow(tileId: selectedTileId, title: "claude · feature/login", kind: .terminal, agentStatus: .needsAttention),
                SidebarTileRow(tileId: UUID(), title: "shell", kind: .terminal, agentStatus: .working),
                SidebarTileRow(tileId: UUID(), title: "localhost:3000", kind: .browser, agentStatus: nil)
            ]
        )
        let scratchZone = SidebarZoneRow(
            zoneId: UUID(), name: "notes", color: "#E0A458", navKey: "1", collapsed: false, projectId: nil,
            tiles: [
                SidebarTileRow(tileId: UUID(), title: "scratch.md", kind: .note, agentStatus: nil)
            ]
        )
        return SidebarTree(workspaces: [
            SidebarWorkspaceRow(workspaceId: workspaceId, name: "Continuum", zones: [currentZone]),
            SidebarWorkspaceRow(workspaceId: altWorkspaceId, name: "Scratch", zones: [scratchZone])
        ])
    }

}

// MARK: - Sandbox

/// Owns a live canvas + a spawn toolbar + zoom controls for an interactive
/// sandbox. Fixture tiles install directly (no runtime); a throwaway temp dir
/// backs File/FileTree tiles and is deleted on teardown. (Runtime tiles —
/// terminal/browser — are added in a later phase via `env`.)
@MainActor
final class LabSandboxContext: NSObject {
    let canvas: CanvasNSView
    let containerView: NSView
    let env: LabEnvironment

    private let tempDir: URL
    private let sampleFilePath: String
    private var spawner: TileSpawner?
    private var teardownBlocks: [() -> Void] = []
    private var spawnCount = 0
    private var affordancesOn = false
    private let zoomLabel = NSTextField(labelWithString: "100%")

    init(env: LabEnvironment) {
        self.env = env
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("continuum-lab/\(UUID().uuidString)", isDirectory: true)
        sampleFilePath = tempDir.appendingPathComponent("README.md").path
        canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil
        ))
        containerView = NSView()
        super.init()

        let fm = FileManager.default
        try? fm.createDirectory(at: tempDir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try? "# Sandbox\n\nA real File tile rendering a file from disk.\n".write(toFile: sampleFilePath, atomically: true, encoding: .utf8)
        try? "let answer = 42\n".write(to: tempDir.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)

        // Runtime tiles (terminal/browser) spawn through the real TileSpawner
        // using the app's shared engines. TileSpawner needs a browserEngine, so
        // the spawner only exists when one was injected (absent in headless checks).
        if let browserEngine = env.browserEngine {
            let store = ProjectStore(projectRoot: tempDir)
            let project = Project(
                id: UUID(), name: "Lab Sandbox", rootPath: tempDir.path,
                createdAt: Date(), updatedAt: Date(),
                defaultLaunchProfileId: "shell", editorPreference: .auto,
                settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning)
            )
            spawner = TileSpawner(canvasView: canvas, ghostty: env.ghostty, browserEngine: browserEngine, projectStore: store, project: project)
        }

        canvas.onTileCloseRequested = { [weak canvas] id in canvas?.removeTile(id: id) }
        buildContainer()
        registerTeardown { [tempDir] in try? FileManager.default.removeItem(at: tempDir) }
    }

    func registerTeardown(_ block: @escaping () -> Void) { teardownBlocks.append(block) }

    var qaTempDirExists: Bool { FileManager.default.fileExists(atPath: tempDir.path) }

    func teardownAll() {
        teardownBlocks.reversed().forEach { $0() }
        teardownBlocks.removeAll()
        canvas.removeFromSuperview()
        containerView.removeFromSuperview()
    }

    // MARK: Layout

    private func buildContainer() {
        let toolbar = makeToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(toolbar)
        containerView.addSubview(canvas)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: containerView.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 38),
            canvas.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
    }

    private func makeToolbar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).appResolvedCGColor

        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            return b
        }
        let terminalButton = button("Terminal", #selector(spawnTerminalClicked))
        terminalButton.isEnabled = spawner != nil && env.ghostty != nil
        terminalButton.toolTip = terminalButton.isEnabled ? nil : "No Ghostty runtime available in this build"
        let browserButton = button("Browser", #selector(spawnBrowserClicked))
        browserButton.isEnabled = spawner != nil
        let spawn = NSStackView(views: [
            terminalButton,
            browserButton,
            button("Note", #selector(spawnNoteClicked)),
            button("File", #selector(spawnFileClicked)),
            button("File Tree", #selector(spawnFileTreeClicked))
        ])
        spawn.spacing = 6

        let affordanceToggle = NSButton(checkboxWithTitle: "Hitboxes", target: self, action: #selector(toggleAffordancesClicked(_:)))
        affordanceToggle.controlSize = .small
        affordanceToggle.toolTip = "Overlay each tile's interaction zones + live screen-px metrics"

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.setContentHuggingPriority(.required, for: .horizontal)
        let zoom = NSStackView(views: [
            affordanceToggle,
            button("−", #selector(zoomOutClicked)),
            zoomLabel,
            button("+", #selector(zoomInClicked)),
            button("Reset", #selector(zoomResetClicked))
        ])
        zoom.spacing = 4

        let row = NSStackView(views: [spawn, NSView(), zoom])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        return bar
    }

    // MARK: Spawning (fixture tiles — no runtime)

    private func nextZ() -> FracIndex { CanvasEngine.zPositionAbove(canvas.canvasState.tiles) }

    /// Install a fixture tile and give it the current affordance-overlay state.
    private func install(_ view: TileNSView, for tile: Tile) {
        canvas.install(tileView: view, for: tile)
        view.showsInteractionAffordances = affordancesOn
    }

    /// Apply the current toggle to every tile (used after runtime spawns, whose
    /// views the spawner installs directly, and when the toggle flips).
    private func applyAffordances() {
        for tileView in canvas.subviews.compactMap({ $0 as? TileNSView }) {
            tileView.showsInteractionAffordances = affordancesOn
        }
    }

    @objc private func toggleAffordancesClicked(_ sender: NSButton) {
        affordancesOn = sender.state == .on
        applyAffordances()
    }

    private func placement(for kind: TileKind) -> TileFrame {
        let size = CanvasEngine.defaultFrame(for: kind)
        let offset = Double(spawnCount % 6) * 36
        spawnCount += 1
        return TileFrame(x: 60 + offset, y: 60 + offset, width: size.width, height: size.height)
    }

    func spawnNote() {
        let noteId = UUID()
        let tile = Tile(id: UUID(), kind: .note, title: "note \(spawnCount + 1)", frame: placement(for: .note), zPosition: nextZ(), runtimeRef: nil, metadata: TileMetadata(noteId: noteId))
        install(NoteTileNSView(tile: tile, noteId: noteId, initialBody: "# Note\n\nType here…"), for: tile)
    }

    func spawnFile() {
        let tile = Tile(id: UUID(), kind: .file, title: "README.md", frame: placement(for: .file), zPosition: nextZ(), runtimeRef: nil, metadata: TileMetadata(filePath: sampleFilePath))
        install(FileTileNSView(tile: tile), for: tile)
    }

    func spawnFileTree() {
        let id = UUID()
        let fileTreeTile = FileTreeTile(tileId: id, rootPath: tempDir.path, expandedPaths: [], selectedPath: nil, searchQuery: "", ignoredNames: [], gitBadges: .off)
        let tile = Tile(id: id, kind: .fileTree, title: "Files", frame: placement(for: .fileTree), zPosition: nextZ(), runtimeRef: nil, metadata: TileMetadata(filePath: tempDir.path))
        install(FileTreeTileNSView(tile: tile, fileTreeTile: fileTreeTile), for: tile)
    }

    func spawnRunArtifacts() {
        let tile = Tile(id: UUID(), kind: .runArtifacts, title: "Run Artifacts", frame: placement(for: .runArtifacts), zPosition: nextZ(), runtimeRef: nil, metadata: TileMetadata())
        install(RunArtifactsTileNSView(tile: tile), for: tile)
    }

    func spawnDescriptor() {
        let tile = Tile(id: UUID(), kind: .terminal, title: "placeholder", frame: placement(for: .terminal), zPosition: nextZ(), runtimeRef: nil, metadata: TileMetadata())
        install(DescriptorTileNSView(tile: tile), for: tile)
    }

    // Runtime tiles — real terminal/browser via TileSpawner; each registers a
    // teardown so closing the lab kills its PTY / webview (no orphan processes).
    func spawnTerminal() {
        guard let spawner else { return }
        // No tmux persistence: a throwaway lab terminal must not leave a tmux
        // session behind after the lab closes.
        if case let .spawned(runtime) = spawner.spawnTerminal(profileId: "shell", allowTmuxPersistence: false) {
            registerTeardown { runtime.terminate(policy: .force) }
        }
        applyAffordances()
    }

    func spawnBrowser() {
        guard let spawner else { return }
        if case let .spawned(runtime) = spawner.spawnBrowser(url: "about:blank") {
            registerTeardown { runtime.terminate(policy: .force) }
        }
        applyAffordances()
    }

    @objc private func spawnTerminalClicked() { spawnTerminal() }
    @objc private func spawnBrowserClicked() { spawnBrowser() }
    @objc private func spawnNoteClicked() { spawnNote() }
    @objc private func spawnFileClicked() { spawnFile() }
    @objc private func spawnFileTreeClicked() { spawnFileTree() }
    @objc private func spawnRunArtifactsClicked() { spawnRunArtifacts() }
    @objc private func spawnDescriptorClicked() { spawnDescriptor() }

    // MARK: Zoom (drives the same path as pinch — keeps cursor rects + metrics live)

    func setZoom(_ z: Double) {
        let clamped = min(3.0, max(0.25, z))
        let vp = canvas.viewport
        canvas.setViewport(CanvasViewport(x: vp.x, y: vp.y, zoom: clamped))
        zoomLabel.stringValue = "\(Int((clamped * 100).rounded()))%"
    }

    @objc private func zoomInClicked() { setZoom(canvas.viewport.zoom * 1.25) }
    @objc private func zoomOutClicked() { setZoom(canvas.viewport.zoom / 1.25) }
    @objc private func zoomResetClicked() { setZoom(1) }
}

@MainActor
final class AgentTranscriptReviewSurface: NSView {
    static let contentInset = CGFloat(Space.l)

    let state: AgentTranscriptReviewState
    let transcript: AgentTranscriptListView
    private(set) var renderError: Error?
    private var positionedInitialViewport = false

    init(state: AgentTranscriptReviewState, size: NSSize, theme: TokenTheme) {
        self.state = state
        transcript = AgentTranscriptListView(renderContext: AgentRenderContext(
            actions: .disabled, tokens: .transcript, appearance: theme
        ))
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        addSubview(transcript)
        transcript.frame = bounds.insetBy(dx: Self.contentInset, dy: Self.contentInset)
        transcript.layoutSubtreeIfNeeded()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Transcript design review, \(state.rawValue)")
        applyTheme(theme)

        let document = LabFixtures.transcriptReviewDocument(state)
        do {
            try transcript.apply(
                document: document,
                patch: AgentDocumentPatch(
                    fromVersion: 0, toVersion: document.version,
                    inserted: document.entries.flatMap(\.blocks).map(\.id)
                )
            )
        } catch {
            renderError = error
        }
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        transcript.frame = bounds.insetBy(dx: Self.contentInset, dy: Self.contentInset)
        transcript.layoutSubtreeIfNeeded()
        transcript.collectionView.layoutSubtreeIfNeeded()
        guard !positionedInitialViewport else { return }
        positionedInitialViewport = true
        if state == .mixed || state == .long {
            transcript.scrollView.contentView.scroll(to: .zero)
            transcript.scrollView.reflectScrolledClipView(transcript.scrollView.contentView)
        } else {
            transcript.jumpToLatest()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let theme = effectiveTokenTheme
        applyTheme(theme)
        do {
            try transcript.updateRenderContext(AgentRenderContext(
                actions: .disabled, tokens: .transcript, appearance: theme
            ))
        } catch {
            renderError = error
        }
    }

    private func applyTheme(_ theme: TokenTheme) {
        layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(for: theme)
    }
}

/// P4.10 review surface for the composer variants. Deterministic drafts and
/// presentation states only: nothing here sends, stops, or fabricates a response
/// contract — the compact states are the presentation-only shell the packet
/// scopes them to.
@MainActor
final class AgentComposerReviewSurface: NSView {
    static let contentInset = CGFloat(Space.l)

    let state: AgentComposerReviewState
    let composer: AgentComposerView
    private(set) var footer: AgentComposerFooterView?
    private(set) var actionButton: ComposerActionButton?
    private(set) var choiceList: ChoiceListView?

    static func preferredSize(for state: AgentComposerReviewState, width: CGFloat = 480) -> NSSize {
        switch state {
        case .empty, .focused, .compactEmpty:
            return NSSize(width: width, height: 150)
        case .multiline, .working, .compactLong:
            return NSSize(width: width, height: 220)
        case .long:
            return NSSize(width: width, height: 300)
        case .modelMenu, .effortMenu, .completion:
            return NSSize(width: width, height: 400)
        }
    }

    init(state: AgentComposerReviewState, size: NSSize, theme: TokenTheme) {
        self.state = state
        composer = AgentComposerView(frame: .zero, variant: state.variant)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        addSubview(composer)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Composer design review, \(state.rawValue)")

        composer.apply(AgentComposerDraft(
            text: Self.draftText(for: state),
            selection: NSRange(location: (Self.draftText(for: state) as NSString).length, length: 0),
            revision: 1
        ))

        if state.variant == .fullTurn {
            let footer = AgentComposerFooterView(frame: .zero)
            footer.apply(.init(model: "openai-codex/gpt-5.4-mini", thinking: "xhigh"))
            addSubview(footer)
            self.footer = footer

            let presentation: AgentComposerPresentation
            switch state {
            case .working:
                presentation = .resolve(
                    state: .working,
                    capabilities: .init(canSend: true, canStop: true, canSteer: false, canQueue: false),
                    hasDraft: false
                )
            default:
                presentation = .resolve(
                    state: .ready,
                    capabilities: .init(canSend: true, canStop: false, canSteer: false, canQueue: false),
                    hasDraft: !Self.draftText(for: state).isEmpty
                )
            }
            let button = ComposerActionButton(presentation: presentation)
            addSubview(button)
            actionButton = button
        }

        if let items = Self.choiceItems(for: state) {
            let list = ChoiceListView(items: items.items, selectedID: items.selectedID)
            addSubview(list)
            choiceList = list
        }

        applyTheme(theme)
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if state == .focused, let window {
            window.makeFirstResponder(composer.textView)
        }
    }

    override func layout() {
        super.layout()
        let inset = Self.contentInset
        let width = max(1, bounds.width - inset * 2)
        composer.frame = NSRect(x: inset, y: inset, width: width, height: max(composer.frame.height, 44))
        composer.layoutSubtreeIfNeeded()
        composer.frame = NSRect(x: inset, y: inset, width: width, height: composer.intrinsicContentSize.height)
        composer.layoutSubtreeIfNeeded()
        var nextY = composer.frame.maxY + CGFloat(Space.m)

        if let footer, let actionButton {
            let buttonSize = actionButton.intrinsicContentSize
            actionButton.frame = NSRect(
                x: inset + width - buttonSize.width,
                y: nextY,
                width: buttonSize.width,
                height: max(buttonSize.height, AgentComposerFooterView.height)
            )
            footer.frame = NSRect(
                x: inset,
                y: nextY,
                width: max(1, actionButton.frame.minX - CGFloat(Space.m) - inset),
                height: AgentComposerFooterView.height
            )
            footer.layoutSubtreeIfNeeded()
            nextY = footer.frame.maxY + CGFloat(Space.m)
        }

        if let choiceList {
            let listSize = choiceList.intrinsicContentSize
            let anchorX: CGFloat
            switch state {
            case .effortMenu:
                anchorX = min(inset + 220, bounds.width - inset - listSize.width)
            default:
                anchorX = inset
            }
            choiceList.frame = NSRect(
                x: max(inset, anchorX),
                y: nextY,
                width: min(listSize.width, width),
                height: listSize.height
            )
            choiceList.layoutSubtreeIfNeeded()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme(effectiveTokenTheme)
    }

    private func applyTheme(_ theme: TokenTheme) {
        layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(for: theme)
    }

    private static func draftText(for state: AgentComposerReviewState) -> String {
        switch state {
        case .empty, .compactEmpty, .modelMenu, .effortMenu:
            return ""
        case .focused:
            return "Summarize the failing checks before the next run."
        case .multiline:
            return "Review the dropdown corrections:\n- quiet idle fill\n- one panel boundary"
        case .long:
            return (1...12).map { "Line \($0) of a long prompt that exceeds the visual cap." }
                .joined(separator: "\n")
        case .working:
            return ""
        case .completion:
            return "Compare @Choice"
        case .compactLong:
            return (1...6).map { "Compact response line \($0)." }.joined(separator: "\n")
        }
    }

    /// The open-menu review states show the exact list content the anchored panel
    /// would present: the footer's real catalogue items for model/effort, and
    /// reference suggestions shaped like the bounded completion fixtures.
    private static func choiceItems(for state: AgentComposerReviewState) -> (items: [ChoiceItem], selectedID: String?)? {
        switch state {
        case .modelMenu:
            let footer = AgentComposerFooterView(frame: NSRect(x: 0, y: 0, width: 560, height: 32))
            footer.apply(.init(model: "openai-codex/gpt-5.4-mini", thinking: "xhigh"))
            footer.layoutSubtreeIfNeeded()
            return (footer.modelButton.items, footer.modelButton.selectedID)
        case .effortMenu:
            let footer = AgentComposerFooterView(frame: NSRect(x: 0, y: 0, width: 560, height: 32))
            footer.apply(.init(model: "openai-codex/gpt-5.4-mini", thinking: "xhigh"))
            footer.layoutSubtreeIfNeeded()
            return (footer.effortButton.items, footer.effortButton.selectedID)
        case .completion:
            return ([
                ChoiceItem(id: "completion-0", title: "ChoiceButton.swift", detail: "Sources/ContinuumRevived/Canvas/AgentComposer"),
                ChoiceItem(id: "completion-1", title: "ChoiceListView.swift", detail: "Sources/ContinuumRevived/Canvas/AgentComposer"),
                ChoiceItem(id: "completion-2", title: "ChoicePopoverController.swift", detail: "Sources/ContinuumRevived/Canvas/AgentComposer"),
            ], nil)
        default:
            return nil
        }
    }
}

// MARK: - Catalog

@MainActor
enum LabCatalog {
    static func entries(env: LabEnvironment) -> [LabEntry] {
        [
            tileSandbox, sidebarCard, observerSidebarCard, topBarCard, pairingTokenCard, agentKindCard,
            observerRollupCard, statusChipsCard, agentsBoardCard, approvalsInboxCard, canvasSceneCard, pushSmokeCard,
            notifyCategoriesCard, agentAdapterProjectionCard, managedSessionRecordCard,
            sessionNamingCard, commandPaletteLauncher, settingsLauncher, projectPickerLauncher,
            sidebarLiveCard, activityDockCard, sidebarSelectedCard, managedAgentCard,
            transcriptReviewCard, composerReviewCard, composerFullVariantCard,
            composerCompactVariantCard, composerProviderControlsCard,

            // MARK: night3-C cards
            managedAgentApprovalDockCard, newTileCwdPolicyCard,
            topologyMigrationNoteCard,

            // MARK: 90-agent-ux cards
            branchChipCard, agentInboxCard, agentInboxSelectedCard, agentInboxParkedCard,
            agentInboxShelfCard, agentInboxJumpHintsCard, agentInboxBulkCard,
            managedAgentProviderCard
        ]
    }

    /// Muted body/metadata text on a lab card (P1.6).
    ///
    /// These cards used Apple's `secondaryLabelColor` (#808080 → 3.95:1 on white)
    /// and `tertiaryLabelColor` (#BDBDBD → 1.88:1), which P1.3's ruling 1 replaced
    /// with a house colour precisely because neither clears AA by construction.
    /// The lab cards ARE the surfaces `--ui-contrast-check` measures headlessly,
    /// so leaving them on the AppKit greys would mean the gate can only ever be
    /// green with an exemption — and an exemption is what the packet forbids.
    ///
    /// Dynamic rather than resolved-at-build: a lab card is a plain factory-built
    /// `NSTextField` with no `applyTokens()` hook, so the appearance has to be
    /// AppKit's to resolve. `dynamicNSColor` is P1.8's existing bridge.
    static var mutedLabelColor: NSColor {
        StatusChipNSView.dynamicNSColor(TextToken.textSecondary.color)
    }

    /// Fixed UUID used by the "session naming" panel — see docs/38-tickets/14-project-session-naming.md.
    static let sessionNamingFixtureId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static var sessionNamingCard: LabEntry {
        LabEntry(
            id: "session.naming", category: "Chrome", title: "Session Naming",
            summary: "The pure TmuxSession naming functions (ticket 14), printed for a fixed UUID.",
            content: .staticCard(preferredSize: NSSize(width: 560, height: 120)) {
                makeSessionNamingView(fixtureId: sessionNamingFixtureId)
            }
        )
    }

    static func makeSessionNamingView(fixtureId: UUID) -> NSView {
        func row(_ identifier: String, _ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.identifier = NSUserInterfaceItemIdentifier(identifier)
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.textColor = .labelColor
            return field
        }
        let stack = NSStackView(views: [
            row("sessionNaming.projectSessionName", "projectSessionName  → \(TmuxSession.projectSessionName(projectId: fixtureId))"),
            row("sessionNaming.ambientSessionName", "ambientSessionName  → \(TmuxSession.ambientSessionName(workspaceId: fixtureId))"),
            row("sessionNaming.sessionName", "sessionName(tileId) → \(TmuxSession.sessionName(tileId: fixtureId))")
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    static var agentKindCard: LabEntry {
        LabEntry(
            id: "agent.kind", category: "Chrome", title: "Agent Kind",
            summary: "Descriptor kind row used by the agent-status inspector.",
            content: .staticCard(preferredSize: NSSize(width: 280, height: 96)) {
                makeAgentKindView(descriptor: AgentDescriptor(agentKind: .claude, worktreePath: "/tmp/project", status: .working, statusUpdatedAt: LabFixtures.epoch))
            }
        )
    }

    static var observerRollupCard: LabEntry {
        LabEntry(
            id: "observer.rollup",
            category: "Agent Status",
            title: "Observer rollup — live feed simulation",
            summary: "Canvas zone chrome and tile badges driven by an observer status snapshot.",
            content: .staticCard(preferredSize: NSSize(width: 640, height: 340)) {
                makeObserverRollupView()
            }
        )
    }

    static func makeObserverRollupView() -> CanvasNSView {
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-00000000A431")!
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-00000000A432")!
        let workingId = UUID(uuidString: "00000000-0000-0000-0000-00000000A433")!
        let needsId = UUID(uuidString: "00000000-0000-0000-0000-00000000A434")!
        let plainId = UUID(uuidString: "00000000-0000-0000-0000-00000000A435")!
        let zone = ZonePlacement(
            zoneId: zoneId,
            projectId: projectId,
            origin: ZonePoint(x: 12, y: 12),
            size: ZoneSize(width: 616, height: 316),
            color: "blue",
            collapsed: false,
            hydrationPolicy: .automatic,
            name: "Agent Status"
        )
        let tiles = [
            Tile(id: workingId, kind: .terminal, title: "claude · working", frame: TileFrame(x: 42, y: 72, width: 170, height: 122), zPosition: .fromLegacyRank(1), zoneId: zoneId, runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: needsId, kind: .terminal, title: "codex · needs", frame: TileFrame(x: 236, y: 72, width: 170, height: 122), zPosition: .fromLegacyRank(2), zoneId: zoneId, runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: plainId, kind: .terminal, title: "shell", frame: TileFrame(x: 430, y: 72, width: 150, height: 122), zPosition: .fromLegacyRank(3), zoneId: zoneId, runtimeRef: nil, metadata: TileMetadata())
        ]
        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: tiles, groups: [], lastActiveTileId: workingId),
            activeZone: zone,
            zoneRenderModels: [CanvasNSView.ZoneRenderModel(placement: zone, displayName: "Agent Status")],
            showsZoneChrome: true
        )
        canvas.frame = NSRect(x: 0, y: 0, width: 640, height: 340)
        for tile in tiles {
            canvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
        }
        canvas.tileView(for: workingId)?.agentStatus = .working
        canvas.tileView(for: needsId)?.agentStatus = .needsAttention
        canvas.tileView(for: plainId)?.agentStatus = nil
        canvas.updateZoneRenderModels([
            CanvasNSView.ZoneRenderModel(
                placement: zone,
                displayName: "Agent Status",
                agentStatusRollup: CanvasNSView.AgentStatusRollup(working: 1, needsAttention: 1, done: 0, stale: 0)
            )
        ])
        canvas.layoutSubtreeIfNeeded()
        return canvas
    }

    // Ticket 87: first agent-UI building block. Renders every AgentStatus
    // through the shared StatusChipPresenter so the Layer-2 vision-QA pass
    // sees exactly what production paints, across all states at once.
    static var statusChipsCard: LabEntry {
        LabEntry(
            id: "agent.statusChip",
            category: "Agent UI",
            title: "Status Chip",
            summary: "Every AgentStatus via the shared StatusChipPresenter — contrast owned + tested (ticket 87).",
            content: .staticCard(preferredSize: NSSize(width: 360, height: 260)) {
                makeStatusChipGalleryView()
            }
        )
    }

    static func makeStatusChipGalleryView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let title = NSTextField(labelWithString: "Status Chips")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        stack.addArrangedSubview(title)

        for status in AgentStatus.allCases {
            let chip = StatusChipNSView(status: status)
            chip.identifier = NSUserInterfaceItemIdentifier("statusChip.\(status.rawValue)")
            // The trailing spacer keeps the chip hugging its own width instead of
            // stretching to the row. It MUST be height-constrained: a bare `NSView()`
            // has no intrinsic size and no constraints, so the row's height was
            // ambiguous and the solver settled on the chip's height or a stretched one
            // NONDETERMINISTICALLY — the same card rendered with two different vertical
            // spacings between runs, which made `--ui-baseline-check` coin-flip on
            // `agent.statusChip` and made blessing it whack-a-mole.
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 0).isActive = true
            let row = NSStackView(views: [chip, spacer])
            row.orientation = .horizontal
            row.alignment = .centerY
            stack.addArrangedSubview(row)
        }
        return stack
    }

    static var agentsBoardCard: LabEntry {
        LabEntry(
            id: "agents.board",
            category: "Chrome",
            title: "Agents Board",
            summary: "Activity projection rows sorted attention-first with glyph and color tokens.",
            content: .staticCard(preferredSize: NSSize(width: 620, height: 190)) {
                makeAgentsBoardView(rows: agentsBoardRows())
            }
        )
    }

    static var approvalsInboxCard: LabEntry {
        LabEntry(
            id: "approvals.inbox",
            category: "Chrome",
            title: "Approvals Inbox",
            summary: "Needs-attention rows folded through the shared approvals helpers, including scope gating.",
            content: .staticCard(preferredSize: NSSize(width: 680, height: 160)) {
                makeApprovalsInboxView(snapshot: approvalsInboxSnapshot())
            }
        )
    }

    static var pushSmokeCard: LabEntry {
        LabEntry(
            id: "push.smoke",
            category: "Chrome",
            title: "Push Smoke",
            summary: "N1-N8 APNS fixture payloads plus firing/dedup table output.",
            content: .staticCard(preferredSize: NSSize(width: 900, height: 315)) {
                makePushSmokeView()
            }
        )
    }

    static func makePushSmokeView() -> NSView {
        func label(_ identifier: String, _ text: String, size: CGFloat = 11) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.identifier = NSUserInterfaceItemIdentifier(identifier)
            field.font = .monospacedSystemFont(ofSize: size, weight: .regular)
            field.textColor = .labelColor
            field.lineBreakMode = .byTruncatingTail
            return field
        }
        let rows: [NSView] = PushCategory.allCases.enumerated().map { index, category in
            let payload = (try? PushPayloadBuilder.fixturePayload(for: category)) ?? PushPayload(category: category, title: "invalid", body: "invalid", deepLink: "\(PairingURL.scheme)://invalid")
            let actions = category.actionIds.isEmpty ? "-" : category.actionIds.joined(separator: ",")
            return label(
                "pushSmoke.row.\(index + 1)",
                "\(category.rawValue) \(category.identifier) level=\(category.interruptionLevel.rawValue) title=\(payload.title) body=\(payload.body) link=\(payload.deepLink) actions=\(actions)"
            )
        }
        let outcome = label("pushSmoke.outcome", "firing: fire -> dedup-suppressed -> refire on phase change")
        outcome.textColor = mutedLabelColor
        let stack = NSStackView(views: [label("pushSmoke.title", "Push Smoke", size: 13)] + rows + [outcome])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    static var notifyCategoriesCard: LabEntry {
        LabEntry(
            id: "notify.categories",
            category: "Chrome",
            title: "Notify Categories",
            summary: "Agents settings toggle rows backed by persisted push category gates.",
            content: .staticCard(preferredSize: NSSize(width: 620, height: 245)) {
                makeNotifyCategoriesView()
            }
        )
    }

    static func makeNotifyCategoriesView() -> NSView {
        func label(_ identifier: String, _ text: String, size: CGFloat = 11) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.identifier = NSUserInterfaceItemIdentifier(identifier)
            field.font = .monospacedSystemFont(ofSize: size, weight: .regular)
            field.textColor = .labelColor
            field.lineBreakMode = .byTruncatingTail
            return field
        }
        let suiteName = "Continuum.ComponentLab.NotifyCategories"
        UserDefaults().removePersistentDomain(forName: suiteName)
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = PersistedPushCategoryPreferences(defaults: defaults)
        let agents = SettingsSchema.sections().first { $0.id == "agents" }
        let toggleFields = agents?.fields.compactMap { field -> SettingsField? in
            if case .toggle = field { return field }
            return nil
        } ?? []
        let categories = PushCategory.allCases.filter(\.isMuteable)
        let rows: [NSView] = zip(toggleFields, categories).enumerated().map { index, pair in
            let (field, category) = pair
            let state = field.currentValue(in: defaults) == .bool(true) ? "on" : "off"
            let gate = preferences.isEnabled(category) ? "allow" : "mute"
            return label(
                "notifyCategories.row.\(index + 1)",
                "\(category.rawValue) \(field.label) key=\(field.key ?? "-") default=\(state) gate=\(gate)"
            )
        }
        let stack = NSStackView(views: [label("notifyCategories.title", "Notify Categories", size: 13)] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    static func agentsBoardRows() -> [AgentsBoardRow] {
        let replica = UUID(uuidString: "61000000-0000-4000-8000-0000000000CC")!
        let base = Date(timeIntervalSinceReferenceDate: 6_167)
        func event(agentId: UUID, sequence: UInt64, status: AgentStatus, summary: String, offset: TimeInterval) -> AgentActivityEvent {
            AgentActivityEvent(
                stamping: AgentActivityEventDraft(
                    agentId: agentId,
                    tileId: agentId,
                    runId: nil,
                    tone: status == .needsAttention ? .approval : .info,
                    kind: status == .needsAttention ? "needs-attention" : "status.\(status.rawValue)",
                    status: status,
                    summary: summary,
                    occurredAt: base.addingTimeInterval(offset)
                ),
                sequence: sequence,
                replicaId: replica
            )
        }
        let alpha = UUID(uuidString: "61000000-0000-4000-8000-0000000000A1")!
        let beta = UUID(uuidString: "61000000-0000-4000-8000-0000000000B2")!
        let gamma = UUID(uuidString: "61000000-0000-4000-8000-0000000000C3")!
        let delta = UUID(uuidString: "61000000-0000-4000-8000-0000000000D4")!
        let snapshot = [
            event(agentId: gamma, sequence: 1, status: .done, summary: "gamma finished cleanly", offset: 1),
            event(agentId: alpha, sequence: 2, status: .needsAttention, summary: "alpha needs approval", offset: 4),
            event(agentId: delta, sequence: 3, status: .working, summary: "delta is running checks", offset: 3),
            event(agentId: beta, sequence: 4, status: .needsAttention, summary: "beta needs input", offset: 2),
        ].reduce(ActivityLogSnapshot.empty) { apply($0, $1) }
        return AgentsBoardProjection.rows(from: snapshot)
    }

    static func approvalsInboxSnapshot() -> ActivityLogSnapshot {
        let replica = UUID(uuidString: "62000000-0000-4000-8000-0000000000CC")!
        let base = Date(timeIntervalSinceReferenceDate: 6_267)
        func event(agentId: UUID, sequence: UInt64, status: AgentStatus, summary: String, offset: TimeInterval, approvalRequestId: String? = nil) -> AgentActivityEvent {
            AgentActivityEvent(
                stamping: AgentActivityEventDraft(
                    agentId: agentId,
                    tileId: agentId,
                    runId: nil,
                    tone: status == .needsAttention ? .approval : .info,
                    kind: status == .needsAttention ? "needs-attention" : "status.\(status.rawValue)",
                    status: status,
                    summary: summary,
                    occurredAt: base.addingTimeInterval(offset),
                    approvalRequestId: approvalRequestId
                ),
                sequence: sequence,
                replicaId: replica
            )
        }
        let withId = UUID(uuidString: "62000000-0000-4000-8000-0000000000A1")!
        let withoutId = UUID(uuidString: "62000000-0000-4000-8000-0000000000B2")!
        let working = UUID(uuidString: "62000000-0000-4000-8000-0000000000C3")!
        return [
            event(agentId: working, sequence: 1, status: .working, summary: "gamma is running", offset: 1),
            event(agentId: withId, sequence: 2, status: .needsAttention, summary: "alpha approve deploy", offset: 3, approvalRequestId: "approval-alpha"),
            event(agentId: withoutId, sequence: 3, status: .needsAttention, summary: "beta legacy request", offset: 2),
        ].reduce(ActivityLogSnapshot.empty) { apply($0, $1) }
    }

    static func makeAgentsBoardView(rows: [AgentsBoardRow]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let title = NSTextField(labelWithString: "Agents Board")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        stack.addArrangedSubview(title)

        for (index, row) in rows.enumerated() {
            let display = StatusChipPresenter.display(for: row.status)
            let label = NSTextField(labelWithString: "\(display.glyph) \(row.status.rawValue) \(row.lastSummary)")
            label.identifier = NSUserInterfaceItemIdentifier("agentsBoard.row.\(index + 1)")
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = statusColor(for: row.status)
            stack.addArrangedSubview(label)
        }
        return stack
    }

    static func makeApprovalsInboxView(snapshot: ActivityLogSnapshot) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let title = NSTextField(labelWithString: "Approvals Inbox — attentionCount=\(AgentsBoardProjection.attentionCount(from: snapshot))")
        title.identifier = NSUserInterfaceItemIdentifier("approvalsInbox.count")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        stack.addArrangedSubview(title)

        let rows = AgentsBoardProjection.approvalsInboxRows(from: snapshot)
        for (index, row) in rows.enumerated() {
            let target = snapshot.byAgent[row.agentId].flatMap { AgentsBoardProjection.respondableRequest(in: $0) }
            let request = target?.approvalRequestId ?? "no-id"
            let label = NSTextField(labelWithString: "\(StatusChipPresenter.display(for: row.status).glyph) \(row.lastSummary) request=\(request)")
            label.identifier = NSUserInterfaceItemIdentifier("approvalsInbox.row.\(index + 1)")
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = statusColor(for: row.status)
            stack.addArrangedSubview(label)
        }

        let observerGate: String
        func scopeName(_ scope: Scope) -> String {
            switch scope {
            case .orchestrationRead:
                "orchestrationRead"
            case .orchestrationOperate:
                "orchestrationOperate"
            case .terminalOperate:
                "terminalOperate"
            case .accessRead:
                "accessRead"
            case .accessWrite:
                "accessWrite"
            default:
                "\(scope.rawValue)"
            }
        }
        do {
            try authorize(.respondToApproval, grantedScopes: .observer)
            observerGate = "observer=allowed"
        } catch AuthError.missingScope(let scope) {
            observerGate = "observer=missing:\(scopeName(scope))"
        } catch {
            observerGate = "observer=error"
        }
        let operatorGate = (try? authorize(.respondToApproval, grantedScopes: .operator)) != nil ? "operator=allowed" : "operator=denied"
        let scope = NSTextField(labelWithString: "\(observerGate) \(operatorGate)")
        scope.identifier = NSUserInterfaceItemIdentifier("approvalsInbox.scope")
        scope.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        scope.textColor = mutedLabelColor
        stack.addArrangedSubview(scope)

        return stack
    }

    static var canvasSceneCard: LabEntry {
        LabEntry(
            id: "canvas.scene",
            category: "Chrome",
            title: "Canvas Scene",
            summary: "Spatial state folded through CanvasSceneProjection: zones with tint tokens, tiles with glyph tokens + render order + membership.",
            content: .staticCard(preferredSize: NSSize(width: 460, height: 220)) {
                makeCanvasSceneView(scene: canvasSceneFixture())
            }
        )
    }

    /// 2 zones + 4 tiles, one membership, distinct z-orders — ticket
    /// 61b's ComponentLab fixture, folded through the REAL `CanvasSceneProjection`.
    static func canvasSceneFixture() -> CanvasScene {
        let zoneAlpha = UUID(uuidString: "61B00000-0000-4000-8000-0000000000A1")!
        let zoneBeta = UUID(uuidString: "61B00000-0000-4000-8000-0000000000B2")!
        let tileA = UUID(uuidString: "61B00000-0000-4000-8000-00000000000A")!
        let tileB = UUID(uuidString: "61B00000-0000-4000-8000-00000000000B")!
        let tileC = UUID(uuidString: "61B00000-0000-4000-8000-00000000000C")!
        let tileD = UUID(uuidString: "61B00000-0000-4000-8000-00000000000D")!

        let canvasState = CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [
                Tile(id: tileA, kind: .terminal, title: "shell", frame: TileFrame(x: 0, y: 0, width: 480, height: 320), zPosition: FracIndex(value: 0.15), zoneId: nil, runtimeRef: nil, metadata: TileMetadata()),
                // The one membership: tileB lives in zoneAlpha.
                Tile(id: tileB, kind: .browser, title: "localhost:3000", frame: TileFrame(x: 500, y: 0, width: 480, height: 320), zPosition: FracIndex(value: 0.35), zoneId: zoneAlpha, runtimeRef: nil, metadata: TileMetadata()),
                Tile(id: tileC, kind: .note, title: "scratch.md", frame: TileFrame(x: 0, y: 400, width: 320, height: 240), zPosition: FracIndex(value: 0.55), zoneId: nil, runtimeRef: nil, metadata: TileMetadata()),
                Tile(id: tileD, kind: .fileTree, title: "files", frame: TileFrame(x: 400, y: 400, width: 320, height: 240), zPosition: FracIndex(value: 0.75), zoneId: nil, runtimeRef: nil, metadata: TileMetadata())
            ],
            groups: [],
            lastActiveTileId: nil
        )
        let workspaceDocument = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [
                ZonePlacement(zoneId: zoneAlpha, projectId: nil, origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 1000, height: 700), color: "mint", collapsed: false, hydrationPolicy: .automatic, name: "Alpha", navKey: nil, zPosition: FracIndex(value: 0.3)),
                ZonePlacement(zoneId: zoneBeta, projectId: nil, origin: ZonePoint(x: 1200, y: 0), size: ZoneSize(width: 800, height: 600), color: "amber", collapsed: false, hydrationPolicy: .automatic, name: "Beta", navKey: nil, zPosition: FracIndex(value: 0.6))
            ],
            lastActiveZoneId: nil
        )
        return CanvasSceneProjection.scene(canvasState: canvasState, workspaceDocument: workspaceDocument)
    }

    static func makeCanvasSceneView(scene: CanvasScene) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let title = NSTextField(labelWithString: "Canvas Scene")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        stack.addArrangedSubview(title)

        for (index, zone) in scene.zones.enumerated() {
            let label = NSTextField(labelWithString: "\(zone.name) [\(zone.tintToken)] z=\(zone.zPosition.value)")
            label.identifier = NSUserInterfaceItemIdentifier("canvasScene.zone.\(index + 1)")
            label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            label.textColor = .labelColor
            stack.addArrangedSubview(label)
        }
        for (index, tile) in scene.tiles.enumerated() {
            let membership = scene.zones.first { $0.zoneId == tile.zoneId }?.name ?? "ambient"
            let label = NSTextField(labelWithString: "#\(index + 1) \(tile.kindGlyphToken) — \(tile.title) (\(membership))")
            label.identifier = NSUserInterfaceItemIdentifier("canvasScene.tile.\(index + 1)")
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .labelColor
            stack.addArrangedSubview(label)
        }
        return stack
    }

    static func makeAgentKindView(descriptor: AgentDescriptor) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let title = NSTextField(labelWithString: "Agent Status")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor

        let kind = NSTextField(labelWithString: "Kind -> \(descriptor.agentKind.rawValue)")
        kind.identifier = NSUserInterfaceItemIdentifier("agentKind.value")
        kind.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        kind.textColor = .labelColor

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(kind)
        return stack
    }

    static var agentAdapterProjectionCard: LabEntry {
        LabEntry(
            id: "agent.adapter.projection",
            category: "Chrome",
            title: "AgentAdapter Event Projection",
            summary: "Managed adapter event stream projected through deriveStatusSignals.",
            content: .staticCard(preferredSize: NSSize(width: 520, height: 260)) {
                makeAgentAdapterProjectionView()
            }
        )
    }

    static func agentAdapterProjectionRows() -> [(String, AgentStatus)] {
        let threadId = "lab-thread"
        let events: [AgentRuntimeEvent] = [
            .sessionStateChanged(.starting),
            .sessionStateChanged(.running),
            .turnStarted(threadId: threadId, turnId: "turn-1"),
            .itemStarted(threadId: threadId, itemId: "item-1", kind: .commandExecution, title: "run build"),
            .requestOpened(threadId: threadId, requestId: "request-1", kind: .commandExecutionApproval),
            .requestResolved(threadId: threadId, requestId: "request-1", decision: "approve"),
            .itemCompleted(threadId: threadId, itemId: "item-1", kind: .commandExecution, status: .completed),
            .turnCompleted(threadId: threadId, turnId: "turn-1", outcome: .completed, errorMessage: nil),
            .sessionStateChanged(.ready)
        ]
        var accumulated: [AgentRuntimeEvent] = []
        return events.enumerated().map { index, event in
            accumulated.append(event)
            let signals = deriveStatusSignals(from: accumulated, threadId: threadId, engineStatus: .idle)
            return ("\(index + 1). \(agentRuntimeEventName(event))", deriveAgentStatus(signals: signals))
        }
    }

    static func makeAgentAdapterProjectionView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let title = NSTextField(labelWithString: "AgentAdapter Event Projection")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        stack.addArrangedSubview(title)

        for (index, row) in agentAdapterProjectionRows().enumerated() {
            let field = NSTextField(labelWithString: "\(row.0) -> \(row.1.rawValue)")
            field.identifier = NSUserInterfaceItemIdentifier("agentAdapterProjection.row.\(index + 1)")
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.textColor = statusColor(for: row.1)
            stack.addArrangedSubview(field)
        }
        return stack
    }

    private static func agentRuntimeEventName(_ event: AgentRuntimeEvent) -> String {
        switch event {
        case .sessionStateChanged(let state): return "sessionStateChanged(\(state.rawValue))"
        case .turnStarted: return "turnStarted"
        case .turnCompleted(_, _, let outcome, _): return "turnCompleted(\(outcome.rawValue))"
        case .itemStarted(_, _, let kind, _): return "itemStarted(\(kind.rawValue))"
        case .itemCompleted(_, _, let kind, let status): return "itemCompleted(\(kind.rawValue), \(status.rawValue))"
        case .contentDelta: return "contentDelta"
        case .requestOpened: return "requestOpened"
        case .requestResolved: return "requestResolved"
        case .userInputRequested: return "userInputRequested"
        case .userInputResolved: return "userInputResolved"
        case .tokenUsageUpdated: return "tokenUsageUpdated"
        case .runtimeError: return "runtimeError"
        }
    }

    // P1.8: the Lab's own `color(for:)` and its `color(forToken:)` decoder for
    // `AgentStatusPresentation.colorToken` are both gone — a catalogue that
    // paints its own hues is a catalogue that cannot show what production
    // paints. Every Lab card now reads the shared presenter.
    private static func statusColor(for status: AgentStatus) -> NSColor {
        StatusChipNSView.dynamicNSColor(StatusChipPresenter.display(for: status).accent)
    }

    static var managedSessionRecordCard: LabEntry {
        LabEntry(
            id: "managed.session.record",
            category: "Chrome",
            title: "Managed Session Record",
            summary: "Private host-local record fields for a managed terminal binding.",
            content: .staticCard(preferredSize: NSSize(width: 420, height: 132)) {
                makeManagedSessionRecordView(record: managedSessionRecordFixture)
            }
        )
    }

    static var managedSessionRecordFixture: ManagedAgentSessionRecord {
        let payload = try! ManagedAgentSessionRecord.makeRuntimePayload(windowTarget: "%42", cwd: "/tmp/continuum")
        return ManagedAgentSessionRecord(
            tileId: UUID(uuidString: "23000000-0000-4000-8000-000000000042")!,
            agentKind: .shell,
            status: .running,
            lastSeenAt: LabFixtures.epoch,
            runtimePayload: payload
        )
    }

    static func makeManagedSessionRecordView(record: ManagedAgentSessionRecord) -> NSView {
        func row(_ identifier: String, _ label: String, _ value: String) -> NSTextField {
            let field = NSTextField(labelWithString: "\(label)  → \(value)")
            field.identifier = NSUserInterfaceItemIdentifier(identifier)
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.textColor = .labelColor
            return field
        }
        let stack = NSStackView(views: [
            row("managedSession.agentKind", "agentKind", record.agentKind.rawValue),
            row("managedSession.status", "status", record.status.rawValue),
            row("managedSession.tmuxWindowTarget", "tmuxWindowTarget", record.tmuxWindowTarget() ?? "")
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private static var pairingTokenCard: LabEntry {
        LabEntry(
            id: "auth.pairingToken", category: "Auth", title: "Pairing Token",
            summary: "Generated observer pairing URL with the credential carried only in the fragment.",
            content: .staticCard(preferredSize: NSSize(width: 560, height: 126)) {
                makePairingTokenView()
            }
        )
    }

    static func makePairingTokenView() -> NSView {
        // Canned, like every other Lab fixture: a freshly generated credential made
        // this the one card whose render differed on every draw, so it could not
        // carry a committed PNG baseline (P0.6). The generator's real properties —
        // length, crowd-safe alphabet, and distribution bias over 5k draws — are
        // gated directly in `AuthChecks.runPairingAlphabetBiasCheck`, not here.
        let credential = LabFixtures.pairingCredential
        let url = PairingURL.issue(credential: credential, scopes: .observer)

        let title = NSTextField(labelWithString: "Pairing Token")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor

        let urlLabel = NSTextField(wrappingLabelWithString: url.absoluteString)
        urlLabel.identifier = NSUserInterfaceItemIdentifier("pairingToken.url")
        urlLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        urlLabel.textColor = .labelColor
        urlLabel.lineBreakMode = .byCharWrapping

        let credentialLabel = NSTextField(labelWithString: credential)
        credentialLabel.identifier = NSUserInterfaceItemIdentifier("pairingToken.credential")
        credentialLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        // Emphasis, not the system accent: `controlAccentColor` defaults to
        // `#007AFF`, which is 4.02:1 on this card's white — root cause 3 of
        // P0.4's 177 (an undarkened accent used as TEXT). `accentWorking` is the
        // same blue with a darkened light-appearance variant.
        credentialLabel.textColor = StatusChipNSView.dynamicNSColor(AccentToken.accentWorking.color)

        let stack = NSStackView(views: [title, urlLabel, credentialLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.controlBackgroundColor.appResolvedCGColor
        return stack
    }

    private static var commandPaletteLauncher: LabEntry {
        LabEntry(
            id: "panel.palette", category: "Palettes & Settings", title: "Command Palette",
            summary: "The real ⌘K launch palette. Opens empty here — the app fills it with live profiles/projects.",
            content: .launcher(buttonTitle: "Open Command Palette") { host in
                let palette = LaunchProfilePalette()
                palette.show(near: host, profiles: [])
                return palette
            }
        )
    }

    private static var settingsLauncher: LabEntry {
        LabEntry(
            id: "panel.settings", category: "Palettes & Settings", title: "Settings",
            summary: "The real Settings panel, live schema.",
            content: .launcher(buttonTitle: "Open Settings") { host in
                let panel = SettingsPanel()
                panel.show(near: host)
                return panel
            }
        )
    }

    private static var projectPickerLauncher: LabEntry {
        LabEntry(
            id: "panel.projectPicker", category: "Palettes & Settings", title: "Project Picker",
            summary: "The modal project picker (empty rows). Runs modally, then dismisses.",
            content: .launcher(buttonTitle: "Open Project Picker") { _ in
                _ = ProjectPickerPanel(request: ProjectLaunchCoordinator.PickerRequest(reason: .noUsableProject, rows: [], workspaces: [])).runModal()
                return nil
            }
        )
    }

    private static var tileSandbox: LabEntry {
        LabEntry(
            id: "tiles.sandbox", category: "Tiles", title: "Tile Sandbox",
            summary: "A live canvas — spawn real tiles from the toolbar, then drag, resize, and zoom them.",
            content: .canvasSandbox { ctx in
                ctx.spawnNote()
                ctx.spawnFileTree()
            }
        )
    }

    private static var sidebarCard: LabEntry {
        LabEntry(
            id: "chrome.sidebar", category: "Chrome", title: "Workspace Sidebar",
            summary: "Workspace ▸ zone ▸ tile tree with agent-status rollups.",
            content: .staticCard(preferredSize: NSSize(width: 280, height: 560)) {
                let view = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 560))
                view.reload(tree: LabFixtures.sidebarTree(), currentWorkspaceId: LabFixtures.workspaceId)
                view.reloadInbox(rows: LabFixtures.inboxRows())
                return view
            }
        )
    }

    private static var observerSidebarCard: LabEntry {
        LabEntry(
            id: "chrome.sidebar.observerFeed", category: "Chrome", title: "Observer-fed Sidebar",
            summary: "Workspace sidebar rows and zone rollups from a live observer status snapshot.",
            content: .staticCard(preferredSize: NSSize(width: 300, height: 420)) {
                let view = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 420))
                view.reload(tree: observerSidebarTree(), currentWorkspaceId: LabFixtures.workspaceId)
                view.reloadInbox(rows: LabFixtures.inboxRows())
                return view
            }
        )
    }

    private static func observerSidebarTree() -> SidebarTree {
        let activeZoneId = UUID(uuidString: "00000000-0000-0000-0000-00000000B441")!
        let queueZoneId = UUID(uuidString: "00000000-0000-0000-0000-00000000B442")!
        let needsTileId = UUID(uuidString: "00000000-0000-0000-0000-00000000B451")!
        let workingTileId = UUID(uuidString: "00000000-0000-0000-0000-00000000B452")!
        let idleTileId = UUID(uuidString: "00000000-0000-0000-0000-00000000B453")!
        let active = SidebarZoneRow(
            zoneId: activeZoneId,
            name: "agent queue",
            color: "blue",
            navKey: "1",
            collapsed: false,
            projectId: UUID(uuidString: "00000000-0000-0000-0000-00000000B461")!,
            agentStatusRollup: SidebarAgentStatusRollup(working: 1, needsAttention: 1),
            tiles: [
                SidebarTileRow(tileId: needsTileId, title: "claude · review fix", kind: .terminal, agentStatus: .needsAttention),
                SidebarTileRow(tileId: workingTileId, title: "codex · matrix", kind: .terminal, agentStatus: .working)
            ]
        )
        let queue = SidebarZoneRow(
            zoneId: queueZoneId,
            name: "scratch",
            color: "mint",
            navKey: "2",
            collapsed: false,
            projectId: nil,
            tiles: [
                SidebarTileRow(tileId: idleTileId, title: "release notes", kind: .note, agentStatus: nil)
            ]
        )
        return SidebarTree(workspaces: [
            SidebarWorkspaceRow(workspaceId: LabFixtures.workspaceId, name: "Continuum", zones: [active, queue])
        ])
    }

    private static var topBarCard: LabEntry {
        LabEntry(
            id: "chrome.topbar", category: "Chrome", title: "Workspace Top Bar",
            summary: "Identity, counts, save state, and the workspace switcher.",
            content: .staticCard(preferredSize: NSSize(width: 720, height: 44)) {
                let view = WorkspaceTopBarView(frame: NSRect(x: 0, y: 0, width: 720, height: 44))
                view.reload(LabFixtures.topBarModel(save: .unsavedChanges, message: nil))
                return view
            }
        )
    }

    // MARK: night3-C cards

    private static var sidebarLiveCard: LabEntry {
        LabEntry(
            id: "chrome.sidebar.live",
            category: "Chrome",
            title: "Workspace Sidebar — Rich Fixture",
            summary: "Two workspaces, mixed statuses, current expanded. Confirms rollup precedence and collapse.",
            content: .staticCard(preferredSize: NSSize(width: 280, height: 640)) {
                let view = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 640))
                view.reload(tree: LabFixtures.richSidebarTree(), currentWorkspaceId: LabFixtures.workspaceId)
                view.reloadInbox(rows: LabFixtures.inboxRows())
                return view
            }
        )
    }

    private static var activityDockCard: LabEntry {
        LabEntry(
            id: "chrome.activityDock",
            category: "Chrome",
            title: "Activity Dock",
            summary: "Default visible dock at 280 pt with the richer sidebar fixture.",
            content: .staticCard(preferredSize: NSSize(width: 280, height: 600)) {
                let view = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
                view.reload(tree: LabFixtures.richSidebarTree(), currentWorkspaceId: LabFixtures.workspaceId)
                view.reloadInbox(rows: LabFixtures.inboxRows())
                return view
            }
        )
    }
    private static var sidebarSelectedCard: LabEntry {
        LabEntry(
            id: "chrome.sidebar.selected",
            category: "Chrome",
            title: "Workspace Sidebar - tile selected",
            summary: "Workspace tree with the clicked tile row selected.",
            content: .staticCard(preferredSize: NSSize(width: 280, height: 560)) {
                let view = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 560))
                view.reload(tree: LabFixtures.sidebarTree(), currentWorkspaceId: LabFixtures.workspaceId)
                view.reloadInbox(rows: LabFixtures.inboxRows())
                _ = view.inboxForQA.selectRowForQA(id: LabFixtures.inboxAgentIds[1])
                _ = view.select(
                    workspaceId: LabFixtures.workspaceId,
                    zoneId: LabFixtures.selectedZoneId,
                    tileId: LabFixtures.selectedTileId
                )
                return view
            }
        )
    }

    private static var managedAgentCard: LabEntry {
        LabEntry(
            id: "tiles.managedAgent",
            category: "Tiles",
            title: "Managed Agent Tile",
            summary: "Structured transcript card stack with a persistent managed-agent status header.",
            content: .staticCard(preferredSize: NSSize(width: 560, height: 560)) {
                makeManagedAgentFixtureView()
            }
        )
    }

    private static var transcriptReviewCard: LabEntry {
        LabEntry(
            id: "agent.transcript.review",
            category: "Managed Agent",
            title: "Semantic Transcript — Supervised Review",
            summary: "The complete mixed semantic transcript. Scroll, select, copy, and inspect hierarchy before composer work begins.",
            content: .reviewSurface(preferredSize: NSSize(width: 640, height: 720)) {
                AgentTranscriptReviewSurface(state: .long, size: NSSize(width: 640, height: 720), theme: .dark)
            }
        )
    }

    static func makeTranscriptReviewSurface(
        state: AgentTranscriptReviewState,
        size: NSSize,
        theme: TokenTheme
    ) -> AgentTranscriptReviewSurface {
        AgentTranscriptReviewSurface(state: state, size: size, theme: theme)
    }

    static func makeComposerReviewSurface(
        state: AgentComposerReviewState,
        size: NSSize,
        theme: TokenTheme
    ) -> AgentComposerReviewSurface {
        AgentComposerReviewSurface(state: state, size: size, theme: theme)
    }

    private static var composerReviewCard: LabEntry {
        LabEntry(
            id: "agent.composer.review",
            category: "Managed Agent",
            title: "Agent Composer — Isolated Shell",
            summary: "Native multiline editing under custom Continuum chrome. Type, select, paste, and undo without migrating the live tile.",
            content: .reviewSurface(preferredSize: NSSize(width: 480, height: 96)) {
                AgentComposerView(frame: NSRect(x: 0, y: 0, width: 480, height: 96))
            }
        )
    }

    private static var composerFullVariantCard: LabEntry {
        let size = AgentComposerReviewSurface.preferredSize(for: .multiline)
        return LabEntry(
            id: "agent.composer.full-variant",
            category: "Managed Agent",
            title: "Composer — Full-Turn Variant",
            summary: "The complete command surface: multiline draft, next-turn model/effort, and Send. 1–8 visual lines with provider /, @, and $ completion.",
            content: .reviewSurface(preferredSize: size) {
                AgentComposerReviewSurface(state: .multiline, size: size, theme: .dark)
            }
        )
    }

    private static var composerCompactVariantCard: LabEntry {
        let size = AgentComposerReviewSurface.preferredSize(for: .compactLong)
        return LabEntry(
            id: "agent.composer.compact-variant",
            category: "Managed Agent",
            title: "Composer — Compact Freeform Shell",
            summary: "Presentation-only response shell: shared native editing in a 1–4-line frame, no model/effort controls, reference (@ and $) completion only. No response contract is fabricated.",
            content: .reviewSurface(preferredSize: size) {
                AgentComposerReviewSurface(state: .compactLong, size: size, theme: .dark)
            }
        )
    }

    private static var composerProviderControlsCard: LabEntry {
        LabEntry(
            id: "agent.composer.provider-controls",
            category: "Managed Agent",
            title: "Composer Model and Effort",
            summary: "Custom next-turn choices at narrow width, using the same catalogue and popover as the composer footer.",
            content: .reviewSurface(preferredSize: NSSize(width: 360, height: 48)) {
                let footer = AgentComposerFooterView(frame: NSRect(x: 0, y: 0, width: 360, height: 48))
                footer.apply(.init(model: "openai-codex/gpt-5.4-mini", thinking: "xhigh"))
                return footer
            }
        )
    }

    private static var managedAgentApprovalDockCard: LabEntry {
        LabEntry(
            id: "managed-agent.approval-dock",
            category: "Managed Agent",
            title: "Approval dock - three states",
            summary: "Working, waiting with orange dock and border, then done.",
            // P6.1: the card grows with its three tiles rather than holding the 720
            // they used to add up to — 3 tiles, 2 gaps of `Space.l`, and the stack's
            // own `Space.l` inset top and bottom.
            content: .staticCard(preferredSize: NSSize(
                width: 560,
                height: 3 * approvalDockPreviewTileHeight + 4 * Space.l
            )) {
                makeManagedAgentApprovalDockPreview()
            }
        )
    }

    // Ticket: docs/38-tickets/90-agent-ux/P6.1-per-agent-model-effort.md
    /// The compose area with its two pickers, holding values that are NOT the global
    /// default — so the gates measure a per-agent choice rather than the seed, and
    /// the PNG beside `tiles.managedAgent` (which shows the default) is the visual
    /// witness that two agents can hold different models at the same time.
    ///
    /// A whole tile, because the compose row is `ManagedAgentTileNSView`'s own
    /// subview and cannot be rendered outside it. Shorter than the other tile card
    /// and with no approval open, so the compose area is most of what the card is.
    ///
    /// Its fixture ends mid-turn, so this card's pickers render UNAVAILABLE while
    /// `tiles.managedAgent`'s (which ends on `needsAttention`) render live — the two
    /// baselines are the visual pair for "they go dark with the rest of compose while
    /// a turn is in flight", which is otherwise only asserted as a Bool.
    private static var managedAgentProviderCard: LabEntry {
        LabEntry(
            id: "managed-agent.provider-controls",
            category: "Managed Agent",
            title: "Model and effort - a per-agent choice",
            summary: "The compose area's model and thinking pickers, on values the global default did not give them.",
            content: .staticCard(preferredSize: NSSize(width: 560, height: 320)) {
                let view = makeManagedAgentFixtureView(includeApproval: false)
                view.frame = NSRect(x: 0, y: 0, width: 560, height: 320)
                view.applyProviderSettings(AgentModelConfig.Resolution(
                    model: "openai-codex/gpt-5.4-mini",
                    thinking: "xhigh"
                ))
                return view
            }
        )
    }

    /// P2C.4's three states, side by side, so the PNG baselines cover all of them
    /// and the contrast gate measures the warning variant as well as the plain one.
    private static var branchChipCard: LabEntry {
        LabEntry(
            id: "managed-agent.branch-chip",
            category: "Managed Agent",
            title: "Branch chip - three states",
            summary: "Shared checkout, an isolated agent on its own branch, and one that has left it.",
            content: .staticCard(preferredSize: NSSize(width: 420, height: 200)) {
                makeBranchChipPreview()
            }
        )
    }

    /// P3.6's list, with every `InboxState`, both emphases, a headless agent and a
    /// spawned child — see `LabFixtures.inboxRows()` for why it is one card and not
    /// one per state.
    private static var agentInboxCard: LabEntry {
        LabEntry(
            id: "chrome.agentInbox",
            category: "Chrome",
            title: "Agent Inbox",
            summary: "Five states, frozen creation order, a headless agent and one spawned child.",
            content: .staticCard(preferredSize: NSSize(width: 320, height: 620 + AgentInboxView.scopeControlHeight)) {
                makeAgentInboxPreview(selecting: nil)
            }
        )
    }

    /// The same list with one row selected: selection clears P3.5's recession on
    /// that row and outlines its card in `borderStrong`, and both are pixel facts
    /// that only a second baseline can hold still.
    private static var agentInboxSelectedCard: LabEntry {
        LabEntry(
            id: "chrome.agentInbox.selected",
            category: "Chrome",
            title: "Agent Inbox - row selected",
            summary: "The working row selected: it stops receding and its card takes the selection outline.",
            content: .staticCard(preferredSize: NSSize(width: 320, height: 620 + AgentInboxView.scopeControlHeight)) {
                makeAgentInboxPreview(selecting: LabFixtures.inboxAgentIds[1])
            }
        )
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.7-slim-rows.md
    /// The same list with three agents parked: settled and snoozed collapse to one
    /// line, the other four stay full cards. Its baseline against
    /// `chrome.agentInbox`'s is the card-vs-slim comparison for the same agents.
    private static var agentInboxParkedCard: LabEntry {
        LabEntry(
            id: "chrome.agentInbox.parked",
            category: "Chrome",
            title: "Agent Inbox - settled and snoozed",
            summary: "Two settled rows and one snoozed collapse to ~36pt; ready, failed, working and approval stay cards.",
            content: .staticCard(preferredSize: NSSize(width: 320, height: 620 + AgentInboxView.scopeControlHeight)) {
                // P4.7 opens the shelf for this card: the collapsed default is
                // `chrome.agentInbox.shelf`'s subject, and a folded shelf here would
                // take the snoozed row — the one collapsed row whose glyph carries an
                // accent — out of the contrast, pixel and baseline sweeps entirely.
                makeAgentInboxPreview(
                    selecting: nil, rows: LabFixtures.inboxParkedRows(), expandShelf: true)
            }
        )
    }

    // Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md
    /// The same three parked agents with the shelf AS IT SHIPS — collapsed. Its
    /// baseline against `chrome.agentInbox.parked`'s is the fold: the snoozed row is
    /// gone, one counted heading stands in its place, and the settled tail below it
    /// has not moved otherwise.
    private static var agentInboxShelfCard: LabEntry {
        LabEntry(
            id: "chrome.agentInbox.shelf",
            category: "Chrome",
            title: "Agent Inbox - shelf collapsed",
            summary: "The snoozed agent folded behind a counted heading, with the settled tail still below it.",
            content: .staticCard(preferredSize: NSSize(width: 320, height: 620 + AgentInboxView.scopeControlHeight)) {
                makeAgentInboxPreview(selecting: nil, rows: LabFixtures.inboxParkedRows())
            }
        )
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.10-jump-shortcuts.md
    /// The same list with ⌘ held: one hint pill per jumpable row, floating over the
    /// card. Its baseline against `chrome.agentInbox`'s is the only thing that can
    /// hold "the pill is an overlay" still in pixels — every word on every row has to
    /// be in exactly the same place in both.
    private static var agentInboxJumpHintsCard: LabEntry {
        LabEntry(
            id: "chrome.agentInbox.jumpHints",
            category: "Chrome",
            title: "Agent Inbox - ⌘ held",
            summary: "⌘1–⌘7 pills floating over the seven rows; nothing else in the list moves.",
            content: .staticCard(preferredSize: NSSize(width: 320, height: 620 + AgentInboxView.scopeControlHeight)) {
                makeAgentInboxPreview(selecting: nil, jumpHints: true)
            }
        )
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.11-multi-select-bulk.md
    /// The same list with two rows selected: both cards outlined, both at full
    /// strength, and the bulk bar floating over the bottom of the list. Its baseline
    /// against `chrome.agentInbox.selected`'s is what holds "the bar is an overlay"
    /// still in pixels — no row may move between the two.
    ///
    /// The two agents are chosen so the bar is FULL: neither is blocked and neither is
    /// running, so all five actions are offered, and one of them is isolated, so the
    /// kept-branch line renders too. A pair that could take nothing would render a bar
    /// with no control in it and hold nothing about the enablement.
    private static var agentInboxBulkCard: LabEntry {
        LabEntry(
            id: "chrome.agentInbox.bulk",
            category: "Chrome",
            title: "Agent Inbox - two rows selected",
            summary: "Two selected rows outlined, with the bulk bar offering the five actions and naming the branch a delete keeps.",
            content: .staticCard(preferredSize: NSSize(width: 320, height: 620 + AgentInboxView.scopeControlHeight)) {
                makeAgentInboxPreview(
                    selecting: nil,
                    selectingMany: [LabFixtures.inboxAgentIds[3], LabFixtures.inboxAgentIds[4]])
            }
        )
    }

    static func makeAgentInboxPreview(
        selecting id: UUID?,
        rows: [AgentInboxRow] = LabFixtures.inboxRows(),
        jumpHints: Bool = false,
        expandShelf: Bool = false,
        selectingMany ids: [UUID] = []
    ) -> NSView {
        // P3.8: 620 was the height that fitted this fixture's seven rows. The scope
        // popup sits above them, so the card is that much taller — the alternative is
        // a card whose last row is half cut off, which costs the contrast and pixel
        // sweeps a row's worth of coverage for no reason.
        let view = AgentInboxView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 620 + AgentInboxView.scopeControlHeight))
        // P3.7: pinned, not live — a parked row's "12m ago" is read off this clock,
        // and a wall-clock one would make the committed baseline flap by the minute.
        view.clock = { LabFixtures.inboxNow }
        // P3.10: set directly rather than through a synthesized `flagsChanged` — the
        // card is a render, not a responder, and there is no window to hold ⌘ in.
        // BEFORE `reload`, so the pills are there on the first cell build: flipping
        // the flag afterwards reloads nine rows of a table that has never laid out,
        // and the row geometry that came back disagreed with where the rows actually
        // drew (measured: `UIProbePixels` mapped row one's project label onto the
        // scope popup's white bezel and called the label flat).
        if jumpHints { view.setJumpHintsVisible(true) }
        view.reload(rows: rows)
        // P4.7: AFTER `reload`, through the same method the heading's own button
        // sends — the shelf is view state, so there is nothing to open until the
        // list has rows to put on it.
        if expandShelf { view.toggleShelf() }
        if let id { _ = view.selectRowForQA(id: id) }
        // P3.11: AFTER `reload`, which empties the selection — and through the same
        // accessor the checks drive, so the card renders the shipped selection path.
        //
        // The no-op handler is not decoration: with `onBulkAction` unset the bar shows no
        // menu at all (see `updateBulkBar` — an action that cannot be performed is not
        // offered), so a card meant to render the enablement has to be a card a host has
        // wired. What it renders is the menu, not the handler.
        if !ids.isEmpty {
            view.onBulkAction = { _, _ in }
            // P3.15 made the gate per-action, so the handler alone no longer offers
            // anything. The card is a render of P3.11's ENABLEMENT — which actions a
            // selection may take — so it declares every action wired; which of them the
            // shipped app performs today is `AppDelegate.wiredInboxBulkActions`, and the
            // baseline for this card must not move when that set grows.
            view.wiredBulkActions = Set(InboxBulkAction.allCases)
            _ = view.selectRowsForQA(ids: ids)
        }
        return view
    }

    /// Built through `BranchChipNSView.display(for:)` from real `AgentRowContext`
    /// values — never by setting the chip's text directly — so this card renders
    /// exactly what a tile would and cannot drift from the mapping under test.
    static func makeBranchChipPreview() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = Space.l
        root.edgeInsets = NSEdgeInsets(Inset.card)

        let states: [(String, AgentRowContext)] = [
            ("no worktree — shares the project checkout", AgentRowContext(
                agentKind: .managed, checkedOutBranch: "main")),
            ("isolated, on the branch it was given", AgentRowContext(
                agentKind: .managed,
                worktreeBranch: "agent/implementer-fix-auth-1a2b3c4d",
                checkedOutBranch: "agent/implementer-fix-auth-1a2b3c4d")),
            ("isolated, but its checkout has moved", AgentRowContext(
                agentKind: .managed,
                worktreeBranch: "agent/implementer-fix-auth-1a2b3c4d",
                checkedOutBranch: "main")),
        ]

        for (caption, context) in states {
            let chip = BranchChipNSView()
            chip.apply(BranchChipNSView.display(for: context))
            let label = NSTextField(labelWithString: caption)
            label.font = .token(.caption)
            label.textColor = mutedLabelColor
            let row = NSStackView(views: [chip, label])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Space.m
            root.addArrangedSubview(row)
        }
        return root
    }

    private static var newTileCwdPolicyCard: LabEntry {
        LabEntry(
            id: "terminal.new-tile-cwd",
            category: "Palettes & Settings",
            title: "New Terminal CWD Policy",
            summary: "Settings fixture for inherit-focus, project-root, and last-used fresh terminal cwd policy.",
            content: .staticCard(preferredSize: NSSize(width: 520, height: 180)) {
                makeNewTileCwdPolicyPreview()
            }
        )
    }

    private static var topologyMigrationNoteCard: LabEntry {
        LabEntry(
            id: "terminal.topology-migration-note",
            category: "Palettes & Settings",
            title: "Topology Migration Note",
            summary: "One-time upgrade copy for the stock alert shown before terminal restore.",
            content: .staticCard(preferredSize: NSSize(width: 520, height: 180)) {
                makeTopologyMigrationNotePreview()
            }
        )
    }

    static func makeTopologyMigrationNotePreview() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        let title = NSTextField(labelWithString: "Session model updated")
        title.identifier = NSUserInterfaceItemIdentifier("topologyMigration.title")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .labelColor
        root.addArrangedSubview(title)

        let body = NSTextField(wrappingLabelWithString: AppDelegate.topologyMigrationInformativeText)
        body.identifier = NSUserInterfaceItemIdentifier("topologyMigration.body")
        body.font = .systemFont(ofSize: 13)
        body.textColor = mutedLabelColor
        body.preferredMaxLayoutWidth = 460
        root.addArrangedSubview(body)

        let button = NSButton(title: "OK", target: nil, action: nil)
        button.identifier = NSUserInterfaceItemIdentifier("topologyMigration.ok")
        button.bezelStyle = .rounded
        button.controlSize = .regular
        root.addArrangedSubview(button)
        return root
    }

    static func makeNewTileCwdPolicyPreview() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let title = NSTextField(labelWithString: "New Terminal Working Directory")
        title.identifier = NSUserInterfaceItemIdentifier("newTileCwd.title")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        root.addArrangedSubview(title)

        let fixtureRows: [(NewTileCwdPolicy, String)] = [
            (.inheritFocus, "/Users/dylan/src/continuum/Sources"),
            (.projectRoot, "/Users/dylan/src/continuum"),
            (.lastUsed, "/Users/dylan/src/continuum/Tests")
        ]
        for (index, fixture) in fixtureRows.enumerated() {
            let field = NSTextField(labelWithString: "\(fixture.0.rawValue) -> \(fixture.1)")
            field.identifier = NSUserInterfaceItemIdentifier("newTileCwd.policy.\(index)")
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.textColor = mutedLabelColor
            root.addArrangedSubview(field)
        }

        let key = NSTextField(labelWithString: NewTileCwdConfig.userDefaultsKey)
        key.identifier = NSUserInterfaceItemIdentifier("newTileCwd.defaultsKey")
        key.font = .systemFont(ofSize: 11, weight: .regular)
        // Was `tertiaryLabelColor` — 1.88:1 on white, the single worst pair the
        // real-tree audit found. There is no third text tier in the palette by
        // design, so the hierarchy is carried by size and weight, not by fading
        // the text below AA.
        key.textColor = mutedLabelColor
        root.addArrangedSubview(key)
        return root
    }

    /// P6.1: these preview tiles were a hardcoded 210pt, which stopped fitting the
    /// moment the compose area grew a picker row — the transcript's scroll view laid
    /// out to 520x0 and `--component-lab-check` named it. DERIVED from the tile's own
    /// fixed chrome plus three body lines of transcript, so the next control that
    /// changes height moves this instead of collapsing the transcript again.
    static var approvalDockPreviewTileHeight: Double {
        // P5.5: the legacy dock is gone — the request renders as a transcript
        // block, so the derived height reserves transcript lines for it instead
        // of a fixed dock band.
        AgentTileHeaderView.preferredHeight                                // header
            + Metrics.rowHeight(for: .body, insets: Inset.card)            // composer row
            + ManagedAgentTileNSView.providerControlHeight                 // the model/effort row
            + Metrics.rowHeight(for: .body, lines: 6, insets: Inset.card)  // transcript incl. request block
    }

    static func makeManagedAgentApprovalDockPreview() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        func stateView(title: String, status: AgentStatus, pending: Bool) -> ManagedAgentTileNSView {
            let tile = Tile(
                id: UUID(),
                kind: .managedAgent,
                title: title,
                frame: TileFrame(x: 0, y: 0, width: 520, height: approvalDockPreviewTileHeight),
                zPosition: .fromLegacyRank(1),
                runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed")
            )
            let view = ManagedAgentTileNSView(tile: tile)
            view.frame = NSRect(x: 0, y: 0, width: 520, height: approvalDockPreviewTileHeight)
            view.layoutSubtreeIfNeeded()
            view.ingest(.sessionStateChanged(status == .done ? .stopped : .running))
            view.ingest(.turnStarted(threadId: "thread-main", turnId: "turn-\(status.rawValue)"))
            view.ingest(.contentDelta(threadId: "thread-main", turnId: "turn-\(status.rawValue)", streamKind: .assistant, delta: "Checking the auth change set."))
            if status == .done {
                view.ingest(.turnCompleted(threadId: "thread-main", turnId: "turn-\(status.rawValue)", outcome: .completed, errorMessage: nil))
            }
            if pending {
                view.ingest(.requestOpened(threadId: "thread-main", requestId: "approval-preview", kind: .commandExecutionApproval))
            } else {
                view.agentStatus = status
            }
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 520).isActive = true
            view.heightAnchor.constraint(equalToConstant: approvalDockPreviewTileHeight).isActive = true
            if pending {
                // The card stands in for the canvas's marching-ants attention
                // ring, so it must be painted from the same source: P1.8's one
                // status→appearance mapping, solid, exactly as
                // `CanvasNSView.attentionAccent` now paints it. It was
                // `systemOrange@0.9`, which `--ui-contrast-check` measured at
                // 2.07:1 against the light tile body — and the real overlay had
                // the same defect, by copy. A fixture that depicts a colour the
                // app no longer paints is a gate reading the wrong thing.
                view.layer?.borderColor = StatusChipNSView
                    .dynamicNSColor(StatusChipPresenter.display(for: .needsAttention).accent).cgColor
                view.layer?.borderWidth = 2
            }
            return view
        }

        root.addArrangedSubview(stateView(title: "Claude · feature/auth", status: .working, pending: false))
        root.addArrangedSubview(stateView(title: "Claude · feature/auth", status: .needsAttention, pending: true))
        root.addArrangedSubview(stateView(title: "Claude · feature/auth", status: .done, pending: false))
        return root
    }

    static func managedAgentFixtureEvents(includeApproval: Bool = true) -> [AgentRuntimeEvent] {
        let threadId = "thread-main"
        var events: [AgentRuntimeEvent] = [
            .sessionStateChanged(.running),
            .turnStarted(threadId: threadId, turnId: "turn-1"),
            .contentDelta(threadId: threadId, turnId: "turn-1", streamKind: .assistant, delta: "I'll read the current guard, then refactor it to be idempotent."),
            // P6.0: a third STRUCTURED card. Two message kinds stopped being
            // `TranscriptCardView` in that ticket, which would have taken the border
            // probe's per-appearance floor of 3 down to 2 — the honest fix is to give
            // the probe something to measure, never to lower the floor. Completed,
            // not in-progress, so `activeToolCount` stays the 1 the Lab asserts.
            .itemStarted(threadId: threadId, itemId: "plan-1", kind: .plan, title: "3 steps"),
            .itemCompleted(threadId: threadId, itemId: "plan-1", kind: .plan, status: .completed),
            .itemStarted(threadId: threadId, itemId: "cmd-1", kind: .commandExecution, title: "swift test"),
            .itemCompleted(threadId: threadId, itemId: "cmd-1", kind: .commandExecution, status: .completed),
            .itemStarted(threadId: threadId, itemId: "file-1", kind: .fileChange, title: "Sources/Auth.swift")
        ]
        if includeApproval {
            events.append(.requestOpened(threadId: threadId, requestId: "approval-1", kind: .commandExecutionApproval))
        }
        return events
    }

    static func makeManagedAgentFixtureView(
        includeApproval: Bool = true
    ) -> ManagedAgentTileNSView {
        let tile = Tile(
            id: UUID(uuidString: "71000000-0000-4000-8000-000000000071")!,
            kind: .managedAgent,
            title: "Claude - feature/login",
            frame: TileFrame(x: 0, y: 0, width: 560, height: 560),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        )
        let view = ManagedAgentTileNSView(tile: tile)
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 560)
        // Size the subtree BEFORE ingesting, as production does (a tile is
        // installed and laid out before its first event): a document applied
        // into a zero-sized collection view materializes no item hosts, and an
        // offscreen render never runs the live display pass that would recover
        // them (P5.5 removal finding).
        view.layoutSubtreeIfNeeded()
        // P2C.4: an isolated agent ON the branch it was given — the ordinary case.
        // The fixture carries it so `--ui-geometry-check` exercises the header with
        // a chip in it at the 320pt tile minimum, where a header that cannot fit one
        // would clip. The mismatch variant is the branch-chip card's job.
        view.applyBranchContext(AgentRowContext(
            agentKind: .managed,
            worktreeBranch: "agent/implementer-fix-login-1a2b3c4d",
            checkedOutBranch: "agent/implementer-fix-login-1a2b3c4d"
        ))
        for event in managedAgentFixtureEvents(includeApproval: includeApproval) {
            view.ingest(event)
        }
        // P6.0: a real user turn, so every probe over this fixture sees BOTH prose
        // presentations — the assistant's, which paints nothing, and yours, whose
        // `SurfaceToken.cardUserMessage` fill is the only thing distinguishing them.
        // A fixture with no user turn would leave that fill unrendered and unprobed.
        view.appendUserPrompt("Also check the token refresh path while you're in there.")
        return view
    }

}

// MARK: - Panel

/// Two-pane lab window: entry list · live render on a flat dark backdrop.
@MainActor
final class ComponentLabPanel: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let rootAccessibilityIdentifier = "ContinuumComponentLabRoot"

    var onClose: (() -> Void)?

    private let env: LabEnvironment
    private var panel: NSPanel?
    private var outline: NSOutlineView?
    private var hostView: NSView?
    private var previousKeyWindow: NSWindow?

    private var categories: [String] = []
    private var entriesByCategory: [String: [LabEntry]] = [:]
    private var selectedEntry: LabEntry?
    private var teardown: [() -> Void] = []
    private var currentLauncher: ((NSWindow) -> AnyObject?)?
    private var launchedRetained: [AnyObject] = []

    init(env: LabEnvironment) {
        self.env = env
        super.init()
        rebuildCatalog()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func rebuildCatalog() {
        var order: [String] = []
        var grouped: [String: [LabEntry]] = [:]
        for entry in LabCatalog.entries(env: env) {
            if grouped[entry.category] == nil { order.append(entry.category) }
            grouped[entry.category, default: []].append(entry)
        }
        categories = order
        entriesByCategory = grouped
    }

    func show(near host: NSWindow?) {
        let panel = ensurePanel()
        previousKeyWindow = host ?? NSApp.keyWindow
        if let host, host.screen != nil {
            let hostFrame = host.frame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: hostFrame.midX - size.width / 2, y: hostFrame.midY - size.height / 2))
        } else {
            panel.center()
        }
        if selectedEntry == nil, let first = entriesByCategory[categories.first ?? ""]?.first {
            selectEntry(first)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        clearCurrentContent()
        launchedRetained.removeAll()  // releases any launched settings/palette panels
        panel?.orderOut(nil)
        let restoreTarget = previousKeyWindow
        outline?.dataSource = nil
        outline?.delegate = nil
        panel = nil
        outline = nil
        hostView = nil
        selectedEntry = nil
        previousKeyWindow = nil
        restoreTarget?.makeKeyAndOrderFront(nil)
        onClose?()
    }

    // MARK: Construction

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.appearance = NSApp?.effectiveAppearance
        panel.title = "Component Lab"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = nil

        let root = NSView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 960, height: 640))
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityIdentifier(Self.rootAccessibilityIdentifier)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.appResolvedCGColor
        panel.contentView = root

        let navWidth: CGFloat = 240
        let outlineScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: navWidth, height: root.bounds.height))
        outlineScroll.autoresizingMask = [.height]
        outlineScroll.hasVerticalScroller = true
        outlineScroll.drawsBackground = false
        outlineScroll.borderType = .noBorder
        let outline = NSOutlineView(frame: outlineScroll.bounds)
        outline.headerView = nil
        outline.rowHeight = 26
        outline.indentationPerLevel = 12
        outline.backgroundColor = .clear
        outline.autoresizesOutlineColumn = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.width = navWidth - 4
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        outlineScroll.documentView = outline
        root.addSubview(outlineScroll)
        self.outline = outline

        // Flat dark host — the app's canvas context, not a distracting pattern.
        let host = NSView(frame: NSRect(x: navWidth, y: 0, width: root.bounds.width - navWidth, height: root.bounds.height))
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        host.setAccessibilityIdentifier("ContinuumComponentLabHost")
        root.addSubview(host)
        self.hostView = host

        self.panel = panel
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        return panel
    }

    // MARK: Selection + rendering

    private func selectEntry(_ entry: LabEntry) {
        selectedEntry = entry
        guard let host = hostView else { return }
        clearCurrentContent()
        switch entry.content {
        case let .staticCard(preferredSize, make):
            Self.place(make(), in: host, preferredSize: preferredSize)
        case let .reviewSurface(preferredSize, make):
            Self.place(make(), in: host, preferredSize: preferredSize)
        case let .canvasSandbox(configure):
            let sandbox = LabSandboxContext(env: env)
            configure(sandbox)
            teardown.append { sandbox.teardownAll() }
            Self.place(sandbox.containerView, in: host, preferredSize: nil)
        case let .launcher(buttonTitle, present):
            currentLauncher = present
            let pane = Self.makeLauncherPane(title: entry.title, summary: entry.summary, buttonTitle: buttonTitle, target: self, action: #selector(launcherButtonClicked))
            pane.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                pane.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                pane.widthAnchor.constraint(lessThanOrEqualToConstant: 400)
            ])
        }
    }

    /// Launcher pane: title + summary + a prominent accent button. Explicit
    /// light colours + an accent bezel with white title so it stays legible on
    /// the dark host regardless of the system appearance.
    static func makeLauncherPane(title: String, summary: String, buttonTitle: String, target: AnyObject?, action: Selector?) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.95, alpha: 1)
        titleLabel.alignment = .center

        let summaryLabel = NSTextField(wrappingLabelWithString: summary)
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = NSColor(white: 0.6, alpha: 1)
        summaryLabel.alignment = .center
        summaryLabel.preferredMaxLayoutWidth = 360

        let button = NSButton(title: buttonTitle, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.bezelColor = .controlAccentColor
        button.attributedTitle = NSAttributedString(string: buttonTitle, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ])

        let stack = NSStackView(views: [titleLabel, summaryLabel, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: summaryLabel)
        return stack
    }

    @objc private func launcherButtonClicked() {
        guard let present = currentLauncher, let window = panel else { return }
        if let retained = present(window) { launchedRetained.append(retained) }
    }

    private func clearCurrentContent() {
        teardown.forEach { $0() }
        teardown.removeAll()
        currentLauncher = nil
        hostView?.subviews.forEach { $0.removeFromSuperview() }
    }

    /// Fixed-size content is centered; otherwise it's pinned to fill (insets).
    static func place(_ view: NSView, in host: NSView, preferredSize: NSSize?) {
        host.addSubview(view)
        if let size = preferredSize {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.frame = NSRect(
                x: floor((host.bounds.width - size.width) / 2),
                y: floor((host.bounds.height - size.height) / 2),
                width: size.width,
                height: size.height
            )
            view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        } else {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
                view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
                view.topAnchor.constraint(equalTo: host.topAnchor, constant: 24),
                view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -24)
            ])
        }
    }

    // MARK: NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return categories.count }
        if let category = item as? String { return entriesByCategory[category]?.count ?? 0 }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return categories[index] }
        return entriesByCategory[item as! String]![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is String
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
            return field
        }()
        if let category = item as? String {
            cell.stringValue = category.uppercased()
            cell.font = .systemFont(ofSize: 10, weight: .semibold)
            cell.textColor = .tertiaryLabelColor
        } else if let entry = item as? LabEntry {
            cell.stringValue = entry.title
            cell.font = .systemFont(ofSize: 12)
            cell.textColor = .labelColor
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is LabEntry
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outline, let entry = outline.item(atRow: outline.selectedRow) as? LabEntry else { return }
        selectEntry(entry)
    }

    // MARK: Self-check

    func qaEntries() -> [LabEntry] { categories.flatMap { entriesByCategory[$0] ?? [] } }

    // MARK: - Static-card gates (P0.7)

    /// Every static card, in both appearances, held to the phase-0 gates: the
    /// blankness floor, the generic geometry invariants, WCAG contrast over the real
    /// view tree, the pixel-flatness probes, and its committed PNG baseline.
    ///
    /// Why this exists: until P0.7 the entire per-card visual gate here was
    /// `VisualSnapshot.isBlank` plus a handful of hand-picked
    /// `distinctSampledColors` thresholds — "the image has more than one colour",
    /// which black-on-dark text, a half-width transcript and an empty card all pass.
    /// Blankness is kept as a floor (a genuinely blank render is still worth naming
    /// cheaply and in the right vocabulary), but it is no longer the gate.
    ///
    /// The four hand-picked colour-count assertions it replaced (sidebar vs
    /// sidebar-selected must differ; approval dock >= 6 colours; user-input card
    /// >= 5; managed-agent >= 3) are gone rather than kept, because the baseline
    /// comparison strictly subsumes each of them: it holds every one of those cards
    /// to its whole committed render, in both appearances, so any change that could
    /// have moved a sampled colour count is red with the pixels to prove it. This is
    /// the one ticket allowed to remove assertions, and only on that ground.
    ///
    /// Each card is rendered ONCE per appearance and all five gates read that one
    /// render, so the leg costs one extra render pass over the catalogue rather than
    /// four. The gates themselves are the same code the dedicated legs run
    /// (`UIProbeGeometry`, `UIProbeContrast.evaluate`, `UIProbePixels.sweep`,
    /// `UIProbeBaseline.mismatch`) — not a second implementation that could drift.
    ///
    /// The render itself replaces the old hand-rolled one, which built its own
    /// borderless window over an opaque dark backdrop (the docs/26 Tier-1 setup) and
    /// so could only ever render one appearance. `UIProbe.render` is the same
    /// substrate the four dedicated legs use, at a declared scale, in a real
    /// appearance.
    ///
    /// What stays in the dedicated legs, deliberately:
    /// - the managed-agent tile's width-fill ratios, scrolled-to-bottom and
    ///   approval-dock slack assertions are about one surface at three widths, so they
    ///   are not per-entry gates and `--ui-geometry-check` keeps them
    /// - `UIProbeGeometry.expectNoAmbiguousLayout`, which is NOT a generic invariant
    ///   and says so at its own definition: `hasAmbiguousLayout` is true for every
    ///   flexible `NSStackView` child AppKit positions with its priority-260 align
    ///   constraint, all of which lay out correctly, so widening it to a subtree walk
    ///   over 23 cards would force weakening the assertion. It stays absolute over the
    ///   transcript column, which is the chain the shipped bug lived in.
    ///
    /// Witnesses observed red with this code, `--component-lab-check` exit 1 each time
    /// — one per gate, and the third is the one that earns the removal above:
    /// - baseline / the packet's own witness — removing `agent.kind`'s width pin
    ///   (`view.widthAnchor.constraint(equalToConstant: 520)`):
    ///   `2 baseline(s) did not match: managed-agent.approval-dock-560x720-aqua.png:
    ///   16175 of 403200 pixels differ (4.0117%, worst channel delta 255)` (+darkAqua),
    ///   `44 other render(s) matched`
    /// - baseline / SUBSUMPTION of the deleted sidebar-selection delta — dropping the
    ///   `view.select(...)` call from the `chrome.sidebar.selected` fixture, i.e. the
    ///   exact regression that assertion existed to catch:
    ///   `chrome.sidebar.selected-280x560-aqua.png: 16007 of 156800 pixels differ
    ///   (10.2085%, worst channel delta 38)` and the same in darkAqua. The retired
    ///   assertion compared two colour COUNTS; this reports 10% of the pixels, per
    ///   appearance, with a diff image.
    /// - geometry — that width pin set to 900 instead of 520:
    ///   `managed-agent.approval-dock.NSAppearanceNameAqua: NSStackView/
    ///   ManagedAgentTileNSView holds a broken required constraint — measured 560.0,
    ///   needs == 900.0`
    /// - contrast — `LabCatalog.mutedLabelColor` back off the token onto a light grey:
    ///   `7 unreadable pair(s) of 452 measured: approvalsInbox.scope
    ///   [NSAppearanceNameAqua · text]: 1.61:1, needs >= 4.5:1`
    /// - pixel-sweep coverage, both floors, per appearance — the text and border
    ///   branches of `UIProbePixels.sweep` made unreachable, standing in for the walk
    ///   or the eligibility filters silently stopping to find anything:
    ///   `static-card pixel sweep probed only 0 text rect(s) in NSAppearanceNameAqua,
    ///   needs >= 192` and `only 0 border(s) ... needs >= 12`
    /// - blankness floor (still fires, still first) — the sidebar fixture's subviews
    ///   hidden: `chrome.sidebar.selected.NSAppearanceNameAqua: render is
    ///   blank/uniform (1 colors at 560x1120)`
    /// - render count / "the check count did not shrink" — one card excluded from the
    ///   gated set: `only 44 static card/appearance render(s) gated, needs >= 46`
    private static func runStaticCardGates(
        entries: [LabEntry], artifactDirectory directory: URL, fail: (String) -> Error
    ) throws -> [[String: Any]] {
        // Production pins the app appearance at launch (`ContinuumApp`); pin it here
        // too so the `.aqua` pass can only be honest if the probe really moves it.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // A bless run writes the baselines in `--ui-baseline-check`, which runs AFTER
        // this leg. Comparing here would fail the matrix before the blessing could
        // happen, so the comparison stands down — and says so — while the other four
        // gates still run.
        //
        // Not an environment-dependent hole: under `CONTINUUM_UPDATE_BASELINES=1`
        // NOTHING compares against a baseline anywhere in the matrix — that flag's
        // whole meaning is "the committed bytes are the ones being replaced", and
        // `--ui-baseline-check` writes rather than compares in exactly the same way.
        // Blessing is a human action followed by a normal run, and it is the normal run
        // that re-establishes the gate. The one thing this must not do is write the
        // baselines itself: two writers of the same 46 files is how they drift.
        let blessing = UIProbeBaseline.isUpdating

        var rendered: [[String: Any]] = []
        var baselineFailures: [String] = []
        var contrast = UIProbeContrast.Evaluation()
        var pixels = UIProbePixels.Sweep()
        // Per appearance as well as in total: an aggregate floor is satisfied by one
        // appearance carrying the whole run while the other silently probes nothing —
        // the trap P0.5 already hit and recorded in `UIProbePixels.runPixelChecks`.
        var pixelsByAppearance: [NSAppearance.Name: UIProbePixels.Sweep] = [:]
        var comparedBaselines = 0
        var gated = 0

        for entry in entries {
            guard case let .staticCard(preferredSize, make) = entry.content else { continue }
            let size = preferredSize ?? UIProbeBaseline.defaultCardSize
            for appearanceName in UIProbeBaseline.appearances {
                // The probe id stays `entry.id`, matching `--ui-contrast-check`, so a
                // measurement key means the same thing in both legs (and an exemption,
                // if one is ever granted, cannot be keyed to only one of them). The
                // appearance travels in `label`, which is what names failures and
                // artifact files.
                let label = "\(entry.id).\(appearanceName.rawValue)"
                let probe = try UIProbe.render(
                    UIProbe.Spec(id: entry.id, size: size, appearance: appearanceName), make: make
                )
                let metrics = VisualSnapshot.metrics(of: probe.hostRep)
                try probe.hostRep.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("\(label).png"))

                // Floor, not gate: a blank render makes every measurement below flat
                // for one reason, so say that once instead of reporting it four times.
                guard !metrics.isBlank else {
                    throw fail("\(label): render is blank/uniform (\(metrics.distinctSampledColors) colors at \(metrics.width)x\(metrics.height))")
                }

                try UIProbeGeometry.expectNoZeroSizeViews(probe.view, label: label)
                try UIProbeGeometry.expectNoClipping(probe.view, label: label)
                try UIProbeGeometry.expectNoBrokenRequiredSizeConstraints(probe.view, label: label)

                contrast.merge(try UIProbeContrast.evaluate(probe))
                let cardSweep = try UIProbePixels.sweep(probe, label: label)
                pixels.merge(cardSweep)
                pixelsByAppearance[appearanceName, default: UIProbePixels.Sweep()].merge(cardSweep)

                if !blessing {
                    let name = UIProbeBaseline.baselineName(id: entry.id, size: size, appearance: appearanceName)
                    let (failure, _) = try UIProbeBaseline.mismatch(of: probe, name: name, size: size)
                    if let failure { baselineFailures.append(failure) } else { comparedBaselines += 1 }
                }

                rendered.append([
                    "entry": entry.id, "appearance": appearanceName.rawValue,
                    "width": metrics.width, "height": metrics.height,
                    "distinctColors": metrics.distinctSampledColors
                ])
                gated += 1
            }
        }

        // Coverage floors, aggregated per appearance rather than per card: a card may
        // legitimately paint no border and no text, so a per-card floor would be
        // wrong, but a run where the eligibility filters or the tree walk stop finding
        // anything passes every gate above vacuously. Numbers are MEASURED on this
        // catalogue: 46 renders (23 static cards x 2 appearances), 240 text rects and
        // 15 borders per appearance.
        //
        // The render count is floored AT the measured number, not under it: P0.7's own
        // verification is "confirm the check count did not shrink", and a floor of 40
        // would let six card/appearance renders disappear green. The two sweep floors
        // keep a margin (80%) because their eligibility filters are layout-sensitive —
        // a clipped or mostly-transparent view drops out legitimately — which is the
        // same reasoning and the same shape as P0.5's per-appearance floors. Growth
        // passes in all three cases (P0.11's convention); only shrinkage is the signal.
        // 48 since P2C.4 added `managed-agent.branch-chip` (24 static cards x 2).
        // 52 since P3.6 added `chrome.agentInbox` and `chrome.agentInbox.selected`
        // (26 static cards x 2).
        // 54 since P3.7 added `chrome.agentInbox.parked` (27 static cards x 2).
        // 56 since P3.10 added `chrome.agentInbox.jumpHints` (28 static cards x 2).
        // 58 since P3.11 added `chrome.agentInbox.bulk` (29 static cards x 2).
        // 60 since P4.7 added `chrome.agentInbox.shelf` (30 static cards x 2).
        let minimumCardsGated = 60
        let minimumTextRectsPerAppearance = 192
        let minimumBordersPerAppearance = 12
        guard gated >= minimumCardsGated else {
            throw fail("only \(gated) static card/appearance render(s) gated, needs >= \(minimumCardsGated)")
        }
        for appearanceName in UIProbeBaseline.appearances {
            let sweep = pixelsByAppearance[appearanceName] ?? UIProbePixels.Sweep()
            guard sweep.textProbes >= minimumTextRectsPerAppearance else {
                throw fail("static-card pixel sweep probed only \(sweep.textProbes) text rect(s) in \(appearanceName.rawValue), needs >= \(minimumTextRectsPerAppearance)")
            }
            guard sweep.borderProbes >= minimumBordersPerAppearance else {
                throw fail("static-card pixel sweep probed only \(sweep.borderProbes) border(s) in \(appearanceName.rawValue), needs >= \(minimumBordersPerAppearance)")
            }
        }
        guard contrast.measured > 0 else { throw fail("static-card contrast gate measured no pairs") }
        guard contrast.failures.isEmpty else {
            throw fail(
                "\(contrast.failures.count) unreadable pair(s) of \(contrast.measured) measured:\n  - "
                    + contrast.failures.joined(separator: "\n  - ")
            )
        }
        guard baselineFailures.isEmpty else {
            throw fail(
                "\(baselineFailures.count) baseline(s) did not match:\n  - "
                    + baselineFailures.joined(separator: "\n  - ")
                    + "\n\(comparedBaselines) other render(s) matched. If these changes are intended, bless them: "
                    + "\(UIProbeBaseline.updateEnvironmentKey)=1 ./scripts/run-matrix.sh — and review the baseline diff before committing."
            )
        }
        guard NSApp.appearance?.name == .darkAqua else {
            throw fail("probing mutated NSApp.appearance to '\(NSApp.appearance?.name.rawValue ?? "nil")'")
        }

        let coverage = UIProbeBaseline.appearances.map { name -> String in
            let sweep = pixelsByAppearance[name] ?? UIProbePixels.Sweep()
            return "\(name.rawValue) \(sweep.textProbes) text/\(sweep.borderProbes) borders"
        }.joined(separator: ", ")
        print(String(
            format: "ComponentLab: %d static card/appearance renders gated — geometry (no zero-size, no clipping, no broken required size), "
                + "%d contrast pair(s) (worst text %.2f:1 %@), %d text rect(s) + %d border(s) probed [%@, floors %d/%d] "
                + "(worst spread %.3f, worst border delta %.3f), %@; blankness is a floor, not the gate",
            gated, contrast.measured,
            contrast.worstText.ratio, contrast.worstText.key.isEmpty ? "none" : contrast.worstText.key,
            pixels.textProbes, pixels.borderProbes, coverage,
            minimumTextRectsPerAppearance, minimumBordersPerAppearance,
            pixels.worstText.spread, pixels.worstBorder.delta,
            blessing
                ? "baseline comparison stood down for \(UIProbeBaseline.updateEnvironmentKey)=1 (--ui-baseline-check writes them)"
                : "\(comparedBaselines) committed baseline(s) matched"
        ))
        return rendered
    }

    /// Isolated P3.8 fixture/check: it exercises production registry hosts but
    /// does not enter the baseline catalogue before the supervised P3.12 review.
    private static func runPlanAndDiffRendererCheck(fail: (String) -> Error) throws {
        func id(_ value: String) -> AgentNodeID { AgentNodeID(rawValue: value)! }
        func visibleStrings(in view: NSView) -> [String] {
            let own: [String]
            if let field = view as? NSTextField { own = [field.stringValue] }
            else if let button = view as? NSButton { own = [button.title, button.toolTip ?? ""] }
            else if let text = view as? NSTextView { own = [text.string] }
            else { own = [] }
            return own + view.subviews.flatMap(visibleStrings)
        }

        guard try AgentBlockRendererRegistry.production.renderer(for: .plan) is PlanRenderer,
              try AgentBlockRendererRegistry.production.renderer(for: .diff) is DiffSummaryRenderer else {
            throw fail("plan/diff fixtures did not resolve to distinct production renderers")
        }

        var actions: [AgentRenderAction] = []
        let context = AgentRenderContext(
            actions: AgentRenderActions { actions.append($0) },
            tokens: .transcript,
            appearance: .dark
        )
        let completedDetail = "COMPLETED-DETAIL-MUST-BE-COLLAPSED"
        let plan = AgentBlock(
            id: id("lab-plan"), revision: 1, kind: .plan,
            payload: .plan(.init(
                title: "Ship semantic transcript",
                status: .inProgress,
                steps: [
                    .init(
                        title: "Build semantic schema",
                        detail: completedDetail,
                        status: .completed,
                        children: [.init(title: "Preserve stable IDs", detail: "Reducer checks are running.", status: .inProgress)]
                    ),
                    .init(title: "Review visual hierarchy", detail: "Waiting for the supervised gate.", status: .pending),
                ]
            ))
        )
        let planHost = AgentBlockHostView()
        let planHeight = try planHost.measuredHeight(for: plan, width: 360, context: context)
        planHost.frame = NSRect(x: 0, y: 0, width: 360, height: planHeight)
        try planHost.apply(block: plan, context: context)
        planHost.layoutSubtreeIfNeeded()
        guard let planView = planHost.rendererView as? AgentPlanView,
              planView.accessibilityRole() == .list,
              planView.rows.map(\.ordinal) == ["1", "1.1", "2"],
              planView.rowViews.count == 3,
              planView.rowViews[0].subviews.count == 1,
              planView.rowViews[1].subviews.count == 2,
              !visibleStrings(in: planView).contains(completedDetail),
              planView.rowViews.allSatisfy({ $0.frame.maxY <= planView.bounds.maxY + 0.5 }) else {
            throw fail("plan fixture lost ordinal hierarchy, passive status detail, accessibility role, or bounds")
        }

        let rawDiff = "RAW-DIFF-MUST-NEVER-RENDER\n@@ -1 +1 @@\n-secret\n+token"
        let diffID = id("lab-diff")
        let diff = AgentBlock(
            id: diffID, revision: 1, kind: .diff,
            payload: .diff(.init(
                text: rawDiff,
                language: "diff",
                summary: "Updated transcript presentation",
                files: [
                    .init(displayName: "PlanRenderer.swift", addedLineCount: 42, removedLineCount: 3),
                    .init(displayName: "DiffSummaryRenderer.swift", addedLineCount: 31, removedLineCount: 1),
                ],
                canOpenReview: true
            ))
        )
        let diffHost = AgentBlockHostView()
        let diffHeight = try diffHost.measuredHeight(for: diff, width: 360, context: context)
        diffHost.frame = NSRect(x: 0, y: 0, width: 360, height: diffHeight)
        try diffHost.apply(block: diff, context: context)
        diffHost.layoutSubtreeIfNeeded()
        guard let diffView = diffHost.rendererView as? AgentDiffSummaryView,
              diffView.accessibilityRole() == .group,
              diffView.countsLabel.stringValue == "2 files · +73 −4",
              diffView.fileLabels.count == 2,
              !diffView.openReviewButton.isHidden,
              !visibleStrings(in: diffView).contains(where: { $0.contains(rawDiff) }),
              diffView.fileLabels.allSatisfy({ $0.frame.maxY <= diffView.bounds.maxY + 0.5 }) else {
            throw fail("diff fixture parsed raw text or lost safe names, supplied counts, role, action, or bounds")
        }
        diffView.openReviewButton.performClick(nil)
        guard actions.count == 1,
              case .openDiff(blockID: diffID) = actions[0] else {
            throw fail("diff review button did not emit the semantic block-scoped action")
        }

        let noReview = AgentBlock(
            id: diffID, revision: 2, kind: .diff,
            payload: .diff(.init(text: rawDiff, summary: "No review route", files: [], canOpenReview: false))
        )
        try diffHost.apply(block: noReview, context: context)
        diffView.openReviewButton.performClick(nil)
        guard diffView.openReviewButton.isHidden, actions.count == 1 else {
            throw fail("unavailable diff review action remained interactive after host reuse")
        }

        let decoder = JSONDecoder()
        let legacyPlan = try decoder.decode(
            AgentPlanPayload.self,
            from: Data(#"{"title":"Legacy","status":"pending"}"#.utf8)
        )
        let legacyDiff = try decoder.decode(
            AgentDiffPayload.self,
            from: Data(#"{"text":"legacy","language":"diff"}"#.utf8)
        )
        guard legacyPlan.steps.isEmpty, legacyDiff.files.isEmpty,
              legacyDiff.summary == nil, !legacyDiff.canOpenReview else {
            throw fail("plan/diff semantic schema did not preserve legacy decoding defaults")
        }
    }

    private static func runTranscriptReviewCheck(fail: (String) -> Error) throws {
        func descendants(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let expectedMinimumRows: [AgentTranscriptReviewState: Int] = [
            .mixed: 10, .long: 28, .activeTool: 4, .failedTool: 5, .approval: 3,
        ]
        for state in AgentTranscriptReviewState.allCases {
            let size = NSSize(width: state == .long ? 320 : 480, height: 720)
            let surface = LabCatalog.makeTranscriptReviewSurface(state: state, size: size, theme: .dark)
            let host = NSView(frame: surface.frame)
            host.addSubview(surface)
            surface.needsLayout = true
            surface.layout()
            surface.transcript.layout()
            surface.transcript.collectionView.layout()
            host.layoutSubtreeIfNeeded()
            surface.layoutSubtreeIfNeeded()
            surface.transcript.layoutSubtreeIfNeeded()
            surface.transcript.collectionView.layoutSubtreeIfNeeded()
            let views = descendants(in: surface)
            let hasSelectableText = views.contains {
                ($0 as? NSTextView)?.isSelectable == true || ($0 as? NSTextField)?.isSelectable == true
            }
            let virtualizationHolds = state != .long
                || surface.transcript.qaLiveHostCount < surface.transcript.qaSemanticRowCount
            guard surface.renderError == nil,
                  surface.transcript.qaSemanticRowCount >= expectedMinimumRows[state, default: .max],
                  surface.transcript.qaLiveHostCount > 0,
                  virtualizationHolds,
                  hasSelectableText,
                  !views.contains(where: { $0 is NSPopUpButton }) else {
                throw fail(
                    "semantic transcript \(state.rawValue) failed review fixture: rows "
                        + "\(surface.transcript.qaSemanticRowCount), live \(surface.transcript.qaLiveHostCount), "
                        + "selectable \(hasSelectableText), error \(String(describing: surface.renderError))"
                )
            }
            switch state {
            case .mixed:
                guard let plan = views.compactMap({ $0 as? AgentPlanView }).first,
                      plan.statusLabel.frame.width >= plan.statusLabel.intrinsicContentSize.width,
                      plan.rowViews.count >= 2,
                      plan.rowViews[1].subviews.count == 2,
                      plan.rowViews[1].subviews[1].frame.minY >= plan.rowViews[1].subviews[0].frame.maxY,
                      let diff = views.compactMap({ $0 as? AgentDiffSummaryView }).first,
                      diff.countsLabel.frame.width >= diff.countsLabel.intrinsicContentSize.width,
                      diff.summaryLabel.lineBreakMode == .byWordWrapping else {
                    throw fail("mixed transcript review state clipped status text or detached plan/diff detail order")
                }
            case .long:
                guard surface.transcript.collectionView.frame.height > surface.transcript.scrollView.contentView.bounds.height else {
                    throw fail("long transcript review fixture does not overflow its viewport")
                }
            case .activeTool:
                guard let tool = views.compactMap({ $0 as? ToolCallView }).first,
                      let output = views.compactMap({ $0 as? CommandOutputView }).first,
                      tool.summaryLabel.lineBreakMode == .byWordWrapping,
                      tool.statusLabel.frame.width >= tool.statusLabel.intrinsicContentSize.width,
                      output.statusLabel.frame.width >= output.statusLabel.intrinsicContentSize.width else {
                    throw fail("active-tool transcript review state clipped status or multiline structured work")
                }
            case .failedTool:
                guard let tool = views.compactMap({ $0 as? ToolCallView }).first,
                      let error = views.compactMap({ $0 as? AgentErrorNoticeView }).first,
                      tool.summaryLabel.lineBreakMode == .byWordWrapping,
                      error.messageLabel.lineBreakMode == .byWordWrapping,
                      error.statusLabel.frame.width >= error.statusLabel.intrinsicContentSize.width else {
                    throw fail("failed-tool transcript review state clipped failure hierarchy")
                }
            case .approval:
                guard let request = views.compactMap({ $0 as? AgentRequestView }).first,
                      request.promptLabel.lineBreakMode == .byWordWrapping,
                      request.promptLabel.stringValue.contains("writes commits to the remote repository"),
                      request.statusLabel.frame.width >= request.statusLabel.intrinsicContentSize.width,
                      request.choiceButtons.map(\.title) == ["Allow once", "Decline"],
                      request.choiceButtons.allSatisfy({
                          !$0.isBordered
                              && $0.accessibilityRole() == .button
                              && $0.layer?.backgroundColor != nil
                              && $0.layer?.cornerRadius == CGFloat(Radius.card)
                              && $0.layer?.masksToBounds == false
                      }) else {
                    throw fail("approval transcript review state lost its explicit contextual custom request controls")
                }
            }
        }
    }

    static func runSelfCheck() throws {
        func fail(_ message: String) -> Error {
            NSError(domain: "ComponentLab", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        _ = NSApplication.shared
        try runPlanAndDiffRendererCheck(fail: fail)
        try runTranscriptReviewCheck(fail: fail)

        let panel = ComponentLabPanel(env: LabEnvironment(ghostty: nil, browserEngine: nil))
        panel.show(near: nil)
        let entries = panel.qaEntries()
        panel.close()
        guard !entries.isEmpty else { throw fail("component lab catalog is empty") }
        // Launcher entries are launch-only (they open real panels needing a run
        // loop), so just assert they're catalogued.
        for id in ["panel.palette", "panel.settings", "panel.projectPicker"] {
            guard entries.contains(where: { $0.id == id }) else { throw fail("missing launcher entry \(id)") }
        }
        guard let transcriptEntry = entries.first(where: { $0.id == "agent.transcript.review" }),
              case .reviewSurface = transcriptEntry.content else {
            throw fail("missing supervised semantic transcript review surface")
        }
        guard let composerEntry = entries.first(where: { $0.id == "agent.composer.review" }),
              case let .reviewSurface(composerSize, makeComposerView) = composerEntry.content,
              let composer = makeComposerView() as? AgentComposerView else {
            throw fail("missing isolated custom composer review surface")
        }
        composer.frame = NSRect(origin: .zero, size: composerSize)
        let composerHost = NSView(frame: composer.frame)
        composerHost.addSubview(composer)
        composerHost.layoutSubtreeIfNeeded()
        composer.layoutSubtreeIfNeeded()
        func descendants(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let composerDescendants = descendants(in: composer)
        guard composer.scrollView.borderType == .noBorder,
              !composer.scrollView.drawsBackground,
              composer.textView.isEditable,
              composer.textView.isSelectable,
              composer.textView.allowsUndo,
              composer.textView.accessibilityRole() == .textArea,
              composer.textView.frame.width > 0,
              composer.textView.frame.height > 0,
              !composerDescendants.contains(where: { $0 is NSPopUpButton }),
              !composerDescendants.compactMap({ $0 as? NSTextField }).contains(where: { $0.isBezeled }) else {
            throw fail("isolated composer review surface lost native editing, document geometry, or custom-only chrome")
        }
        guard let footerEntry = entries.first(where: { $0.id == "agent.composer.provider-controls" }),
              case let .reviewSurface(footerSize, makeFooterView) = footerEntry.content,
              let footer = makeFooterView() as? AgentComposerFooterView else {
            throw fail("missing custom composer model/effort review surface")
        }
        // Label variants are a MEASURED fit since the P5.5 corrections: 260 pt
        // cannot hold this catalogue's full titles (compact expected below), and
        // 640 pt must restore them. The review surface keeps its own size.
        footer.frame = NSRect(x: 0, y: 0, width: 260, height: footerSize.height)
        footer.layoutSubtreeIfNeeded()
        let footerDescendants = descendants(in: footer)
        guard !footerDescendants.contains(where: { $0 is NSPopUpButton }),
              footer.modelButton.accessibilityRole() == .popUpButton,
              footer.effortButton.accessibilityRole() == .popUpButton,
              footer.modelButton.accessibilityLabel() == "Model, next turn",
              footer.effortButton.accessibilityLabel() == "Reasoning effort, next turn",
              footer.qaModelTitles == AgentModelConfig.modelOptions.map(AgentComposerFooterView.abbreviatedModel),
              footer.qaEffortTitles == AgentModelConfig.thinkingOptions.map(AgentComposerFooterView.abbreviatedEffort),
              Set(footer.qaModelTitles).count == AgentModelConfig.modelOptions.count else {
            throw fail("composer provider footer lost custom-only chrome, next-turn accessibility, or unambiguous narrow labels")
        }
        footer.frame.size.width = 640
        footer.layoutSubtreeIfNeeded()
        guard footer.qaModelTitles == AgentModelConfig.modelOptions,
              footer.qaEffortTitles == AgentModelConfig.thinkingOptions.map(\.capitalized),
              footer.bounds.contains(footer.modelButton.frame),
              footer.bounds.contains(footer.effortButton.frame),
              footer.modelButton.frame.width > footer.effortButton.frame.width else {
            throw fail("composer provider footer did not restore full labels or keep both controls inside its wide layout")
        }

        // Render-state gate for the COMPOSED footer, not ChoiceButton in isolation.
        // Mouse tracking, first-responder focus, and the real mouse-down/open path
        // must all repaint the installed model control coherently.
        let stateWindow = NSWindow(contentRect: footer.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        stateWindow.contentView = footer
        stateWindow.makeKeyAndOrderFront(nil)
        footer.layoutSubtreeIfNeeded()
        guard let restingFill = footer.modelButton.layer?.backgroundColor else {
            throw fail("composer provider footer has no resting fill")
        }
        let pointerEvent = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: stateWindow.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: 1
        )!
        footer.modelButton.mouseEntered(with: pointerEvent)
        guard let hoverFill = footer.modelButton.layer?.backgroundColor,
              hoverFill.components != restingFill.components else {
            throw fail("composer provider footer hover did not repaint its quiet fill")
        }
        footer.modelButton.mouseExited(with: pointerEvent)
        // Owner corrections (P4.10): idle is a quiet fill with no outline; keyboard
        // focus and the open state paint a ≤0.5 pt accent line plus an accent glow
        // instead of a thick permanent border.
        guard footer.modelButton.layer?.borderWidth == 0,
              footer.modelButton.layer?.shadowOpacity == 0 else {
            throw fail("composer provider footer idle control regained an outline or glow")
        }
        stateWindow.makeFirstResponder(footer.modelButton)
        guard let focusBorder = footer.modelButton.layer?.borderWidth,
              focusBorder > 0, focusBorder <= 0.5,
              let focusGlow = footer.modelButton.layer?.shadowOpacity, focusGlow > 0 else {
            throw fail("composer provider footer focus did not paint the accent line and glow focus cue")
        }
        stateWindow.makeFirstResponder(nil)
        let pressedAlpha = footer.qaPressModel(with: pointerEvent)
        guard pressedAlpha.contains(where: { abs($0 - 0.78) < 0.001 }),
              stateWindow.childWindows?.isEmpty == false,
              let openBorder = footer.modelButton.layer?.borderWidth,
              openBorder > 0, openBorder <= 0.5,
              let openGlow = footer.modelButton.layer?.shadowOpacity, openGlow > 0 else {
            throw fail("composer provider footer pressed/open path did not paint pressed alpha and the open focus cue")
        }
        _ = footer.modelButton.accessibilityPerformPress()
        stateWindow.orderOut(nil)

        // P4.10 composer variant review states. The full-turn card keeps the
        // complete command surface; the compact card is the presentation-only
        // freeform shell: 1–4 visual lines, no model/effort controls, reference
        // completion only, and no fabricated response contract.
        guard let fullVariantEntry = entries.first(where: { $0.id == "agent.composer.full-variant" }),
              case let .reviewSurface(fullSize, makeFullVariant) = fullVariantEntry.content,
              let fullSurface = makeFullVariant() as? AgentComposerReviewSurface else {
            throw fail("missing full-turn composer variant review surface")
        }
        fullSurface.frame = NSRect(origin: .zero, size: fullSize)
        fullSurface.layoutSubtreeIfNeeded()
        guard fullSurface.composer.variant == .fullTurn,
              fullSurface.footer != nil,
              fullSurface.actionButton != nil,
              AgentComposerVariant.fullTurn.completionTriggers == AgentCompletionQueryDetector.supportedTriggers else {
            throw fail("full-turn composer variant lost its footer, action, or provider completion triggers")
        }
        guard let compactVariantEntry = entries.first(where: { $0.id == "agent.composer.compact-variant" }),
              case let .reviewSurface(compactSize, makeCompactVariant) = compactVariantEntry.content,
              let compactSurface = makeCompactVariant() as? AgentComposerReviewSurface else {
            throw fail("missing compact composer variant review surface")
        }
        compactSurface.frame = NSRect(origin: .zero, size: compactSize)
        compactSurface.layoutSubtreeIfNeeded()
        guard compactSurface.composer.variant == .compactFreeform,
              compactSurface.footer == nil,
              compactSurface.actionButton == nil,
              AgentComposerVariant.compactFreeform.completionTriggers == ["@", "$"] else {
            throw fail("compact composer shell gained full-turn controls or command completion")
        }
        // The compact shell caps at four visual lines: with a six-line draft its
        // editor height equals a full-turn composer holding exactly four lines,
        // and stays below the same six-line draft in the full-turn composer.
        let compactMeasureWidth = compactSize.width - AgentComposerReviewSurface.contentInset * 2
        func measuredComposerHeight(_ variant: AgentComposerVariant, lines: Int) -> CGFloat {
            let probe = AgentComposerView(
                frame: NSRect(x: 0, y: 0, width: compactMeasureWidth, height: 44),
                variant: variant
            )
            let text = (1...lines).map { "line \($0)" }.joined(separator: "\n")
            probe.apply(AgentComposerDraft(text: text, selection: NSRange(location: 0, length: 0), revision: 1))
            probe.layoutSubtreeIfNeeded()
            return probe.intrinsicContentSize.height
        }
        let compactSixLines = measuredComposerHeight(.compactFreeform, lines: 6)
        guard compactSixLines == measuredComposerHeight(.fullTurn, lines: 4),
              compactSixLines < measuredComposerHeight(.fullTurn, lines: 6) else {
            throw fail("compact composer shell did not cap at four visual lines")
        }
        let emptyCompact = AgentComposerView(frame: .zero, variant: .compactFreeform)
        guard emptyCompact.qaPlaceholderVisible,
              AgentComposerVariant.compactFreeform.placeholder == "Write a response…" else {
            throw fail("compact composer shell lost its response placeholder")
        }

        guard let agentKindEntry = entries.first(where: { $0.id == "agent.kind" }),
              case let .staticCard(_, makeAgentKindView) = agentKindEntry.content else {
            throw fail("missing agent.kind descriptor card")
        }
        let agentKindView = makeAgentKindView()
        guard let kindLabel = agentKindView.descendant(withIdentifier: "agentKind.value") as? NSTextField else {
            throw fail("agent.kind card missing agentKind.value label")
        }
        guard kindLabel.stringValue == "Kind -> claude" else {
            throw fail("agent.kind label rendered '\(kindLabel.stringValue)', expected 'Kind -> claude'")
        }
        guard let observerSidebarEntry = entries.first(where: { $0.id == "chrome.sidebar.observerFeed" }),
              case let .staticCard(_, makeObserverSidebarView) = observerSidebarEntry.content else {
            throw fail("missing chrome.sidebar.observerFeed card")
        }
        guard let observerSidebar = makeObserverSidebarView() as? WorkspaceSidebarView else {
            throw fail("observer-fed sidebar card did not return WorkspaceSidebarView")
        }
        let observerSidebarWorkspaceId = LabFixtures.workspaceId
        let observerSidebarZoneId = UUID(uuidString: "00000000-0000-0000-0000-00000000B441")!
        let observerSidebarNeedsTileId = UUID(uuidString: "00000000-0000-0000-0000-00000000B451")!
        let observerSidebarWorkingTileId = UUID(uuidString: "00000000-0000-0000-0000-00000000B452")!
        observerSidebar.layoutSubtreeIfNeeded()
        guard observerSidebar.tileStatusGlyphForQA(workspaceId: observerSidebarWorkspaceId, zoneId: observerSidebarZoneId, tileId: observerSidebarNeedsTileId) == "◆",
              observerSidebar.tileStatusTextForQA(workspaceId: observerSidebarWorkspaceId, zoneId: observerSidebarZoneId, tileId: observerSidebarNeedsTileId) == "needs you",
              observerSidebar.tileStatusGlyphForQA(workspaceId: observerSidebarWorkspaceId, zoneId: observerSidebarZoneId, tileId: observerSidebarWorkingTileId) == "●",
              observerSidebar.tileStatusTextForQA(workspaceId: observerSidebarWorkspaceId, zoneId: observerSidebarZoneId, tileId: observerSidebarWorkingTileId) == "working" else {
            throw fail("observer-fed sidebar card did not render needs-attention and working tile rows")
        }
        guard observerSidebar.zoneStatusTextForQA(workspaceId: observerSidebarWorkspaceId, zoneId: observerSidebarZoneId) == "1 working · 1 needs you" else {
            throw fail("observer-fed sidebar zone rollup rendered '\(observerSidebar.zoneStatusTextForQA(workspaceId: observerSidebarWorkspaceId, zoneId: observerSidebarZoneId) ?? "nil")'")
        }
        guard let observerRollupEntry = entries.first(where: { $0.id == "observer.rollup" }),
              case let .staticCard(_, makeObserverRollupView) = observerRollupEntry.content else {
            throw fail("missing observer.rollup card")
        }
        guard let observerCanvas = makeObserverRollupView() as? CanvasNSView else {
            throw fail("observer.rollup card did not return a CanvasNSView")
        }
        let observerZoneId = UUID(uuidString: "00000000-0000-0000-0000-00000000A432")!
        let observerWorkingId = UUID(uuidString: "00000000-0000-0000-0000-00000000A433")!
        let observerNeedsId = UUID(uuidString: "00000000-0000-0000-0000-00000000A434")!
        let observerPlainId = UUID(uuidString: "00000000-0000-0000-0000-00000000A435")!
        guard observerCanvas.zoneChromeSnapshot(for: observerZoneId)?.agentRollupText == "1 working · 1 needs you" else {
            throw fail("observer.rollup zone text rendered '\(observerCanvas.zoneChromeSnapshot(for: observerZoneId)?.agentRollupText ?? "nil")'")
        }
        guard observerCanvas.tileChromeSnapshot(for: observerWorkingId)?.agentStatus == .working,
              observerCanvas.tileChromeSnapshot(for: observerNeedsId)?.agentStatus == .needsAttention,
              observerCanvas.tileChromeSnapshot(for: observerPlainId)?.agentStatus == nil else {
            throw fail("observer.rollup tile badge states did not render working/needs/nil")
        }
        guard let agentsBoardEntry = entries.first(where: { $0.id == "agents.board" }),
              case let .staticCard(_, makeAgentsBoardView) = agentsBoardEntry.content else {
            throw fail("missing agents.board projection card")
        }
        let agentsBoardView = makeAgentsBoardView()
        func agentsBoardText(_ row: Int) throws -> String {
            guard let field = agentsBoardView.descendant(withIdentifier: "agentsBoard.row.\(row)") as? NSTextField else {
                throw fail("agents board card missing row \(row)")
            }
            return field.stringValue
        }
        let agentsBoardRow1 = try agentsBoardText(1)
        let agentsBoardRow2 = try agentsBoardText(2)
        let agentsBoardRow3 = try agentsBoardText(3)
        let agentsBoardRow4 = try agentsBoardText(4)
        // P1.8: the `[orange]`/`[blue]` field was `AgentStatusPresentation.colorToken`,
        // the stringly-typed channel this ticket deleted. The glyph is unchanged
        // and now comes from the shared presenter — and the row's COLOUR, which
        // no assertion could reach while it was a string, is asserted below.
        guard agentsBoardRow1.contains("◆ needsAttention alpha needs approval") else {
            throw fail("agents board row 1 rendered '\(agentsBoardRow1)'")
        }
        guard agentsBoardRow2.contains("◆ needsAttention beta needs input") else {
            throw fail("agents board row 2 rendered '\(agentsBoardRow2)'")
        }
        guard agentsBoardRow3.contains("● working delta is running checks") else {
            throw fail("agents board row 3 rendered '\(agentsBoardRow3)'")
        }
        guard agentsBoardRow4.contains("✓ done gamma finished cleanly") else {
            throw fail("agents board row 4 rendered '\(agentsBoardRow4)'")
        }

        // The packet's verification: what a migrated call site RENDERS is the
        // presenter's own value, in both appearances. Reading the field's
        // textColor back per appearance is what makes this a statement about the
        // pixels rather than about the code path — a hardcoded `.systemOrange`
        // here would land on 0xFF9F0A/0xFF9500, not on `accentApproval`.
        func renderedHexKey(_ field: NSTextField, _ appearance: NSAppearance) throws -> String {
            guard let color = field.textColor else { throw fail("agents board row has no textColor") }
            var key = ""
            appearance.performAsCurrentDrawingAppearance {
                if let srgb = color.usingColorSpace(.sRGB) {
                    key = ChipColor(
                        r: Double(srgb.redComponent),
                        g: Double(srgb.greenComponent),
                        b: Double(srgb.blueComponent)).hexKey
                }
            }
            return key
        }
        let appearancesByTheme: [(TokenTheme, NSAppearance)] = [
            (.light, NSAppearance(named: .aqua)!),
            (.dark, NSAppearance(named: .darkAqua)!),
        ]
        // EVERY status, not just the three the canned board fixture happens to
        // carry — otherwise `configuring` (the status that was purple here and
        // teal on the board) would have no rendered witness at all. Built from a
        // synthetic row per status through the real `makeAgentsBoardView(rows:)`,
        // so this needs no fixture change and moves no baseline.
        let everyStatusRows = AgentStatus.allCases.enumerated().map { index, status in
            AgentsBoardRow(
                agentId: UUID(uuidString: "88000000-0000-4000-8000-0000000001\(String(format: "%02d", index))")!,
                status: status,
                lastSummary: "row for \(status.rawValue)",
                recent: [],
                updatedAt: Date(timeIntervalSinceReferenceDate: Double(index))
            )
        }
        // Qualified: `makeAgentsBoardView` is shadowed above by the card's own
        // no-argument closure binding.
        let everyStatusBoard = LabCatalog.makeAgentsBoardView(rows: everyStatusRows)
        for (index, row) in everyStatusRows.enumerated() {
            guard let field = everyStatusBoard.descendant(withIdentifier: "agentsBoard.row.\(index + 1)") as? NSTextField else {
                throw fail("all-status agents board missing row \(index + 1)")
            }
            let display = StatusChipPresenter.display(for: row.status)
            guard field.stringValue.hasPrefix(display.glyph) else {
                throw fail("all-status agents board row for \(row.status.rawValue) rendered "
                           + "'\(field.stringValue)', presenter glyph is '\(display.glyph)'")
            }
            for (theme, appearance) in appearancesByTheme {
                let rendered = try renderedHexKey(field, appearance)
                let expected = display.accent.resolved(for: theme).hexKey
                guard rendered == expected else {
                    throw fail("all-status agents board row for \(row.status.rawValue) rendered #\(rendered) "
                               + "in \(theme.rawValue), presenter says #\(expected)")
                }
            }
        }
        // …and the canned fixture rows the baselines are taken from, so the
        // pinned board card is covered by the same assertion.
        for (rowIndex, status) in [(1, AgentStatus.needsAttention), (3, .working), (4, .done)] {
            guard let field = agentsBoardView.descendant(withIdentifier: "agentsBoard.row.\(rowIndex)") as? NSTextField else {
                throw fail("agents board card missing row \(rowIndex)")
            }
            let accent = StatusChipPresenter.display(for: status).accent
            for (theme, appearance) in appearancesByTheme {
                let rendered = try renderedHexKey(field, appearance)
                let expected = accent.resolved(for: theme).hexKey
                guard rendered == expected else {
                    throw fail("agents board row \(rowIndex) (\(status.rawValue)) rendered #\(rendered) in "
                               + "\(theme.rawValue), presenter says #\(expected)")
                }
            }
        }
        guard let approvalsInboxEntry = entries.first(where: { $0.id == "approvals.inbox" }),
              case let .staticCard(_, makeApprovalsInboxView) = approvalsInboxEntry.content else {
            throw fail("missing approvals.inbox card")
        }
        let approvalsInboxView = makeApprovalsInboxView()
        func approvalsInboxText(_ identifier: String) throws -> String {
            guard let field = approvalsInboxView.descendant(withIdentifier: identifier) as? NSTextField else {
                throw fail("approvals inbox card missing label \(identifier)")
            }
            return field.stringValue
        }
        let approvalsCount = try approvalsInboxText("approvalsInbox.count")
        guard approvalsCount == "Approvals Inbox — attentionCount=2" else {
            throw fail("approvals inbox count rendered '\(approvalsCount)'")
        }
        let approvalsRow1 = try approvalsInboxText("approvalsInbox.row.1")
        let approvalsRow2 = try approvalsInboxText("approvalsInbox.row.2")
        guard approvalsRow1.contains("◆ alpha approve deploy request=approval-alpha") else {
            throw fail("approvals inbox row 1 rendered '\(approvalsRow1)'")
        }
        guard approvalsRow2.contains("◆ beta legacy request request=no-id") else {
            throw fail("approvals inbox row 2 rendered '\(approvalsRow2)'")
        }
        let approvalsScope = try approvalsInboxText("approvalsInbox.scope")
        guard approvalsScope == "observer=missing:orchestrationOperate operator=allowed" else {
            throw fail("approvals inbox scope rendered '\(approvalsScope)'")
        }
        guard let pushSmokeEntry = entries.first(where: { $0.id == "push.smoke" }),
              case let .staticCard(_, makePushSmokeView) = pushSmokeEntry.content else {
            throw fail("missing push.smoke card")
        }
        let pushSmokeView = makePushSmokeView()
        func pushSmokeText(_ identifier: String) throws -> String {
            guard let field = pushSmokeView.descendant(withIdentifier: identifier) as? NSTextField else {
                throw fail("push smoke card missing label \(identifier)")
            }
            return field.stringValue
        }
        let pushRows = try (1...8).map { try pushSmokeText("pushSmoke.row.\($0)") }
        guard pushRows.count == 8 else {
            throw fail("push smoke row count \(pushRows.count), expected 8")
        }
        guard pushRows[0].contains(PushCategory.approveActionId), pushRows[0].contains(PushCategory.denyActionId) else {
            throw fail("push smoke N1 row missing approve/deny actions: \(pushRows[0])")
        }
        let pushOutcome = try pushSmokeText("pushSmoke.outcome")
        guard pushOutcome == "firing: fire -> dedup-suppressed -> refire on phase change" else {
            throw fail("push smoke outcome rendered '\(pushOutcome)'")
        }
        guard let notifyCategoriesEntry = entries.first(where: { $0.id == "notify.categories" }),
              case let .staticCard(_, makeNotifyCategoriesView) = notifyCategoriesEntry.content else {
            throw fail("missing notify.categories card")
        }
        let notifyCategoriesView = makeNotifyCategoriesView()
        func notifyCategoriesText(_ identifier: String) throws -> String {
            guard let field = notifyCategoriesView.descendant(withIdentifier: identifier) as? NSTextField else {
                throw fail("notify categories card missing label \(identifier)")
            }
            return field.stringValue
        }
        let notifyRows = try (1...7).map { try notifyCategoriesText("notifyCategories.row.\($0)") }
        guard notifyRows.count == 7 else {
            throw fail("notify categories row count \(notifyRows.count), expected 7")
        }
        let expectedNotifyDefaults: [(PushCategory, String)] = [
            (.approvalRequested, "default=on gate=allow"),
            (.agentWaitingForInput, "default=on gate=allow"),
            (.agentFinished, "default=on gate=allow"),
            (.agentFailed, "default=on gate=allow"),
            (.stillWorkingDigest, "default=on gate=allow"),
            (.desktopConnectionChanged, "default=off gate=mute"),
            (.sessionReapedOrRevived, "default=off gate=mute"),
        ]
        for (index, expected) in expectedNotifyDefaults.enumerated() {
            let (category, fragment) = expected
            guard notifyRows[index].contains(category.rawValue), notifyRows[index].contains(fragment) else {
                throw fail("notify categories row \(index + 1) rendered '\(notifyRows[index])'")
            }
        }
        guard let canvasSceneEntry = entries.first(where: { $0.id == "canvas.scene" }),
              case let .staticCard(_, makeCanvasSceneView) = canvasSceneEntry.content else {
            throw fail("missing canvas.scene projection card")
        }
        let canvasSceneView = makeCanvasSceneView()
        func canvasSceneText(_ identifier: String) throws -> String {
            guard let field = canvasSceneView.descendant(withIdentifier: identifier) as? NSTextField else {
                throw fail("canvas scene card missing label \(identifier)")
            }
            return field.stringValue
        }
        let canvasSceneZone1 = try canvasSceneText("canvasScene.zone.1")
        let canvasSceneZone2 = try canvasSceneText("canvasScene.zone.2")
        guard canvasSceneZone1 == "Alpha [mint] z=0.3" else {
            throw fail("canvas scene zone 1 rendered '\(canvasSceneZone1)'")
        }
        guard canvasSceneZone2 == "Beta [amber] z=0.6" else {
            throw fail("canvas scene zone 2 rendered '\(canvasSceneZone2)'")
        }
        let canvasSceneTile1 = try canvasSceneText("canvasScene.tile.1")
        let canvasSceneTile2 = try canvasSceneText("canvasScene.tile.2")
        let canvasSceneTile3 = try canvasSceneText("canvasScene.tile.3")
        let canvasSceneTile4 = try canvasSceneText("canvasScene.tile.4")
        guard canvasSceneTile1 == "#1 terminal — shell (ambient)" else {
            throw fail("canvas scene tile 1 rendered '\(canvasSceneTile1)'")
        }
        guard canvasSceneTile2 == "#2 globe — localhost:3000 (Alpha)" else {
            throw fail("canvas scene tile 2 rendered '\(canvasSceneTile2)'")
        }
        guard canvasSceneTile3 == "#3 note.text — scratch.md (ambient)" else {
            throw fail("canvas scene tile 3 rendered '\(canvasSceneTile3)'")
        }
        guard canvasSceneTile4 == "#4 folder — files (ambient)" else {
            throw fail("canvas scene tile 4 rendered '\(canvasSceneTile4)'")
        }
        guard let adapterEntry = entries.first(where: { $0.id == "agent.adapter.projection" }),
              case let .staticCard(_, makeAdapterView) = adapterEntry.content else {
            throw fail("missing agent.adapter.projection card")
        }
        let adapterView = makeAdapterView()
        func adapterText(_ row: Int) throws -> String {
            guard let field = adapterView.descendant(withIdentifier: "agentAdapterProjection.row.\(row)") as? NSTextField else {
                throw fail("agent adapter projection card missing row \(row)")
            }
            return field.stringValue
        }
        let adapterRow1 = try adapterText(1)
        let adapterRow2 = try adapterText(2)
        let adapterRow5 = try adapterText(5)
        let adapterRow6 = try adapterText(6)
        let adapterRow9 = try adapterText(9)
        guard adapterRow1.hasSuffix("-> configuring") else {
            throw fail("agent adapter row 1 rendered '\(adapterRow1)'")
        }
        guard adapterRow2.hasSuffix("-> working") else {
            throw fail("agent adapter row 2 rendered '\(adapterRow2)'")
        }
        guard adapterRow5.hasSuffix("-> needsAttention") else {
            throw fail("agent adapter row 5 rendered '\(adapterRow5)'")
        }
        guard adapterRow6.hasSuffix("-> working") else {
            throw fail("agent adapter row 6 rendered '\(adapterRow6)'")
        }
        guard adapterRow9.hasSuffix("-> done") else {
            throw fail("agent adapter row 9 rendered '\(adapterRow9)'")
        }
        guard let managedEntry = entries.first(where: { $0.id == "managed.session.record" }),
              case let .staticCard(_, makeManagedView) = managedEntry.content else {
            throw fail("missing managed.session.record card")
        }
        let managedView = makeManagedView()
        func managedText(_ identifier: String) throws -> String {
            guard let field = managedView.descendant(withIdentifier: identifier) as? NSTextField else {
                throw fail("managed session card missing label \(identifier)")
            }
            return field.stringValue
        }
        let managedAgentKind = try managedText("managedSession.agentKind")
        let managedStatus = try managedText("managedSession.status")
        let managedWindowTarget = try managedText("managedSession.tmuxWindowTarget")
        guard managedAgentKind == "agentKind  → shell" else {
            throw fail("managed session agentKind label rendered '\(managedAgentKind)'")
        }
        guard managedStatus == "status  → running" else {
            throw fail("managed session status label rendered '\(managedStatus)'")
        }
        guard managedWindowTarget == "tmuxWindowTarget  → %42" else {
            throw fail("managed session window target label rendered '\(managedWindowTarget)'")
        }
        guard let pairingEntry = entries.first(where: { $0.id == "auth.pairingToken" }),
              case let .staticCard(_, makePairingView) = pairingEntry.content else {
            throw fail("missing auth.pairingToken card")
        }
        let pairingView = makePairingView()
        guard let pairingURLLabel = pairingView.descendant(withIdentifier: "pairingToken.url") as? NSTextField,
              let credentialLabel = pairingView.descendant(withIdentifier: "pairingToken.credential") as? NSTextField else {
            throw fail("pairing token card missing URL or credential labels")
        }
        guard let pairingURL = URL(string: pairingURLLabel.stringValue),
              let components = URLComponents(url: pairingURL, resolvingAgainstBaseURL: false) else {
            throw fail("pairing token URL did not parse: \(pairingURLLabel.stringValue)")
        }
        guard pairingURLLabel.stringValue.contains("#token=") else {
            throw fail("pairing token URL missing #token= fragment: \(pairingURLLabel.stringValue)")
        }
        guard components.queryItems == nil else {
            throw fail("pairing token URL leaked query items: \(pairingURLLabel.stringValue)")
        }
        guard credentialLabel.stringValue.count == 12 else {
            throw fail("pairing token credential length \(credentialLabel.stringValue.count), expected 12")
        }
        guard PairingAlphabet.containsOnlySymbols(credentialLabel.stringValue) else {
            throw fail("pairing token credential contains non-crowd-safe characters: \(credentialLabel.stringValue)")
        }
        guard let managedAgentEntry = entries.first(where: { $0.id == "tiles.managedAgent" }),
              case let .staticCard(_, makeManagedAgentView) = managedAgentEntry.content else {
            throw fail("missing tiles.managedAgent card")
        }
        guard let managedAgentView = makeManagedAgentView() as? ManagedAgentTileNSView else {
            throw fail("tiles.managedAgent did not vend ManagedAgentTileNSView")
        }
        guard managedAgentView.transcriptCardCount >= 3 else {
            throw fail("managed agent fixture rendered \(managedAgentView.transcriptCardCount) cards, expected at least 3")
        }
        guard managedAgentView.activeToolCount == 1 else {
            throw fail("managed agent fixture active tool count \(managedAgentView.activeToolCount), expected 1")
        }
        guard managedAgentView.currentAgentStatus == .needsAttention else {
            throw fail("managed agent fixture status \(managedAgentView.currentAgentStatus), expected needsAttention")
        }
        let v2ManagedAgentView = LabCatalog.makeManagedAgentFixtureView(includeApproval: false)
        guard v2ManagedAgentView.qaUsesV2Tile,
              v2ManagedAgentView.qaUsesFullTurnComposer,
              !v2ManagedAgentView.qaHasLegacyComposeField,
              !v2ManagedAgentView.qaHasPermanentApprovalDock,
              v2ManagedAgentView.qaV2RenderError == nil else {
            throw fail("Component Lab v2 construction seam did not install the migrated tile exclusively")
        }
        guard entries.contains(where: { $0.id == "managed-agent.approval-dock" }) else {
            throw fail("missing managed-agent.approval-dock card")
        }
        guard let newTileCwdEntry = entries.first(where: { $0.id == "terminal.new-tile-cwd" }),
              case let .staticCard(_, makeNewTileCwdView) = newTileCwdEntry.content else {
            throw fail("missing terminal.new-tile-cwd card")
        }
        let newTileCwdView = makeNewTileCwdView()
        for (index, policy) in NewTileCwdPolicy.allCases.enumerated() {
            guard let row = newTileCwdView.descendant(withIdentifier: "newTileCwd.policy.\(index)") as? NSTextField else {
                throw fail("new terminal cwd policy card missing row \(index)")
            }
            guard row.stringValue.hasPrefix("\(policy.rawValue) -> ") else {
                throw fail("new terminal cwd policy row \(index) rendered '\(row.stringValue)', expected prefix \(policy.rawValue)")
            }
        }
        guard let topologyMigrationEntry = entries.first(where: { $0.id == "terminal.topology-migration-note" }),
              case let .staticCard(_, makeTopologyMigrationView) = topologyMigrationEntry.content else {
            throw fail("missing terminal.topology-migration-note card")
        }
        let topologyMigrationView = makeTopologyMigrationView()
        guard let topologyTitle = topologyMigrationView.descendant(withIdentifier: "topologyMigration.title") as? NSTextField,
              let topologyBody = topologyMigrationView.descendant(withIdentifier: "topologyMigration.body") as? NSTextField,
              let topologyOK = topologyMigrationView.descendant(withIdentifier: "topologyMigration.ok") as? NSButton else {
            throw fail("topology migration note card missing title, body, or OK button")
        }
        guard topologyTitle.stringValue == "Session model updated" else {
            throw fail("topology migration note title rendered '\(topologyTitle.stringValue)'")
        }
        guard topologyBody.stringValue.contains("tmux") && topologyBody.stringValue.contains("restart once") else {
            throw fail("topology migration note body missing tmux/restart copy: '\(topologyBody.stringValue)'")
        }
        guard topologyOK.title == "OK" else {
            throw fail("topology migration note button rendered '\(topologyOK.title)'")
        }
        try runApprovalDockLiveCheck(fail: fail)
        try runUserInputCardLiveCheck(fail: fail)

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("component-lab", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var rendered = try runStaticCardGates(entries: entries, artifactDirectory: directory, fail: fail)

        // Interactive sandbox: spawn every fixture tile kind, assert they install,
        // render each tile non-blank, that zoom clamps via setViewport, and that
        // teardown deletes the throwaway temp dir.
        let sandbox = LabSandboxContext(env: LabEnvironment(ghostty: nil, browserEngine: nil))
        sandbox.spawnNote(); sandbox.spawnFile(); sandbox.spawnFileTree(); sandbox.spawnRunArtifacts(); sandbox.spawnDescriptor()
        guard sandbox.canvas.canvasState.tiles.count == 5 else {
            throw fail("sandbox installed \(sandbox.canvas.canvasState.tiles.count) tiles, expected 5")
        }
        guard sandbox.qaTempDirExists else { throw fail("sandbox temp dir was not created") }

        let sandboxWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        sandbox.containerView.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        sandboxWindow.contentView = sandbox.containerView
        sandbox.containerView.layoutSubtreeIfNeeded()
        sandbox.canvas.layoutSubtreeIfNeeded()
        let tileViews = sandbox.canvas.subviews.compactMap { $0 as? TileNSView }
        guard tileViews.count == 5 else { throw fail("sandbox canvas has \(tileViews.count) tile views, expected 5") }
        for tileView in tileViews {
            tileView.layoutSubtreeIfNeeded()
            guard let rep = tileView.bitmapImageRepForCachingDisplay(in: tileView.bounds) else { throw fail("sandbox tile bitmap alloc failed") }
            tileView.cacheDisplay(in: tileView.bounds, to: rep)
            let m = VisualSnapshot.metrics(of: rep)
            guard !m.isBlank else { throw fail("sandbox tile '\(tileView.tile.title)' render is blank (\(m.distinctSampledColors) colors)") }
        }

        sandbox.setZoom(5.0); let zoomHigh = sandbox.canvas.viewport.zoom
        sandbox.setZoom(0.01); let zoomLow = sandbox.canvas.viewport.zoom
        guard abs(zoomHigh - 3.0) < 1e-6, abs(zoomLow - 0.25) < 1e-6 else {
            throw fail("zoom clamp wrong: high=\(zoomHigh) (want 3.0), low=\(zoomLow) (want 0.25)")
        }

        // Affordance inspector: overlay installs, and the screen-px floors hold
        // across zoom (regression gate on the docs/25 dead-corner/grab bugs).
        let probe = tileViews[0]
        probe.showsInteractionAffordances = true
        guard probe.qaAffordanceOverlayInstalled else { throw fail("affordance overlay did not install") }
        for zoom in [0.5, 1.0, 2.0] {
            sandbox.setZoom(zoom)
            let a = probe.affordanceMetrics()
            guard abs(a.resizeEdgeScreenPx - 8) < 0.5 else { throw fail("resize edge \(a.resizeEdgeScreenPx)px @ zoom \(zoom), want 8") }
            guard a.cornerScreenPx >= 15.5 else { throw fail("corner \(a.cornerScreenPx)px @ zoom \(zoom), want >=16") }
            guard a.grabScreenPx >= 27.5 else { throw fail("grab \(a.grabScreenPx)px @ zoom \(zoom), want >=28") }
            guard a.closeScreenPx >= 21.5 else { throw fail("close \(a.closeScreenPx)px @ zoom \(zoom), want >=22") }
        }
        sandbox.setZoom(1.0)
        probe.layoutSubtreeIfNeeded()
        if let rep = probe.bitmapImageRepForCachingDisplay(in: probe.bounds) {
            probe.cacheDisplay(in: probe.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("affordance-overlay.png"))
            guard !VisualSnapshot.metrics(of: rep).isBlank else { throw fail("affordance overlay render is blank") }
        }

        probe.showsInteractionAffordances = false
        guard !probe.qaAffordanceOverlayInstalled else { throw fail("affordance overlay did not uninstall") }

        sandbox.teardownAll()
        guard !sandbox.qaTempDirExists else { throw fail("sandbox temp dir survived teardown") }

        // Delete-tombstone visual gate (ticket 05): three tiles, close the
        // middle one through the REAL onTileCloseRequested -> removeTile path
        // (the same wiring the lab uses at panel setup), and assert exactly the
        // two survivors remain — by id, not count alone — with a non-degenerate
        // render. This is the UI close path that later emits a deleteTile op
        // once ticket 06 wires the op-log store.
        do {
            let ids = (1...3).map { UUID(uuidString: "00000000-0000-0000-0000-00000000D10\($0)")! }
            let closeTiles = ids.enumerated().map { i, id in
                Tile(id: id, kind: .note, title: "close-\(i + 1)",
                     frame: TileFrame(x: Double(i) * 220 + 20, y: 40, width: 200, height: 150),
                     zPosition: .fromLegacyRank(i + 1), runtimeRef: nil, metadata: TileMetadata())
            }
            let closeCanvas = CanvasNSView(
                canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
                activeZone: nil, zoneRenderModels: [], showsZoneChrome: false)
            closeCanvas.frame = NSRect(x: 0, y: 0, width: 720, height: 260)
            let closeWindow = NSWindow(contentRect: closeCanvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            closeWindow.contentView = closeCanvas
            closeCanvas.onTileCloseRequested = { [weak closeCanvas] id in closeCanvas?.removeTile(id: id) }
            for tile in closeTiles {
                closeCanvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
            }
            closeCanvas.layoutSubtreeIfNeeded()
            guard closeCanvas.canvasState.tiles.count == 3 else { throw fail("delete gate: expected 3 tiles installed") }
            closeCanvas.onTileCloseRequested?(ids[1])   // close the MIDDLE tile
            closeCanvas.layoutSubtreeIfNeeded()
            let surviving = Set(closeCanvas.canvasState.tiles.map(\.id))
            guard surviving == [ids[0], ids[2]] else {
                throw fail("delete gate: survivors must be exactly {first, last}, got \(surviving)")
            }
            let survivingViews = closeCanvas.subviews.compactMap { ($0 as? TileNSView)?.tile.id }
            guard Set(survivingViews) == [ids[0], ids[2]] else {
                throw fail("delete gate: rendered tile views must match survivors, got \(survivingViews)")
            }
            guard let rep = closeCanvas.bitmapImageRepForCachingDisplay(in: closeCanvas.bounds) else {
                throw fail("delete gate: bitmap alloc failed")
            }
            closeCanvas.cacheDisplay(in: closeCanvas.bounds, to: rep)
            let metrics = VisualSnapshot.metrics(of: rep)
            guard metrics.width > 0, metrics.height > 0, !metrics.isBlank else {
                throw fail("delete gate: render degenerate (\(metrics.distinctSampledColors) colors at \(metrics.width)x\(metrics.height))")
            }
            try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("delete-tombstone.png"))
            rendered.append(["entry": "delete.tombstone.gate", "tilesAfterClose": surviving.count, "width": metrics.width, "height": metrics.height])
        }

        // Launcher pane legibility on the dark host (light-on-dark, accent button).
        let launcherHost = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        launcherHost.wantsLayer = true
        launcherHost.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        let launcherWindow = NSWindow(contentRect: launcherHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        launcherWindow.contentView = launcherHost
        let pane = makeLauncherPane(title: "Command Palette", summary: "The real ⌘K launch palette. Opens empty here — the app fills it with live profiles/projects.", buttonTitle: "Open Command Palette", target: nil, action: nil)
        pane.translatesAutoresizingMaskIntoConstraints = false
        launcherHost.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.centerXAnchor.constraint(equalTo: launcherHost.centerXAnchor),
            pane.centerYAnchor.constraint(equalTo: launcherHost.centerYAnchor),
            pane.widthAnchor.constraint(lessThanOrEqualToConstant: 400)
        ])
        launcherHost.layoutSubtreeIfNeeded()
        if let rep = launcherHost.bitmapImageRepForCachingDisplay(in: launcherHost.bounds) {
            launcherHost.cacheDisplay(in: launcherHost.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("launcher-pane.png"))
            // >3 sampled colours: dark host + light title + grey summary + accent
            // button + white label — a dark-on-dark regression would collapse this.
            guard VisualSnapshot.metrics(of: rep).distinctSampledColors > 3 else {
                throw fail("launcher pane is low-contrast (dark-on-dark?)")
            }
        }

        // Session naming panel (ticket 14): assert the three labels read exactly
        // the expected strings for the fixed UUID — the -proj-/-ws- prefixes are
        // the load-bearing dogfood proof, not the render-blank check above.
        let sessionNamingView = LabCatalog.makeSessionNamingView(fixtureId: LabCatalog.sessionNamingFixtureId)
        func labelText(_ identifier: String) throws -> String {
            guard let field = sessionNamingView.subviews.compactMap({ $0 as? NSTextField })
                .first(where: { $0.identifier?.rawValue == identifier }) else {
                throw fail("session naming panel missing label \(identifier)")
            }
            return field.stringValue
        }
        let expectedProjectLabel = "projectSessionName  → continuum-proj-00000000-0000-0000-0000-000000000001"
        let expectedAmbientLabel = "ambientSessionName  → continuum-ws-00000000-0000-0000-0000-000000000001"
        let expectedSessionLabel = "sessionName(tileId) → continuum-00000000-0000-0000-0000-000000000001"
        let projectLabel = try labelText("sessionNaming.projectSessionName")
        let ambientLabel = try labelText("sessionNaming.ambientSessionName")
        let sessionLabel = try labelText("sessionNaming.sessionName")
        guard projectLabel == expectedProjectLabel else {
            throw fail("session naming panel projectSessionName label: expected '\(expectedProjectLabel)' got '\(projectLabel)'")
        }
        guard ambientLabel == expectedAmbientLabel else {
            throw fail("session naming panel ambientSessionName label: expected '\(expectedAmbientLabel)' got '\(ambientLabel)'")
        }
        guard sessionLabel == expectedSessionLabel else {
            throw fail("session naming panel sessionName label: expected '\(expectedSessionLabel)' got '\(sessionLabel)'")
        }

        let manifest: [String: Any] = [
            "check": "component-lab",
            "entryCount": entries.count,
            "rendered": rendered,
            "sandbox": ["tilesInstalled": 5, "zoomClampHigh": zoomHigh, "zoomClampLow": zoomLow],
            "agentKind": ["label": kindLabel.stringValue],
            "agentsBoard": [
                "row1": agentsBoardRow1,
                "row2": agentsBoardRow2,
                "row3": agentsBoardRow3,
                "row4": agentsBoardRow4
            ],
            "pushSmoke": [
                "rows": pushRows,
                "outcome": pushOutcome
            ],
            "agentAdapterProjection": [
                "row1": adapterRow1,
                "row2": adapterRow2,
                "row5": adapterRow5,
                "row6": adapterRow6,
                "row9": adapterRow9
            ],
            "managedSessionRecord": [
                "agentKind": managedAgentKind,
                "status": managedStatus,
                "tmuxWindowTarget": managedWindowTarget
            ],
            "sessionNaming": [
                "projectSessionName": projectLabel,
                "ambientSessionName": ambientLabel,
                "sessionName": sessionLabel
            ],
            // P0.7: the `sidebarSelection` delta and `userInputCard` colour-count
            // sections reported the two hand-picked distinct-colour assertions that
            // the committed baselines now subsume. Per-card numbers live in
            // `rendered`, one row per card AND appearance.
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
    }

    private static func runApprovalDockLiveCheck(fail: (String) -> Error) throws {
        let tile = Tile(
            id: UUID(uuidString: "72000000-0000-4000-8000-000000000072")!,
            kind: .managedAgent,
            title: "Claude · feature/auth",
            frame: TileFrame(x: 80, y: 60, width: 520, height: 260),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        )
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [tile],
            groups: [],
            lastActiveTileId: nil
        ))
        let view = ManagedAgentTileNSView(tile: tile)
        canvas.install(tileView: view, for: tile)
        view.ingest(.sessionStateChanged(.running))
        view.ingest(.turnStarted(threadId: "thread-main", turnId: "turn-live"))
        view.ingest(.requestOpened(threadId: "thread-main", requestId: "approval-live", kind: .commandExecutionApproval))
        canvas.markActive(tileId: tile.id)

        guard canvas.agentStatus(for: tile.id) == .needsAttention else {
            throw fail("approval live check: canvas status did not become needsAttention")
        }
        guard canvas.attentionTileIds.contains(tile.id) else {
            throw fail("approval live check: canvas did not track the attention tile")
        }
        guard canvas.qaAttentionBorderActive(for: tile.id) else {
            throw fail("approval live check: attention border is not active")
        }
        guard !canvas.qaFocusBorderActive else {
            throw fail("approval live check: focus border must be suppressed while attention is active")
        }
        // P5.5: the legacy dock is gone — the request lives in the transcript as
        // the reducer-projected block with the compiled choices, and only the
        // real runtime resolution turns it passive (P5.4 rule).
        guard view.qaV2RequestIDs == ["approval-live"],
              view.qaV2RequestChoices("approval-live") == ApprovalDecision.compiledChoices else {
            throw fail("approval live check: the request block did not render the compiled choices (ids \(view.qaV2RequestIDs))")
        }
        guard !view.qaHasPermanentApprovalDock else {
            throw fail("approval live check: a legacy approval dock is reachable after the P5.5 removal")
        }

        view.ingest(.requestResolved(threadId: "thread-main", requestId: "approval-live", decision: ApprovalDecision.accept.rawValue))
        guard canvas.agentStatus(for: tile.id) != AgentStatus.needsAttention else {
            throw fail("approval live check: status stayed needsAttention after the runtime resolution")
        }
        guard canvas.attentionTileIds.isEmpty else {
            throw fail("approval live check: attention set not cleared after the runtime resolution")
        }
        guard !canvas.qaAttentionBorderActive(for: tile.id) else {
            throw fail("approval live check: attention border stayed active after the runtime resolution")
        }
        guard view.qaV2RequestStatus("approval-live") == .completed else {
            throw fail("approval live check: the request block did not turn passive on the runtime resolution")
        }
    }

    private static func runUserInputCardLiveCheck(fail: (String) -> Error) throws {
        let tile = Tile(
            id: UUID(uuidString: "73000000-0000-4000-8000-000000000073")!,
            kind: .managedAgent,
            title: "Claude · feature/migrations",
            frame: TileFrame(x: 80, y: 60, width: 520, height: 260),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        )
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [tile],
            groups: [],
            lastActiveTileId: nil
        ))
        let view = ManagedAgentTileNSView(tile: tile)
        canvas.install(tileView: view, for: tile)
        view.ingest(.sessionStateChanged(.running))
        view.ingest(.turnStarted(threadId: "thread-main", turnId: "turn-live-input"))
        view.ingest(.contentDelta(threadId: "thread-main", turnId: "turn-live-input", streamKind: .assistant, delta: "I need one naming decision."))
        view.ingest(.userInputRequested(threadId: "thread-main", requestId: "input-live", questions: [
            UserInputQuestion(key: "filename", prompt: "What should I name the new migration file?")
        ]))
        canvas.markActive(tileId: tile.id)

        // P5.5: the legacy typed-answer card is gone with the compatibility path —
        // there is no compiled respond transport, so a text editor here fabricated
        // a capability (the P5.4 rule). The request renders as the reducer's
        // question block, holds attention, and only the runtime resolution clears
        // it.
        guard view.qaV2RequestIDs == ["input-live"] else {
            throw fail("user input live check: the question block did not render (ids \(view.qaV2RequestIDs))")
        }
        guard canvas.agentStatus(for: tile.id) == .needsAttention else {
            throw fail("user input live check: canvas status did not become needsAttention")
        }
        guard canvas.attentionTileIds.contains(tile.id) else {
            throw fail("user input live check: canvas did not track the attention tile")
        }
        guard view.qaUserInputCardCount == 0 else {
            throw fail("user input live check: a legacy typed-answer card is reachable after the P5.5 removal")
        }

        view.ingest(.userInputResolved(threadId: "thread-main", requestId: "input-live"))
        guard view.qaV2RequestStatus("input-live") == .completed else {
            throw fail("user input live check: the question block did not turn passive on the runtime resolution")
        }
        let statusAfterResolution = canvas.agentStatus(for: tile.id)
        guard statusAfterResolution == .working else {
            throw fail("user input live check: status after resolution \(String(describing: statusAfterResolution)), expected working")
        }
    }
}
