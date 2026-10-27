import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// `.plans/79` — `--external-sessions-sidebar-check [out.png]`. Sessions from
/// other apps are ordinary rows of the PRODUCTION sidebar.
///
/// Drives the boot mount (`WorkspaceAPIChecks.makeFixture`), installs the
/// sidebar the way boot does (`configureWorkspaceSidebar`), and publishes a
/// made-up discovery snapshot through the app's own monitor — the last step of
/// the production path, so no real process or session file is ever read. Then:
/// rows keyed by session, the where marker, what the default scope hides and
/// "This Mac" shows, no session twice, the hover buttons, the click's Watch
/// seam, and Copy through its real button: a managed Claude agent in the
/// session's project, its first turn forking the session, its tile in that
/// project's zone, the history it forked from rendered.
///
/// With a path argument it also writes the sidebar, "This Mac" scope with one
/// row hovered, as a PNG for review.
@MainActor
enum ExternalSessionsSidebarChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    static func run(pngPath: String?) throws -> String {
        let fixture = try WorkspaceAPIChecks.makeFixture()
        defer { fixture.tearDown() }
        let delegate = fixture.delegate
        let supervisor = delegate.qaAgentSupervisor
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        guard let claudeModel = AgentCatalogQAFixture.claude.seedModel else { throw Failure(message: "no claude fixture model") }
        let unpin = AgentCatalogQAFixture.pinAmbientSelection(harness: .claudeCode, model: claudeModel)
        defer { unpin() }
        let monitor = delegate.externalSessionMonitor
        try expect(!monitor.isStarted, "the monitor must be inert in a check until something drives it (hazard 6)")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 1240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 340, height: 1240))
        window.contentView = sidebar
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        let appSupport = fixture.tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        // Boot's managed-session sweep, without which the inbox publishes nothing.
        try delegate.reconciledManagedSessionSource.reconcile(
            registry: try RegistryStore(applicationSupportDirectory: appSupport).loadOrEmpty(),
            reason: .continuumRestarted, now: Date())
        delegate.qaInstallWorkspaceSidebar(sidebar)
        delegate.qaRefreshAgentSurfaces()
        let inbox = sidebar.inboxForQA
        inbox.pinScrollerStyleForQA()
        // Picked through the view, not the popup: a popup pick is persisted to
        // the standard defaults, which a check must not write.
        inbox.setScope(.currentWorkspace)
        inbox.layoutForQA()
        try expect(inbox.rowIdsForQA.contains(fixture.agentId.rawValue), "precondition: the fixture agent has a row")

        // The made-up Mac.
        let now = Date()
        let transcripts = fixture.tempRoot.appendingPathComponent("claude-projects", isDirectory: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        let forkedFrom = transcripts.appendingPathComponent("s-cmux.jsonl")
        try Data("""
        {"type":"user","uuid":"u1","sessionId":"s-cmux","message":{"role":"user","content":"Why is the upload test flaky?"}}
        {"type":"assistant","uuid":"a1","sessionId":"s-cmux","message":{"id":"m1","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"The retry races the timeout."}]}}

        """.utf8).write(to: forkedFrom)
        let scratch = fixture.tempRoot.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let agentTag = AgentProcessAttribution.ownerTag(for: fixture.agentId)
        func session(_ id: String, _ provider: ExternalSessionProvider = .claude, cwd: URL, title: String,
                     status: ExternalSessionStatus, host: ExternalSessionHost, ago: TimeInterval = 600,
                     transcript: URL? = nil, pid: Int32? = 4242) -> ExternalAgentSession {
            ExternalAgentSession(
                provider: provider, sessionId: id, pid: pid, cwd: cwd.path, title: title, status: status,
                startedAt: now.addingTimeInterval(-ago), statusSince: now.addingTimeInterval(-312),
                lastActivity: now.addingTimeInterval(-240), host: host,
                transcriptURL: transcript ?? transcripts.appendingPathComponent("\(id).jsonl"))
        }
        let cmux = session("s-cmux", cwd: fixture.pbRoot, title: "Fix flaky upload test", status: .busy,
                           host: .app("cmux"), ago: 900, transcript: forkedFrom)
        let shell = session("s-shell", cwd: fixture.paRoot, title: "Refactor token store", status: .waiting,
                            host: .arrayShellTile(tileId: nil), ago: 800)
        let desktop = session("s-desktop", cwd: fixture.paRoot, title: "LinkedIn post for launch day", status: .idle,
                              host: .app("Claude app"), ago: 700)
        let codexApp = session("t-app", .codex, cwd: fixture.paRoot, title: "Polish which-tab transition",
                               status: .unknown, host: .app("Codex app"), ago: 600, pid: nil)
        let ghostty = session("s-scratch", cwd: scratch, title: "Port scanner spike", status: .idle,
                              host: .app("Ghostty"), ago: 500)
        let referenceFolder = fixture.tempRoot.appendingPathComponent("roast-web", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceFolder, withIntermediateDirectories: true)
        let referenceTerminal = session("s-reference-terminal", cwd: referenceFolder,
            title: "Metadata reference", status: .idle, host: .app("Terminal"), ago: 450)
        let otherWorkspace = session("s-pc", cwd: fixture.pcRoot, title: "Bannockburn invoice export", status: .busy,
                                     host: .app("cmux"), ago: 400)
        // Array's own: a session the fixture agent's record names, and its tile's Terminal face.
        let owned = session(AgentSupervisor.claudeSessionId(for: fixture.agentId), cwd: fixture.pbRoot,
                            title: "owned", status: .busy, host: .app("cmux"))
        let face = session("s-face", cwd: fixture.pbRoot, title: "face", status: .busy,
                           host: .arrayTerminalFace(agentId: agentTag))
        monitor.publish(ExternalSessionSnapshot(sessions: [
            cmux, shell, desktop, codexApp, ghostty, otherWorkspace, referenceTerminal, owned, face,
        ]))
        inbox.layoutForQA()
        func rowId(_ session: ExternalAgentSession) -> UUID { ExternalSessionRows.rowId(forSessionKey: session.id) }

        // Workspace scope includes idle/unknown open sessions in its projects.
        let defaultIds = Set(inbox.rowIdsForQA)
        try expect(defaultIds.contains(rowId(cmux)) && defaultIds.contains(rowId(shell)),
                   "the default scope lists live and waiting sessions in this workspace's projects; got \(inbox.titlesForQA)")
        for idle in [desktop, codexApp] {
            try expect(defaultIds.contains(rowId(idle)),
                       "idle and unknown open sessions in this workspace must remain findable: \(idle.title ?? "")")
        }
        for quiet in [ghostty, otherWorkspace] {
            try expect(!defaultIds.contains(rowId(quiet)),
                       "the default scope hides '\(quiet.title ?? "")' (outside this workspace); got \(inbox.titlesForQA)")
        }
        try expect(inbox.row(forAgentId: rowId(cmux))?.state == .working, "a busy session is a Working row")
        guard let marker = inbox.whereMarkerForQA(id: rowId(cmux)) else {
            throw Failure(message: "the cmux row draws no where marker")
        }
        try expect(marker.text == "cmux" && marker.frame.minX >= marker.placementFrame.maxX
                   && abs(marker.frame.midY - marker.placementFrame.midY) < 3,
                   "the where marker reads 'cmux' after the project name, on its line; got \(marker)")
        try expect(inbox.whereMarkerForQA(id: fixture.agentId.rawValue)?.text == "Terminal",
                   "an Array agent whose tile shows the CLI is marked Terminal on its own row")
        try expect(inbox.scopeTitlesForQA.prefix(3) == ["This workspace", "All agents", "This Mac"],
                   "the scope menu offers This Mac after All agents; got \(inbox.scopeTitlesForQA)")

        // All agents is truly all, even idle and unregistered-folder sessions.
        inbox.setScope(.all)
        inbox.layoutForQA()
        for listed in [cmux, shell, desktop, codexApp, ghostty, otherWorkspace] {
            try expect(inbox.rowIdsForQA.contains(rowId(listed)), "All agents must include \(listed.title ?? "")")
        }
        inbox.setScope(.project(inbox.row(forAgentId: rowId(desktop))?.projectName ?? ""))
        inbox.layoutForQA()
        try expect(inbox.rowIdsForQA.contains(rowId(desktop)), "project scope must retain its idle external session")
        // This Mac: everything, each session once.
        inbox.setScope(.thisMac)
        inbox.layoutForQA()
        let macIds = inbox.rowIdsForQA
        for listed in [cmux, shell, desktop, codexApp, ghostty, otherWorkspace] {
            try expect(macIds.contains(rowId(listed)), "This Mac lists '\(listed.title ?? "")'; got \(inbox.titlesForQA)")
        }
        try expect(!macIds.contains(rowId(owned)) && !macIds.contains(rowId(face)),
                   "a session an Array agent owns is never a row of its own; got \(inbox.titlesForQA)")
        try expect(Set(macIds).count == macIds.count && macIds.filter { $0 == fixture.agentId.rawValue }.count == 1,
                   "one row per session and per agent; got \(inbox.titlesForQA)")
        try expect(inbox.row(forAgentId: rowId(ghostty))?.directoryName == "scratch",
                   "a folder that is not a project is labelled by its name")
        try expect(inbox.row(forAgentId: rowId(codexApp))?.whereMarker?.text == "Codex app · 4m ago",
                   "a Codex app thread reads 'Codex app · 4m ago'; got \(String(describing: inbox.row(forAgentId: rowId(codexApp))?.whereMarker))")

        // Hover: Move here, Copy and the hide ×, and no Copy for Codex.
        try expect(inbox.hoverRowForQA(id: rowId(cmux)), "the cmux row must be hoverable")
        inbox.layoutForQA()
        try expect(inbox.hoverActionsForQA(id: rowId(cmux))?.titles == ["Move here", "Copy", "Hide"],
                   "hovering a Claude session offers Move here, Copy and Hide; got \(String(describing: inbox.hoverActionsForQA(id: rowId(cmux))))")
        if let pngPath {
            try writePNG(of: sidebar, to: URL(fileURLWithPath: pngPath))
        }
        // A baseline-only/icon-to-icon witness passed while both glyphs sat below
        // the words. Measure ink painted by the production cells in both appearances.
        var metadataInkFailures: [String] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            inbox.layoutForQA()
            for session in [cmux, shell, desktop, codexApp, ghostty, otherWorkspace, referenceTerminal] {
                guard let ink = inbox.metadataInkGeometryForQA(id: rowId(session)),
                      let folder = ink["folder"], let project = ink["project"],
                      let origin = ink["origin"], let text = ink["originText"],
                      let cap = ink["opticalCentre"] else {
                    throw Failure(message: "missing native metadata ink for \(session.id)")
                }
                let folderDelta = folder.midY - cap.minY
                let originDelta = origin.midY - cap.minY
                print("metadata-ink \(appearance.rawValue) \(session.host): folder=\(folder) project=\(project) origin=\(origin) text=\(text) opticalY=\(cap.minY) deltas=\(folderDelta),\(originDelta)")
                if abs(folderDelta) > 0.5 || abs(originDelta) > 0.5
                    || abs(folder.midY - project.midY) > 1.5 || abs(origin.midY - text.midY) > 1.5 {
                    metadataInkFailures.append("\(appearance.rawValue) \(session.host): folder/optical \(folderDelta)pt, origin/optical \(originDelta)pt, folder/text \(folder.midY - project.midY)pt, origin/text \(origin.midY - text.midY)pt")
                }
            }
            if let pngPath {
                let base = URL(fileURLWithPath: pngPath).deletingPathExtension()
                try writePNG(of: sidebar, to: base.appendingPathExtension(appearance == .aqua ? "aqua.png" : "dark.png"))
            }
        }
        try expect(metadataInkFailures.isEmpty, "metadata visible ink misaligned: " + metadataInkFailures.joined(separator: "; "))

        for session in [cmux, shell, desktop, codexApp, ghostty, otherWorkspace] {
            guard let marker = inbox.whereMarkerForQA(id: rowId(session)) else {
                throw Failure(message: "missing metadata for \(session.title ?? session.id)")
            }
            try expect(abs(marker.iconInkCenterDelta) <= 0.5 && abs(marker.projectIconOpticalCenterDelta) <= 0.5,
                       "folder and host icons must align visually for \(marker.text); folder ink/optical-centre delta \(marker.projectIconOpticalCenterDelta)pt, icon ink center delta \(marker.iconInkCenterDelta)pt")
        }
        try expect(inbox.hoverRowForQA(id: rowId(codexApp)), "the Codex row must be hoverable")
        // Nor Move here: the Codex app runs every thread in one server, so a
        // thread's close cannot be seen, and Move here waits for exactly that.
        try expect(inbox.hoverActionsForQA(id: rowId(codexApp))?.titles ?? [] == ["Hide"],
                   "a Codex app thread offers neither Copy nor Move here, only Hide; got \(String(describing: inbox.hoverActionsForQA(id: rowId(codexApp))))")
        try expect(inbox.hoverRowForQA(id: fixture.agentId.rawValue)
                   && !(inbox.hoverActionsForQA(id: fixture.agentId.rawValue)?.titles.contains("Copy") ?? false),
                   "an Array agent's row never offers an external session's buttons")

        // A click is Watch, through the one seam (`--external-session-watch-check`
        // witnesses the tile). Ghostty's folder is not a project, so Watch asks
        // first (edge case 15), and Cancel opens nothing.
        delegate.externalSessionFolderChoiceForQA = { _ in false }
        let beforeWatch = supervisor.records.count
        try expect(inbox.clickRowForQA(id: rowId(ghostty)), "the Ghostty row must be clickable")
        try expect(delegate.qaExternalSessionSeams.last.map { $0.0 == .watch && $0.1 == ghostty.id } == true,
                   "clicking an external row reaches the Watch seam; got \(delegate.qaExternalSessionSeams)")
        try expect(supervisor.records.count == beforeWatch, "watching a folder that is not a project asks, and Cancel opens nothing")
        delegate.externalSessionFolderChoiceForQA = nil

        // Copy, through its real button.
        let before = Set(supervisor.records.keys)
        try expect(inbox.hoverRowForQA(id: rowId(cmux)), "the cmux row must be hoverable again")
        try expect(inbox.clickExternalActionForQA(id: rowId(cmux), .copy), "Copy must be pressable")
        let created = Set(supervisor.records.keys).subtracting(before)
        guard created.count == 1, let copyId = created.first, let copy = supervisor.records[copyId] else {
            throw Failure(message: "Copy must create exactly one agent; created \(created.count)")
        }
        try expect(copy.harness == .claudeCode && copy.pendingSessionForkFrom == cmux.sessionId,
                   "the copy is a Claude agent marked to fork the session; got \(String(describing: copy.harness)) / \(String(describing: copy.pendingSessionForkFrom))")
        let config = AgentSupervisor.claudeRunnerConfig(for: copy)
        try expect(config.sessionId == cmux.sessionId && config.forkSession && config.cwd.path == cmux.cwd,
                   "its first launch resumes and forks the session in the session's own folder; got \(config.sessionId) fork=\(config.forkSession) \(config.cwd.path)")
        try expect(copy.projectId == fixture.projectPb && copy.displayName == "Fix flaky upload test",
                   "the copy belongs to the session's project and carries its title")
        guard let tileId = copy.tileId else { throw Failure(message: "the copy must have a tile") }
        try expect(fixture.canvas.zoneId(containing: tileId) == fixture.zoneB,
                   "the copy's tile lands in the session's project's zone, not the armed one")
        try expect(fixture.canvas.tileView(for: tileId) is ManagedAgentTileNSView, "the copy's tile is a managed agent tile")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, supervisor.rehydratedTranscript(for: copyId) == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(supervisor.rehydratedTranscript(for: copyId)?.restoredMessageCount == 2,
                   "the copy shows the history it forked from; got \(String(describing: supervisor.rehydratedTranscript(for: copyId)?.restoredMessageCount))")
        delegate.qaRefreshAgentSurfaces()
        inbox.layoutForQA()
        try expect(inbox.rowIdsForQA.contains(rowId(cmux)) && inbox.rowIdsForQA.contains(copyId.rawValue),
                   "the original keeps running and keeps its row beside the copy; got \(inbox.titlesForQA)")

        // A folder that is not a project: Copy asks, and Cancel creates nothing.
        delegate.externalSessionFolderChoiceForQA = { _ in false }
        let beforeCancel = supervisor.records.count
        try expect(!delegate.performExternalSessionAction(.copy, rowId: rowId(ghostty)) && supervisor.records.count == beforeCancel,
                   "Copy of a session outside every project asks first, and Cancel creates nothing")
        var asked: String?
        delegate.externalSessionFolderChoiceForQA = { asked = $0.id; return true }
        try expect(delegate.performExternalSessionAction(.copy, rowId: rowId(ghostty)) && asked == ghostty.id,
                   "…and Add Folder makes it a project and copies into it")
        let registry = try RegistryStore(applicationSupportDirectory: appSupport).loadOrEmpty()
        try expect(registry.projects.contains { URL(fileURLWithPath: $0.rootPath).resolvingSymlinksInPath().path == scratch.resolvingSymlinksInPath().path },
                   "the folder is registered as a project")

        return "ExternalSessionsSidebarChecks: sessions from other apps are rows keyed by session, marked where they live, "
            + "idle sessions retained by location scopes, All agents and This Mac include all discovered sessions, never doubled; Copy forked one into its project"
            + (pngPath.map { " (png: \($0))" } ?? "")
    }

    private static func writePNG(of view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure(message: "could not snapshot the sidebar")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Failure(message: "could not encode the sidebar PNG")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
