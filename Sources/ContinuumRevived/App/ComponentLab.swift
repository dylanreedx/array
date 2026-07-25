import AppKit
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

            // MARK: night3-C cards
            managedAgentApprovalDockCard, managedAgentUserInputCard, newTileCwdPolicyCard,
            topologyMigrationNoteCard
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
            let row = NSStackView(views: [chip, NSView()])
            row.orientation = .horizontal
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
        func event(tileId: UUID, sequence: UInt64, status: AgentStatus, summary: String, offset: TimeInterval) -> AgentActivityEvent {
            AgentActivityEvent(
                stamping: AgentActivityEventDraft(
                    tileId: tileId,
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
            event(tileId: gamma, sequence: 1, status: .done, summary: "gamma finished cleanly", offset: 1),
            event(tileId: alpha, sequence: 2, status: .needsAttention, summary: "alpha needs approval", offset: 4),
            event(tileId: delta, sequence: 3, status: .working, summary: "delta is running checks", offset: 3),
            event(tileId: beta, sequence: 4, status: .needsAttention, summary: "beta needs input", offset: 2),
        ].reduce(ActivityLogSnapshot.empty) { apply($0, $1) }
        return AgentsBoardProjection.rows(from: snapshot)
    }

    static func approvalsInboxSnapshot() -> ActivityLogSnapshot {
        let replica = UUID(uuidString: "62000000-0000-4000-8000-0000000000CC")!
        let base = Date(timeIntervalSinceReferenceDate: 6_267)
        func event(tileId: UUID, sequence: UInt64, status: AgentStatus, summary: String, offset: TimeInterval, approvalRequestId: String? = nil) -> AgentActivityEvent {
            AgentActivityEvent(
                stamping: AgentActivityEventDraft(
                    tileId: tileId,
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
            event(tileId: working, sequence: 1, status: .working, summary: "gamma is running", offset: 1),
            event(tileId: withId, sequence: 2, status: .needsAttention, summary: "alpha approve deploy", offset: 3, approvalRequestId: "approval-alpha"),
            event(tileId: withoutId, sequence: 3, status: .needsAttention, summary: "beta legacy request", offset: 2),
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
            let target = snapshot.byTile[row.tileId].flatMap { AgentsBoardProjection.respondableRequest(in: $0) }
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

    private static var managedAgentApprovalDockCard: LabEntry {
        LabEntry(
            id: "managed-agent.approval-dock",
            category: "Managed Agent",
            title: "Approval dock - three states",
            summary: "Working, waiting with orange dock and border, then done.",
            content: .staticCard(preferredSize: NSSize(width: 560, height: 720)) {
                makeManagedAgentApprovalDockPreview()
            }
        )
    }

    private static var managedAgentUserInputCard: LabEntry {
        LabEntry(
            id: "managed-agent.user-input-card",
            category: "Managed Agent",
            title: "User Input Card",
            summary: "Inline answer-field card for user-input.requested events.",
            content: .staticCard(preferredSize: NSSize(width: 480, height: 160)) {
                let card = UserInputCardView(frame: NSRect(x: 0, y: 0, width: 480, height: 160))
                card.configure(question: "What should I name the new migration file?")
                return card
            }
        )
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
                frame: TileFrame(x: 0, y: 0, width: 520, height: 210),
                zPosition: .fromLegacyRank(1),
                runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed")
            )
            let view = ManagedAgentTileNSView(tile: tile)
            view.frame = NSRect(x: 0, y: 0, width: 520, height: 210)
            view.ingest(.sessionStateChanged(status == .done ? .stopped : .running))
            view.ingest(.turnStarted(threadId: "thread-main", turnId: "turn-\(status.rawValue)"))
            view.ingest(.contentDelta(threadId: "thread-main", turnId: "turn-\(status.rawValue)", streamKind: .assistant, delta: "Checking the auth change set."))
            if status == .done {
                view.ingest(.turnCompleted(threadId: "thread-main", turnId: "turn-\(status.rawValue)", outcome: .completed, errorMessage: nil))
            }
            if pending {
                view.setPendingApprovalForQA(kind: .commandExecutionApproval, requestId: "approval-preview", detail: "npm test")
            } else {
                view.agentStatus = status
            }
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 520).isActive = true
            view.heightAnchor.constraint(equalToConstant: 210).isActive = true
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
            .itemStarted(threadId: threadId, itemId: "cmd-1", kind: .commandExecution, title: "swift test"),
            .itemCompleted(threadId: threadId, itemId: "cmd-1", kind: .commandExecution, status: .completed),
            .itemStarted(threadId: threadId, itemId: "file-1", kind: .fileChange, title: "Sources/Auth.swift")
        ]
        if includeApproval {
            events.append(.requestOpened(threadId: threadId, requestId: "approval-1", kind: .commandExecutionApproval))
        }
        return events
    }

    static func makeManagedAgentFixtureView(includeApproval: Bool = true) -> ManagedAgentTileNSView {
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
        for event in managedAgentFixtureEvents(includeApproval: includeApproval) {
            view.ingest(event)
        }
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

    /// Renders every static card over an opaque dark backdrop and asserts each is
    /// non-blank — the Tier-1 visual gate (docs/26). An opaque backdrop means a
    /// non-rendering card collapses to one flat colour and is caught, while
    /// light-on-dark chrome stays legible.
    static func runSelfCheck() throws {
        func fail(_ message: String) -> Error {
            NSError(domain: "ComponentLab", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        _ = NSApplication.shared

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
                tileId: UUID(uuidString: "88000000-0000-4000-8000-0000000001\(String(format: "%02d", index))")!,
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
        guard entries.contains(where: { $0.id == "managed-agent.approval-dock" }) else {
            throw fail("missing managed-agent.approval-dock card")
        }
        guard entries.contains(where: { $0.id == "managed-agent.user-input-card" }) else {
            throw fail("missing managed-agent.user-input-card card")
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

        var rendered: [[String: Any]] = []
        var sidebarDistinctColors: Int?
        var selectedSidebarDistinctColors: Int?
        var managedAgentDistinctColors: Int?
        var approvalDockDistinctColors: Int?
        var userInputCardDistinctColors: Int?
        for entry in entries {
            guard case let .staticCard(preferredSize, make) = entry.content else { continue }
            let size = preferredSize ?? NSSize(width: 560, height: 640)
            let host = NSView(frame: NSRect(origin: .zero, size: size))
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            place(make(), in: host, preferredSize: preferredSize)
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw fail("\(entry.id): could not allocate bitmap")
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            let metrics = VisualSnapshot.metrics(of: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(entry.id).png"))
            guard !metrics.isBlank else {
                throw fail("\(entry.id): render is blank/uniform (\(metrics.distinctSampledColors) colors at \(metrics.width)x\(metrics.height))")
            }
            if entry.id == "chrome.sidebar" {
                sidebarDistinctColors = metrics.distinctSampledColors
            } else if entry.id == "chrome.sidebar.selected" {
                selectedSidebarDistinctColors = metrics.distinctSampledColors
            } else if entry.id == "tiles.managedAgent" {
                managedAgentDistinctColors = metrics.distinctSampledColors
            } else if entry.id == "managed-agent.approval-dock" {
                approvalDockDistinctColors = metrics.distinctSampledColors
            } else if entry.id == "managed-agent.user-input-card" {
                userInputCardDistinctColors = metrics.distinctSampledColors
            }
            rendered.append(["entry": entry.id, "width": metrics.width, "height": metrics.height, "distinctColors": metrics.distinctSampledColors])
        }
        guard let sidebarDistinctColors else {
            throw fail("missing chrome.sidebar render for selection delta gate")
        }
        guard let selectedSidebarDistinctColors else {
            throw fail("missing chrome.sidebar.selected render for selection delta gate")
        }
        guard selectedSidebarDistinctColors != sidebarDistinctColors else {
            throw fail("selected sidebar render should visibly differ; selected=\(selectedSidebarDistinctColors) unselected=\(sidebarDistinctColors)")
        }
        guard let managedAgentDistinctColors else {
            throw fail("missing tiles.managedAgent render")
        }
        guard let approvalDockDistinctColors, approvalDockDistinctColors >= 6 else {
            throw fail("managed-agent.approval-dock waiting-state render too flat: \(approvalDockDistinctColors ?? 0) colors")
        }
        guard let userInputCardDistinctColors, userInputCardDistinctColors >= 5 else {
            throw fail("managed-agent.user-input-card render too flat: \(userInputCardDistinctColors ?? 0) colors")
        }
        guard managedAgentDistinctColors >= 3 else {
            throw fail("managed agent render too uniform: \(managedAgentDistinctColors) distinct colors")
        }

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
            "sidebarSelection": [
                "unselectedDistinctColors": sidebarDistinctColors,
                "selectedDistinctColors": selectedSidebarDistinctColors,
                "delta": selectedSidebarDistinctColors - sidebarDistinctColors
            ],
            "userInputCard": [
                "distinctColors": userInputCardDistinctColors
            ]
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
        view.setPendingApprovalForQA(kind: .commandExecutionApproval, requestId: "approval-live", detail: "npm test")
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
        guard view.qaApprovalDockVisible else {
            throw fail("approval live check: approval dock is hidden")
        }
        guard view.qaApprovalDockDetailText.contains("Run command: npm test") else {
            throw fail("approval live check: dock detail rendered '\(view.qaApprovalDockDetailText)'")
        }
        guard view.qaApprovalDockButtonTitles == ["Approve", "Approve for session", "Decline"] else {
            throw fail("approval live check: dock buttons \(view.qaApprovalDockButtonTitles)")
        }

        view.qaClickApproval(.accept)
        guard canvas.agentStatus(for: tile.id) != AgentStatus.needsAttention else {
            throw fail("approval live check: status stayed needsAttention after approve")
        }
        guard canvas.attentionTileIds.isEmpty else {
            throw fail("approval live check: attention set not cleared after approve")
        }
        guard !canvas.qaAttentionBorderActive(for: tile.id) else {
            throw fail("approval live check: attention border stayed active after approve")
        }
        guard !view.qaApprovalDockVisible else {
            throw fail("approval live check: dock stayed visible after approve")
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
        var submitted: (requestId: String, answers: UserInputAnswers)?
        view.onUserInputSubmit = { requestId, answers in
            submitted = (requestId, answers)
        }
        canvas.install(tileView: view, for: tile)
        view.ingest(.sessionStateChanged(.running))
        view.ingest(.turnStarted(threadId: "thread-main", turnId: "turn-live-input"))
        view.ingest(.contentDelta(threadId: "thread-main", turnId: "turn-live-input", streamKind: .assistant, delta: "I need one naming decision."))
        view.ingest(.userInputRequested(threadId: "thread-main", requestId: "input-live", questions: [
            UserInputQuestion(key: "filename", prompt: "What should I name the new migration file?")
        ]))
        canvas.markActive(tileId: tile.id)

        guard view.qaPendingUserInputCount == 1 else {
            throw fail("user input live check: pending count \(view.qaPendingUserInputCount), expected 1")
        }
        guard canvas.agentStatus(for: tile.id) == .needsAttention else {
            throw fail("user input live check: canvas status did not become needsAttention")
        }
        guard canvas.attentionTileIds.contains(tile.id) else {
            throw fail("user input live check: canvas did not track the attention tile")
        }
        guard view.qaUserInputCardCount == 1 else {
            throw fail("user input live check: card count \(view.qaUserInputCardCount), expected 1")
        }
        guard view.qaUserInputQuestion(requestId: "input-live") == "What should I name the new migration file?" else {
            throw fail("user input live check: question text mismatch")
        }

        view.qaSubmitUserInput(requestId: "input-live", answer: "AddWorkspaceZoneMigration.swift")
        guard submitted?.requestId == "input-live" else {
            throw fail("user input live check: submit requestId \(submitted?.requestId ?? "nil")")
        }
        guard submitted?.answers.answers == ["response": "AddWorkspaceZoneMigration.swift"] else {
            throw fail("user input live check: submitted answers \(submitted?.answers.answers ?? [:])")
        }
        guard view.qaPendingUserInputCount == 0 else {
            throw fail("user input live check: pending count stayed \(view.qaPendingUserInputCount)")
        }
        guard view.qaUserInputCardCount == 0 else {
            throw fail("user input live check: card stayed visible after submit")
        }
        let statusAfterSubmit = canvas.agentStatus(for: tile.id)
        guard statusAfterSubmit == .working else {
            throw fail("user input live check: status after submit \(String(describing: statusAfterSubmit)), expected working")
        }
    }
}
