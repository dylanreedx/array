import AppKit
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
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func tile(kind: TileKind, title: String) -> Tile {
        Tile(
            id: UUID(),
            kind: kind,
            title: title,
            frame: TileFrame(x: 0, y: 0, width: 480, height: 320),
            zIndex: 1,
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
            zoneId: UUID(), name: "continuum-revived", color: "#5B8DEF", navKey: "1", collapsed: false, projectId: UUID(),
            agentStatusRollup: SidebarAgentStatusRollup(working: 1, needsAttention: 1),
            tiles: [
                SidebarTileRow(tileId: UUID(), title: "claude · feature/login", kind: .terminal, agentStatus: .working),
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
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor

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

    private func nextZ() -> Int { (canvas.canvasState.tiles.map(\.zIndex).max() ?? 0) + 1 }

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
        let tile = Tile(id: UUID(), kind: .note, title: "note \(spawnCount + 1)", frame: placement(for: .note), zIndex: nextZ(), runtimeRef: nil, metadata: TileMetadata(noteId: noteId))
        install(NoteTileNSView(tile: tile, noteId: noteId, initialBody: "# Note\n\nType here…"), for: tile)
    }

    func spawnFile() {
        let tile = Tile(id: UUID(), kind: .file, title: "README.md", frame: placement(for: .file), zIndex: nextZ(), runtimeRef: nil, metadata: TileMetadata(filePath: sampleFilePath))
        install(FileTileNSView(tile: tile), for: tile)
    }

    func spawnFileTree() {
        let id = UUID()
        let fileTreeTile = FileTreeTile(tileId: id, rootPath: tempDir.path, expandedPaths: [], selectedPath: nil, searchQuery: "", ignoredNames: [], gitBadges: .off)
        let tile = Tile(id: id, kind: .fileTree, title: "Files", frame: placement(for: .fileTree), zIndex: nextZ(), runtimeRef: nil, metadata: TileMetadata(filePath: tempDir.path))
        install(FileTreeTileNSView(tile: tile, fileTreeTile: fileTreeTile), for: tile)
    }

    func spawnRunArtifacts() {
        let tile = Tile(id: UUID(), kind: .runArtifacts, title: "Run Artifacts", frame: placement(for: .runArtifacts), zIndex: nextZ(), runtimeRef: nil, metadata: TileMetadata())
        install(RunArtifactsTileNSView(tile: tile), for: tile)
    }

    func spawnDescriptor() {
        let tile = Tile(id: UUID(), kind: .terminal, title: "placeholder", frame: placement(for: .terminal), zIndex: nextZ(), runtimeRef: nil, metadata: TileMetadata())
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
        [tileSandbox, sidebarCard, topBarCard]
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
        panel.title = "Component Lab"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = nil

        let root = NSView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 960, height: 640))
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityIdentifier(Self.rootAccessibilityIdentifier)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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
        }
    }

    private func clearCurrentContent() {
        teardown.forEach { $0() }
        teardown.removeAll()
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

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("component-lab", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var rendered: [[String: Any]] = []
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
            rendered.append(["entry": entry.id, "width": metrics.width, "height": metrics.height, "distinctColors": metrics.distinctSampledColors])
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

        let manifest: [String: Any] = [
            "check": "component-lab",
            "entryCount": entries.count,
            "rendered": rendered,
            "sandbox": ["tilesInstalled": 5, "zoomClampHigh": zoomHigh, "zoomClampLow": zoomLow]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
    }
}
