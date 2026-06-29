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

    static func emptyStateActions() -> CanvasEmptyStateActions {
        CanvasEmptyStateActions(
            spawnClaude: {}, spawnShell: {}, spawnBrowser: {}, openInEditor: {},
            addProjectToCanvas: {},
            recentProjects: [.init(title: "continuum-revived", action: {}), .init(title: "dotfiles", action: {})]
        )
    }
}

// MARK: - Catalog

@MainActor
enum LabCatalog {
    static func entries(env: LabEnvironment) -> [LabEntry] {
        [sidebarCard, topBarCard, emptyStateCard]
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

    private static var emptyStateCard: LabEntry {
        LabEntry(
            id: "chrome.emptystate", category: "Chrome", title: "Canvas Empty State",
            summary: "Blank-canvas first run: wordmark, ⌘K hint, spawn actions, recents.",
            content: .staticCard(preferredSize: nil) {
                CanvasEmptyStateNSView(actions: LabFixtures.emptyStateActions(), projectPath: "~/code/continuum-revived")
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

        let manifest: [String: Any] = ["check": "component-lab", "entryCount": entries.count, "rendered": rendered]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
    }
}
