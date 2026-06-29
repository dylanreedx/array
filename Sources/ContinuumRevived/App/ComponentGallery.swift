import AppKit
import ContinuumRevivedCore
import Foundation

// A live, in-app catalog of the views used throughout Continuum — the native
// equivalent of Storybook. Stories render the *real* AppKit views (not mockups)
// from fixtures, so the gallery doubles as a polish surface: open it, see every
// component and its states side by side, and tweak the source to iterate.
//
// Adding a component = appending one `GalleryStory` to `GalleryCatalog.stories`.

/// A single rendered story instance plus an optional teardown hook. Live stories
/// (e.g. a real terminal) use `onRemove` to release runtimes / kill processes
/// when the variant is switched away or the gallery closes — no orphan shells.
@MainActor
struct GalleryRendered {
    let view: NSView
    let onRemove: (() -> Void)?

    init(_ view: NSView, onRemove: (() -> Void)? = nil) {
        self.view = view
        self.onRemove = onRemove
    }
}

/// One state of a component (e.g. TopBar "Save failed", Badge "working").
@MainActor
struct GalleryVariant {
    let name: String
    /// Fixed render size, centered in the host. `nil` pins the view to fill the
    /// host (for width-hungry chrome like the top bar / empty state).
    let preferredSize: NSSize?
    let make: () -> GalleryRendered

    init(_ name: String, preferredSize: NSSize? = nil, make: @escaping () -> GalleryRendered) {
        self.name = name
        self.preferredSize = preferredSize
        self.make = make
    }
}

/// A component entry: one or more variants under a category.
@MainActor
struct GalleryStory {
    let id: String
    let category: String
    let title: String
    let summary: String
    let variants: [GalleryVariant]
}

// MARK: - Fixtures

/// Canned model objects so stories render with realistic data and zero app state.
@MainActor
enum GalleryFixtures {
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

    static func topBarModel(
        save: WorkspaceDocumentSaveState,
        message: String? = nil,
        multiWorkspace: Bool = true
    ) -> WorkspaceTopBarModel {
        WorkspaceTopBarModel(
            currentWorkspaceId: workspaceId,
            currentWorkspaceName: "Continuum",
            projectCount: 2,
            zoneCount: 3,
            saveState: save,
            workspaces: multiWorkspace ? workspaceEntries() : [workspaceEntries()[0]],
            managementMessage: message
        )
    }

    static func shellProfile() -> LaunchProfile {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        return LaunchProfile(command: shell, arguments: [], cwd: NSTemporaryDirectory(), title: "Shell")
    }
}

// MARK: - Catalog

@MainActor
enum GalleryCatalog {
    /// All stories. `ghostty` enables the live-terminal story when available.
    static func stories(ghostty: GhosttyRuntimeContext?) -> [GalleryStory] {
        var stories: [GalleryStory] = [
            topBarStory,
            emptyStateStory,
            tileChromeStory,
            resizeHUDStory
        ]
        if let ghostty {
            stories.append(liveTerminalStory(ghostty: ghostty))
        }
        return stories
    }

    private static var topBarStory: GalleryStory {
        func make(_ model: WorkspaceTopBarModel) -> GalleryRendered {
            let view = WorkspaceTopBarView(frame: NSRect(x: 0, y: 0, width: 720, height: 44))
            view.reload(model)
            return GalleryRendered(view)
        }
        let size = NSSize(width: 720, height: 44)
        return GalleryStory(
            id: "chrome.topbar",
            category: "Chrome",
            title: "Workspace Top Bar",
            summary: "Identity + workspace switcher. Save-state colour and management message vary.",
            variants: [
                GalleryVariant("Saved", preferredSize: size) { make(GalleryFixtures.topBarModel(save: .saved)) },
                GalleryVariant("Saving", preferredSize: size) { make(GalleryFixtures.topBarModel(save: .saving)) },
                GalleryVariant("Unsaved", preferredSize: size) { make(GalleryFixtures.topBarModel(save: .unsavedChanges)) },
                GalleryVariant("Save failed", preferredSize: size) { make(GalleryFixtures.topBarModel(save: .saveFailed)) },
                GalleryVariant("With message", preferredSize: size) { make(GalleryFixtures.topBarModel(save: .unsavedChanges, message: "Renaming workspace…")) },
                GalleryVariant("Single workspace", preferredSize: size) { make(GalleryFixtures.topBarModel(save: .saved, multiWorkspace: false)) }
            ]
        )
    }

    private static var emptyStateStory: GalleryStory {
        func actions(recents: [String]) -> CanvasEmptyStateActions {
            CanvasEmptyStateActions(
                spawnClaude: {}, spawnShell: {}, spawnBrowser: {}, openInEditor: {},
                addProjectToCanvas: recents.isEmpty ? nil : {},
                recentProjects: recents.map { title in .init(title: title, action: {}) }
            )
        }
        return GalleryStory(
            id: "chrome.emptystate",
            category: "Chrome",
            title: "Canvas Empty State",
            summary: "The blank-canvas first run: wordmark, palette hint, spawn actions, recents.",
            variants: [
                GalleryVariant("With project") { GalleryRendered(CanvasEmptyStateNSView(actions: actions(recents: []), projectPath: "~/Documents/personal/continuum-revived")) },
                GalleryVariant("No project") { GalleryRendered(CanvasEmptyStateNSView(actions: actions(recents: []), projectPath: nil)) },
                GalleryVariant("With recents") { GalleryRendered(CanvasEmptyStateNSView(actions: actions(recents: ["continuum-revived", "dotfiles", "api"]), projectPath: "~/code/api")) }
            ]
        )
    }

    private static var tileChromeStory: GalleryStory {
        func make(_ status: AgentStatus?) -> GalleryRendered {
            let view = TileNSView(tile: GalleryFixtures.tile(kind: .terminal, title: "claude · feature/login"))
            view.agentStatus = status
            return GalleryRendered(view)
        }
        let size = NSSize(width: 420, height: 260)
        return GalleryStory(
            id: "tile.chrome",
            category: "Tiles",
            title: "Tile Chrome + Agent Badge",
            summary: "Title bar, close affordance, and the agent-status badge across every state.",
            variants: [
                GalleryVariant("No agent", preferredSize: size) { make(nil) },
                GalleryVariant("Configuring", preferredSize: size) { make(.configuring) },
                GalleryVariant("Working", preferredSize: size) { make(.working) },
                GalleryVariant("Idle", preferredSize: size) { make(.idle) },
                GalleryVariant("Needs attention", preferredSize: size) { make(.needsAttention) },
                GalleryVariant("Done", preferredSize: size) { make(.done) },
                GalleryVariant("Stale", preferredSize: size) { make(.stale) }
            ]
        )
    }

    private static var resizeHUDStory: GalleryStory {
        func make(width: Int, height: Int) -> GalleryRendered {
            let view = ResizeDimensionsOverlayView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
            view.showDimensions(widthPx: width, heightPx: height, atOverlayPoint: CGPoint(x: 150, y: 80))
            return GalleryRendered(view)
        }
        let size = NSSize(width: 300, height: 160)
        return GalleryStory(
            id: "overlay.resizehud",
            category: "Overlays",
            title: "Resize Dimensions HUD",
            summary: "The pixel-dimension pill shown while dragging a tile's resize handle.",
            variants: [
                GalleryVariant("Small", preferredSize: size) { make(width: 480, height: 320) },
                GalleryVariant("Wide", preferredSize: size) { make(width: 1280, height: 400) }
            ]
        )
    }

    private static func liveTerminalStory(ghostty: GhosttyRuntimeContext) -> GalleryStory {
        func make() -> GalleryRendered {
            let tile = GalleryFixtures.tile(kind: .terminal, title: "Shell")
            let runtime = GhosttyTerminalRuntime(
                id: UUID(),
                tileId: tile.id,
                title: "Shell",
                launchProfile: GalleryFixtures.shellProfile(),
                ghostty: ghostty,
                displayDefaults: .standard
            )
            let view = TerminalTileNSView(tile: tile, runtime: runtime)
            return GalleryRendered(view, onRemove: { runtime.terminate(policy: .force) })
        }
        return GalleryStory(
            id: "live.terminal",
            category: "Live / Embedded",
            title: "Terminal Tile (live)",
            summary: "A real Ghostty terminal on a sandboxed shell — fully interactive. Proves the embedded-flow path end to end.",
            variants: [
                GalleryVariant("Sandboxed shell", preferredSize: NSSize(width: 600, height: 380)) { make() }
            ]
        )
    }
}

// MARK: - Panel

/// Three-pane gallery window: story list · live render · variant controls.
@MainActor
final class ComponentGalleryPanel: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let rootAccessibilityIdentifier = "ContinuumComponentGalleryRoot"

    var onClose: (() -> Void)?

    private let ghostty: GhosttyRuntimeContext?
    private var panel: NSPanel?
    private var outline: NSOutlineView?
    private var hostView: NSView?
    private var controlsStack: NSStackView?
    private var previousKeyWindow: NSWindow?

    private var categories: [String] = []
    private var storiesByCategory: [String: [GalleryStory]] = [:]
    private var selectedStory: GalleryStory?
    private var currentTeardown: (() -> Void)?

    init(ghostty: GhosttyRuntimeContext?) {
        self.ghostty = ghostty
        super.init()
        rebuildCatalog()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func rebuildCatalog() {
        let stories = GalleryCatalog.stories(ghostty: ghostty)
        var order: [String] = []
        var grouped: [String: [GalleryStory]] = [:]
        for story in stories {
            if grouped[story.category] == nil { order.append(story.category) }
            grouped[story.category, default: []].append(story)
        }
        categories = order
        storiesByCategory = grouped
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
        if selectedStory == nil, let first = storiesByCategory[categories.first ?? ""]?.first {
            selectStory(first)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        clearCurrentRender()
        panel?.orderOut(nil)
        let restoreTarget = previousKeyWindow
        outline?.dataSource = nil
        outline?.delegate = nil
        panel = nil
        outline = nil
        hostView = nil
        controlsStack = nil
        selectedStory = nil
        previousKeyWindow = nil
        restoreTarget?.makeKeyAndOrderFront(nil)
        onClose?()
    }

    // MARK: Construction

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Component Gallery"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.delegate = nil

        let root = NSView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 960, height: 620))
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityIdentifier(Self.rootAccessibilityIdentifier)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.contentView = root

        // Left — story list grouped by category.
        let outlineScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: root.bounds.height))
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
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("story"))
        column.width = 200
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        outlineScroll.documentView = outline
        root.addSubview(outlineScroll)
        self.outline = outline

        // Right — variant controls.
        let controlsWidth: CGFloat = 220
        let controlsScroll = NSScrollView(frame: NSRect(x: root.bounds.width - controlsWidth, y: 0, width: controlsWidth, height: root.bounds.height))
        controlsScroll.autoresizingMask = [.height, .minXMargin]
        controlsScroll.hasVerticalScroller = true
        controlsScroll.drawsBackground = false
        controlsScroll.borderType = .noBorder
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        controls.translatesAutoresizingMaskIntoConstraints = false
        let controlsClip = FlippedView()
        controlsClip.translatesAutoresizingMaskIntoConstraints = false
        controlsClip.addSubview(controls)
        controlsScroll.documentView = controlsClip
        NSLayoutConstraint.activate([
            controlsClip.widthAnchor.constraint(equalTo: controlsScroll.widthAnchor),
            controls.topAnchor.constraint(equalTo: controlsClip.topAnchor),
            controls.leadingAnchor.constraint(equalTo: controlsClip.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: controlsClip.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: controlsClip.bottomAnchor)
        ])
        root.addSubview(controlsScroll)
        self.controlsStack = controls

        // Center — checkerboard host that renders the selected variant.
        let host = CheckerboardView(frame: NSRect(x: 220, y: 0, width: root.bounds.width - 220 - controlsWidth, height: root.bounds.height))
        host.autoresizingMask = [.width, .height]
        host.setAccessibilityIdentifier("ContinuumComponentGalleryHost")
        root.addSubview(host)
        self.hostView = host

        self.panel = panel
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        return panel
    }

    // MARK: Selection + rendering

    private func selectStory(_ story: GalleryStory) {
        selectedStory = story
        renderVariant(story.variants.first, of: story)
        rebuildControls(for: story, selectedIndex: 0)
    }

    private func renderVariant(_ variant: GalleryVariant?, of story: GalleryStory) {
        guard let host = hostView, let variant else { return }
        clearCurrentRender()
        let rendered = variant.make()
        currentTeardown = rendered.onRemove
        Self.place(rendered.view, in: host, preferredSize: variant.preferredSize)
    }

    /// Shared placement so the self-check captures components exactly as the panel
    /// displays them: fixed-size variants centered, others pinned to fill.
    private static func place(_ view: NSView, in host: NSView, preferredSize: NSSize?) {
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

    private func clearCurrentRender() {
        currentTeardown?()
        currentTeardown = nil
        hostView?.subviews.forEach { $0.removeFromSuperview() }
    }

    // MARK: QA / self-check

    /// Flat list of stories in display order.
    func qaStories() -> [GalleryStory] { categories.flatMap { storiesByCategory[$0] ?? [] } }

    /// Renders every chrome story+variant onto an opaque dark backdrop (the app's
    /// canvas context) and asserts each is non-blank — the Tier-1 visual gate
    /// (docs/26). An opaque backdrop means a non-rendering component collapses to
    /// one flat colour and is caught, while light-on-dark chrome stays legible.
    /// Live/Ghostty stories are excluded (ghostty: nil) — GPU surfaces don't
    /// composite through cacheDisplay.
    static func runSelfCheck() throws {
        _ = NSApplication.shared

        // Exercise the panel's catalog + plumbing the way the menu action does.
        let panel = ComponentGalleryPanel(ghostty: nil)
        panel.show(near: nil)
        let stories = panel.qaStories()
        panel.close()
        guard !stories.isEmpty else { throw SelfCheckError("component gallery catalog is empty") }

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("component-gallery", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var rendered: [[String: Any]] = []
        for story in stories {
            for variant in story.variants {
                let size = variant.preferredSize ?? NSSize(width: 560, height: 720)
                let host = NSView(frame: NSRect(origin: .zero, size: size))
                host.wantsLayer = true
                host.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host

                let result = variant.make()
                place(result.view, in: host, preferredSize: variant.preferredSize)
                host.layoutSubtreeIfNeeded()

                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    result.onRemove?()
                    throw SelfCheckError("\(story.id) / \(variant.name): could not allocate bitmap")
                }
                host.cacheDisplay(in: host.bounds, to: rep)
                let metrics = VisualSnapshot.metrics(of: rep)
                result.onRemove?()

                let slug = "\(story.id).\(variant.name)".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
                try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(slug).png"))
                guard !metrics.isBlank else {
                    throw SelfCheckError("\(story.id) / \(variant.name): render is blank/uniform (\(metrics.distinctSampledColors) colors at \(metrics.width)x\(metrics.height))")
                }
                rendered.append([
                    "story": story.id,
                    "variant": variant.name,
                    "width": metrics.width,
                    "height": metrics.height,
                    "distinctColors": metrics.distinctSampledColors
                ])
            }
        }

        let manifest: [String: Any] = [
            "check": "component-gallery",
            "storyCount": stories.count,
            "variantCount": rendered.count,
            "rendered": rendered
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
    }

    private struct SelfCheckError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    private func rebuildControls(for story: GalleryStory, selectedIndex: Int) {
        guard let controls = controlsStack else { return }
        controls.arrangedSubviews.forEach {
            controls.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let title = NSTextField(labelWithString: story.title)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        controls.addArrangedSubview(title)

        let summary = NSTextField(wrappingLabelWithString: story.summary)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.preferredMaxLayoutWidth = 192
        controls.addArrangedSubview(summary)

        let heading = NSTextField(labelWithString: "Variants")
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        controls.addArrangedSubview(heading)

        for (index, variant) in story.variants.enumerated() {
            let radio = NSButton(radioButtonWithTitle: variant.name, target: self, action: #selector(variantClicked(_:)))
            radio.tag = index
            radio.state = index == selectedIndex ? .on : .off
            controls.addArrangedSubview(radio)
        }
    }

    @objc private func variantClicked(_ sender: NSButton) {
        guard let story = selectedStory, story.variants.indices.contains(sender.tag) else { return }
        renderVariant(story.variants[sender.tag], of: story)
    }

    // MARK: NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return categories.count }
        if let category = item as? String { return storiesByCategory[category]?.count ?? 0 }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return categories[index] }
        let category = item as! String
        return storiesByCategory[category]![index]
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
        } else if let story = item as? GalleryStory {
            cell.stringValue = story.title
            cell.font = .systemFont(ofSize: 12)
            cell.textColor = .labelColor
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is GalleryStory
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outline, let story = outline.item(atRow: outline.selectedRow) as? GalleryStory else { return }
        selectStory(story)
    }
}

/// Flipped container so the controls stack lays out top-down in a scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Neutral checkerboard backdrop so transparent components are legible.
private final class CheckerboardView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()
        let tile: CGFloat = 16
        NSColor(white: 0.16, alpha: 1).setFill()
        var row = 0
        var y: CGFloat = 0
        while y < bounds.height {
            var x: CGFloat = (row % 2 == 0) ? 0 : tile
            while x < bounds.width {
                NSRect(x: x, y: y, width: tile, height: tile).fill()
                x += tile * 2
            }
            y += tile
            row += 1
        }
    }
}
