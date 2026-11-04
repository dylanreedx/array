import AppKit
import ContinuumRevivedCore
import Foundation

/// `--subagent-sidebar-open-check` — clicking a subagent's row in the sidebar
/// always opens that subagent in a tile, whatever state its lead's tile is in,
/// and with no tmux anywhere on the path.
///
/// **The defect (0.7.40).** Under a managed lead, a tile-less subagent's row
/// click goes through `AgentSupervisor.popOut`, which refused — and the app then
/// showed the refusal and revealed the lead instead — in four states where the
/// lead was on the canvas:
///
/// - a NATIVE subagent (the harness's own `Agent` call, observed read-only):
///   `popOut` required a locally managed record ("This helper has no available
///   lead or canvas.");
/// - a lead LENT into a shared area: it is in no project layer, so the
///   beside-lead lookup found no zone ("Open the lead's workspace and tile…");
/// - a lead in ANOTHER WORKSPACE: same refusal, then a jump to the lead with no
///   helper tile;
/// - a helper in ANOTHER PROJECT than the zone its lead sits in: same refusal.
///
/// Drives production only: `mountWorkspaceSceneAtBoot` (via
/// `WorkspaceAPIChecks.makeFixture`), the sidebar `configureWorkspaceSidebar`
/// wires, and a real mouse click on the row through `NSApp.sendEvent` in an
/// offscreen window. Asserts the subagent's tile exists, is focused, and that
/// its WORLD frame is inside the zone it should be in (beside the lead where the
/// lead is in a project zone), never a zone stamp (hazard 9).
///
/// Each condition runs twice: tmux persistence off, and on with the only tmux
/// on PATH a shim that records any call and fails. The shim's log must stay
/// empty: opening a subagent must not need tmux. `TMUX_TMPDIR` points at a
/// disposable directory and `TMUX`/`TMUX_PANE` are unset, so nothing can reach
/// the default server.
@MainActor
enum SubagentSidebarOpenChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: "subagent-sidebar-open: " + message) }
    }

    enum LeadCondition: String, CaseIterable {
        case nativeSubagent = "native subagent, lead in its zone"
        case leadInSharedArea = "lead lent into a shared area"
        case leadInOtherWorkspace = "lead in another workspace"
        case helperInOtherProject = "helper's project differs from the lead's zone"
    }

    static func run() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(description: "subagent-sidebar-open requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("subagent-sidebar-open-\(UUID().uuidString)", isDirectory: true)
        let shimDir = scratch.appendingPathComponent("bin", isDirectory: true)
        let tmuxDir = scratch.appendingPathComponent("tmux", isDirectory: true)
        for dir in [shimDir, tmuxDir] { try fileManager.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? fileManager.removeItem(at: scratch) }

        // tmux isolation: a private namespace, no inherited client, and a shim as
        // the only tmux on PATH that records every call and fails.
        let shimLog = scratch.appendingPathComponent("tmux-calls.log")
        let shim = shimDir.appendingPathComponent("tmux")
        try "#!/bin/sh\necho \"$@\" >> '\(shimLog.path)'\nexit 1\n".write(to: shim, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        let originalPath = environment["PATH"] ?? "/usr/bin:/bin"
        let tmuxFree = originalPath.split(separator: ":").map(String.init).filter {
            !fileManager.isExecutableFile(atPath: ($0 as NSString).appendingPathComponent("tmux"))
        }
        setenv("PATH", ([shimDir.path] + tmuxFree).joined(separator: ":"), 1)
        setenv("TMUX_TMPDIR", tmuxDir.path, 1)
        unsetenv("TMUX")
        unsetenv("TMUX_PANE")
        defer { setenv("PATH", originalPath, 1) }

        var report: [String] = []
        var failures: [String] = []
        for tmuxPersistence in [false, true] {
            for condition in LeadCondition.allCases {
                let label = "\(condition.rawValue), tmux persistence \(tmuxPersistence ? "on (broken shim)" : "off")"
                do {
                    report.append(try scenario(condition, tmuxPersistence: tmuxPersistence, tmuxPath: shim.path, label: label))
                } catch {
                    failures.append("[\(label)] \(error)")
                }
            }
        }
        let tmuxCalls = (try? String(contentsOf: shimLog, encoding: .utf8)) ?? ""
        if !tmuxCalls.isEmpty { failures.append("opening a subagent called tmux: \(tmuxCalls)") }
        guard failures.isEmpty else {
            throw Failure(description: "\(failures.count) failing:\n  " + failures.joined(separator: "\n  "))
        }
        return report.joined(separator: "\n")
    }

    private static func scenario(_ condition: LeadCondition, tmuxPersistence: Bool, tmuxPath: String, label: String) throws -> String {
        AgentModelCatalog.shared.resetForQA(snapshot: .init(
            harness: .pi, readiness: .ready, models: [WorkspaceAgentReportChecks.model],
            displayNames: [WorkspaceAgentReportChecks.model: "Fixture"],
            contextWindows: [WorkspaceAgentReportChecks.model: 200_000]))
        guard let settings = QAIsolatedDefaults(isolatedSuiteName: "array.qa.subagent-sidebar-open.\(UUID().uuidString)") else {
            throw Failure(description: "no isolated defaults suite")
        }
        defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }
        settings.set(tmuxPersistence, forKey: TmuxPersistenceConfig.enabledKey)
        settings.set(tmuxPersistence ? tmuxPath : "", forKey: TmuxPersistenceConfig.pathKey)

        let f = try WorkspaceAPIChecks.makeFixture(settings: settings)
        defer { f.tearDown() }
        let delegate = f.delegate
        let supervisor = delegate.qaAgentSupervisor
        let lead = f.agentId
        try expect(supervisor.setMode(.managed, for: lead), "the lead would not go managed")

        // The subagent, through the supervisor's own entry points.
        let child: AgentID
        switch condition {
        case .nativeSubagent:
            guard let id = supervisor.handleSpawnRequest(SpawnRequest(
                role: nil, prompt: "Survey the ledger", isolated: false,
                sourceItemID: "toolu_\(UUID().uuidString.prefix(8))", observedOnly: true,
                displayLabel: "Native survey"), from: lead) else {
                throw Failure(description: "the native subagent was not adopted")
            }
            try expect(supervisor.records[id]?.capabilities == .observedReadOnly, "precondition: the native subagent is observed read-only")
            child = id
        case .helperInOtherProject:
            child = supervisor.spawn(role: nil, prompt: nil, cwd: f.paRoot, harness: .pi,
                                     model: WorkspaceAgentReportChecks.model, thinking: "high",
                                     projectId: f.projectPa, projectRoot: f.paRoot, parentAgentID: lead)
        default:
            child = supervisor.spawn(role: nil, prompt: nil, cwd: f.pbRoot, harness: .pi,
                                     model: WorkspaceAgentReportChecks.model, thinking: "high",
                                     projectId: f.projectPb, projectRoot: f.pbRoot, parentAgentID: lead)
        }
        try expect(supervisor.records[child]?.tileId == nil && supervisor.helperLead(for: child) == lead,
                   "precondition: a tile-less subagent of the managed lead")

        // The lead's state.
        switch condition {
        case .leadInSharedArea:
            _ = try f.runtime.createSharedZone(fromTiles: [f.agentTileB], areaId: UUID(), name: "Shared with a colleague")
            try expect(f.canvas.lentTileHomeZoneId(f.agentTileB) == f.zoneB && f.canvas.zoneId(containing: f.agentTileB) == nil,
                       "precondition: the lead is lent out of its zone")
        case .leadInOtherWorkspace:
            // The sidebar lists another workspace's agents under "All agents",
            // the person's persisted choice; the default shows this workspace.
            WorkspaceSidebarConfig.setScope(.all, defaults: settings)
            try f.runtime.switchWorkspace(to: f.workspaceWB)
            try expect(f.canvas.navigationTileSnapshot(for: f.agentTileB) == nil, "precondition: the lead is in another workspace")
        default:
            break
        }
        if condition != .leadInOtherWorkspace {
            try expect(f.canvas.navigationTileSnapshot(for: f.agentTileB) != nil, "precondition: the lead is on the canvas")
        }

        // The sidebar exactly as boot installs it, in an offscreen window. Boot
        // reconciles managed sessions before the sidebar may list anything.
        try delegate.reconciledManagedSessionSource.reconcile(
            registry: delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: WorkspaceSidebarConfig.defaultWidth, height: 900))
        delegate.qaInstallWorkspaceSidebar(sidebar)
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        delegate.qaRefreshAgentSurfaces()

        try click(row: child.rawValue, parent: lead.rawValue, in: sidebar, window: window, label: label)
        delegate.qaRefreshAgentSurfaces()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.agentInbox.layoutForQA()
        let poppedRow = sidebar.agentInbox.qaMaterializedRowCells.compactMap { $0 as? AgentInbox96CellView }
            .first { $0.qaAgentID == child.rawValue }
        try expect(poppedRow?.isSubagentRow == true,
                   "popped-out helper lost its normal one-line row (height \(poppedRow?.frame.height ?? -1))")

        guard let tile = supervisor.records[child]?.tileId else {
            throw Failure(description: "clicking the subagent's row opened no tile for it"
                + (delegate.qaWorkspaceManagementMessage.map { "; the app said \"\($0)\"" } ?? ""))
        }
        try expect(delegate.qaWorkspaceManagementMessage == nil,
                   "the click succeeded but still said \"\(delegate.qaWorkspaceManagementMessage ?? "")\"")
        try expect(f.canvas.tileRecord(for: tile)?.kind == .managedAgent, "the subagent's tile is not a managed agent tile on the canvas")
        try expect(delegate.qaFocusBroker.activeSurface == .tile(tile) || f.canvas.canvasState.lastActiveTileId == tile,
                   "the subagent's tile was not revealed (focus \(String(describing: delegate.qaFocusBroker.activeSurface)))")
        guard let snapshot = f.canvas.navigationTileSnapshot(for: tile) else {
            throw Failure(description: "the subagent's tile has no world frame")
        }
        let rect = CGRect(x: snapshot.worldFrame.x, y: snapshot.worldFrame.y,
                          width: snapshot.worldFrame.width, height: snapshot.worldFrame.height)
        func zoneRect(_ zoneId: UUID) throws -> CGRect {
            guard let zone = f.runtime.document.zones.first(where: { $0.zoneId == zoneId }) else {
                throw Failure(description: "no zone \(zoneId)")
            }
            return CGRect(x: zone.origin.x, y: zone.origin.y, width: zone.size.width, height: zone.size.height)
        }
        let expectedZone = condition == .helperInOtherProject ? f.zoneA : f.zoneB
        let expectedRect = try zoneRect(expectedZone)
        try expect(expectedRect.insetBy(dx: -1, dy: -1).contains(rect),
                   "the subagent's WORLD frame \(rect) is outside its zone \(expectedRect)")
        var where_ = "in its zone"
        if condition == .nativeSubagent || condition == .leadInOtherWorkspace {
            try expect(f.runtime.workspaceId == f.workspaceWA, "the subagent did not open in its lead's workspace")
            guard let leadFrame = f.canvas.navigationTileSnapshot(for: f.agentTileB)?.worldFrame else {
                throw Failure(description: "the lead left the canvas")
            }
            let leadRect = CGRect(x: leadFrame.x, y: leadFrame.y, width: leadFrame.width, height: leadFrame.height)
            // Beside, on whichever side the placement chose (auto layout fans
            // helpers out around the lead): not overlapping it, and close.
            let gapX = max(rect.minX - leadRect.maxX, leadRect.minX - rect.maxX)
            let gapY = max(rect.minY - leadRect.maxY, leadRect.minY - rect.maxY)
            try expect(!rect.intersects(leadRect) && max(gapX, gapY) >= 0 && max(gapX, gapY) <= 200,
                       "the subagent's WORLD frame \(rect) is not beside its lead \(leadRect)")
            where_ = "beside its lead"
        }
        // A scoped list may omit the lead. Keep the helper's normal typography
        // and pitch even when the sorter places it at the root of that list.
        if condition == .nativeSubagent && !tmuxPersistence {
            let inbox = sidebar.agentInbox
            let all = inbox.qaAllRowsForQA
            inbox.reload(rows: all.filter { $0.id == child.rawValue })
            inbox.layoutForQA()
            let scoped = inbox.qaMaterializedRowCells.compactMap { $0 as? AgentInbox96CellView }
                .first { $0.qaAgentID == child.rawValue }
            if let capture = ProcessInfo.processInfo.environment["CONTINUUM_QA_CAPTURE"] {
                let directory = URL(fileURLWithPath: capture)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    sidebar.appearance = NSAppearance(named: appearance)
                    try SidebarOwnershipChecks.write(sidebar, to: directory.appendingPathComponent("popped-helper-\(name).png"))
                }
            }
            try expect(scoped?.isSubagentRow == true
                       && (scoped?.frame.height ?? .infinity) < 40,
                       "scoped popped-out helper enlarged to lead styling (height \(scoped?.frame.height ?? -1))")
            inbox.reload(rows: all)
            inbox.layoutForQA()
        }
        // Positive control: the same click on the lead's row reaches the host.
        if condition == .nativeSubagent {
            try click(row: lead.rawValue, parent: nil, in: sidebar, window: window, label: label)
            try expect(delegate.qaFocusBroker.activeSurface == .tile(f.agentTileB) || f.canvas.canvasState.lastActiveTileId == f.agentTileB,
                       "positive control: clicking the lead's row did not reveal the lead")
        }
        return "  \(label): opened \(where_) at \(Int(rect.minX)),\(Int(rect.minY))"
    }

    /// A real click on the row's title, through the window: mouse-up queued
    /// first so the table's tracking loop ends, then mouse-down sent.
    private static func click(row id: UUID, parent: UUID?, in sidebar: WorkspaceSidebarView, window: NSWindow, label: String) throws {
        let inbox = sidebar.agentInbox
        func cell() -> AgentInbox96CellView? {
            sidebar.layoutSubtreeIfNeeded()
            inbox.layoutForQA()
            return inbox.qaMaterializedRowCells.compactMap { $0 as? AgentInbox96CellView }.first { $0.qaAgentID == id }
        }
        var target = cell()
        if target == nil, let parent {
            inbox.toggleCollapse(parentId: parent)
            target = cell()
        }
        guard let target else {
            throw Failure(description: "no sidebar row for \(id) (rows: \(inbox.qaMaterializedRowCells.compactMap(\.qaAgentID)))")
        }
        let title = target.qaTitleFrameForQA
        let point = target.convert(NSPoint(x: title.midX, y: title.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1) else { throw Failure(description: "could not synthesise \(type)") }
            return event
        }
        NSApp.postEvent(try mouse(.leftMouseUp), atStart: false)
        NSApp.sendEvent(try mouse(.leftMouseDown))
        while let pending = NSApp.nextEvent(matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(pending)
        }
    }
}
