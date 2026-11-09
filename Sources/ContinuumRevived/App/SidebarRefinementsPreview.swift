import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Opt-in dev preview: production sidebar views, isolated sample rows, no runners
/// or project/store acquisition. Invoked only by ARRAY_SIDEBAR_PREVIEW=1.
@MainActor
final class SidebarRefinementsPreview: NSObject, NSApplicationDelegate {
    private static var retained: SidebarRefinementsPreview?
    private var windows: [NSWindow] = []
    private var inboxes: [AgentInboxView] = []
    private var rows = WorkspaceFilterSheet.rows()
    private var settingsWindow: NSWindow?
    private lazy var settingsModal = SettingsModal(model: SettingsModel(
        defaults: .standard, navKeymap: .resolve(defaults: .standard, warn: { _ in }),
        initialPaneID: "appearance"))

    static func run() {
        let app = NSApplication.shared
        let preview = SidebarRefinementsPreview()
        retained = preview
        app.delegate = preview
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let now = WorkspaceFilterSheet.now
        rows = SidebarPolishFixtures.rows(now: now)
        let activeLead = rows.first { $0.depth == 0 && $0.identityColor == "teal" }?.id
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Array Sidebar")
        let settingsItem = applicationMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit Array Sidebar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
        for (index, theme) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 380, height: 740))
            inbox.clock = { now }
            inbox.foldsUntouchedGroups = true
            if let activeLead {
                inbox.openAgentId = activeLead
                inbox.restoreParentFolds([activeLead: true])
            }
            inbox.onRevealRow = { [weak self] id in
                guard let self else { return }
                for sidebar in self.inboxes {
                    sidebar.openAgentId = id
                    sidebar.reload(rows: self.rows)
                }
            }
            inbox.workspaceColourNames = Dictionary(uniqueKeysWithValues:
                WorkspaceFilterSheet.workspaces.map { ($0.id, $0.colour) })
            inbox.scopeCatalog = WorkspaceFilterSheet.workspaces.map { .workspaceID($0.id, $0.name) }
            inbox.currentWorkspaceId = WorkspaceFilterSheet.array.id
            inbox.setScope(.all)
            inbox.wiredRowActions = [.snooze, .settle, .wake, .unsettle]
            inbox.onRowAction = { [weak self] action, ids in
                switch action {
                case .settle: self?.update(ids, lifecycle: .settled(at: now))
                case .wake, .unsettle: self?.update(ids, lifecycle: .active)
                default: break
                }
            }
            inbox.onSnoozeSelection = { [weak self] ids, until in
                self?.update(ids, lifecycle: .snoozed(until: until))
            }
            inbox.restoreShelfExpansion(snoozed: true, history: true)
            let window = NSWindow(contentRect: inbox.frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "Sidebar Preview — \(index == 0 ? "Light" : "Dark") · Sample rows"
            window.appearance = NSAppearance(named: theme)
            window.minSize = NSSize(width: 260, height: 400)
            window.contentView = inbox
            window.setFrameOrigin(NSPoint(x: screen.midX - 390 + CGFloat(index) * 400,
                                          y: max(screen.minY + 20, screen.midY - 380)))
            windows.append(window)
            inboxes.append(inbox)
            inbox.reload(rows: rows)
            window.makeKeyAndOrderFront(nil)
        }
        // Settle the real table viewport after both windows are exposed. The
        // first offscreen-sized pass can otherwise leave a stale row layer.
        for inbox in inboxes {
            inbox.layoutForQA()
            inbox.rebuildRowsForQA()
        }
        NSApp.activate(ignoringOtherApps: true)
        if let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] {
            let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                "treatment": "iconBadge", "windows": windows.count, "sampleRowsOnly": true]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted]) {
                try? data.write(to: URL(fileURLWithPath: support).appendingPathComponent("sidebar-preview.json"))
            }
        }
    }

    @objc private func openSettings(_ sender: Any?) {
        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 820),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Array Sidebar — Settings"
            window.minSize = NSSize(width: 700, height: 560)
            window.center()
            settingsWindow = window
            settingsModal.onClose = { [weak self] in self?.settingsWindow?.orderOut(nil) }
        }
        window.makeKeyAndOrderFront(nil)
        settingsModal.show(in: window, paneID: "appearance")
    }

    private func update(_ ids: [UUID], lifecycle: InboxLifecycle) {
        rows = rows.map { row in
            guard ids.contains(row.id) else { return row }
            return row.followingParent(lifecycle: lifecycle, closingSince: row.closingSince,
                workspaceName: row.workspaceName, workspaceId: row.workspaceId)
        }
        inboxes.forEach { $0.reload(rows: rows) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
