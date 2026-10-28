import AppKit
import ContinuumRevivedAgentUI

/// Opt-in dev preview: production sidebar views, isolated sample rows, no runners
/// or project/store acquisition. Invoked only by ARRAY_SIDEBAR_PREVIEW=1.
@MainActor
final class SidebarRefinementsPreview: NSObject, NSApplicationDelegate {
    private static var retained: SidebarRefinementsPreview?
    private var windows: [NSWindow] = []
    private var inboxes: [AgentInboxView] = []
    private var rows = WorkspaceFilterSheet.rows()

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
        rows.append(AgentInboxRow(
            id: UUID(), title: "Plan richer file tile previews", projectName: "Array",
            workspaceName: "Array", workspaceId: WorkspaceFilterSheet.array.id,
            state: .ready, lifecycle: .settled(at: now.addingTimeInterval(-120)),
            createdAt: now.addingTimeInterval(-600), identityColor: "teal"))
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
        for (index, theme) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 380, height: 740))
            inbox.clock = { now }
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
        NSApp.activate(ignoringOtherApps: true)
        if let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] {
            let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                "treatment": "iconBadge", "windows": windows.count, "sampleRowsOnly": true]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted]) {
                try? data.write(to: URL(fileURLWithPath: support).appendingPathComponent("sidebar-preview.json"))
            }
        }
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
