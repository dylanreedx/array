import AppKit
import ContinuumRevivedCore
import Foundation

/// `agent.update` with `displayName`, through the production boot mount and
/// dispatch, with real supervisor persistence, a real tile and the production
/// sidebar. The rule under test: a PROACTIVE rename never replaces a name
/// somebody chose (the user's, or one set on request); a REQUESTED one may.
@MainActor
enum WorkspaceAPIAgentRenameChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }
    private static func result(_ reply: WorkspaceAPIService.Reply) throws -> [String: AnyHashableJSON] {
        guard case let .result(value) = reply else { throw Failure(description: "expected result, got \(reply)") }
        return value
    }
    private static func error(_ reply: WorkspaceAPIService.Reply, _ code: WorkspaceAPIError.Code) throws {
        guard case let .error(value) = reply, value.code == code else {
            throw Failure(description: "expected \(code), got \(reply)")
        }
    }
    private static func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    static func run() throws {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(description: "agent-rename API check requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        let f = try WorkspaceAPIChecks.makeFixture()
        defer { f.tearDown() }
        let supervisor = f.delegate.qaAgentSupervisor
        supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        var serial = 0
        func payload(_ target: AgentID, _ name: Any?, _ intent: Any?, key: String?) -> [String: Any] {
            var payload: [String: Any] = ["agentId": target.rawValue.uuidString]
            if let name { payload["displayName"] = name }
            if let intent { payload["nameIntent"] = intent }
            if let key { payload["idempotencyKey"] = key }
            return payload
        }
        func rename(_ target: AgentID, _ name: Any?, _ intent: Any?, caller: AgentID? = nil, key: String? = nil) -> WorkspaceAPIService.Reply {
            serial += 1
            return f.api.dispatch(agentId: caller ?? f.agentId, requestId: "rename-\(serial)", op: "agent.update",
                                  payload: payload(target, name, intent, key: key))
        }
        func context(_ caller: AgentID) throws -> [String: AnyHashableJSON] {
            serial += 1
            return try result(f.api.dispatch(agentId: caller, requestId: "rename-context-\(serial)", op: "workspace.context", payload: [:]))
        }
        let store = AgentStore()
        func stored(_ id: AgentID) throws -> (String, AgentDisplayNameSource)? {
            try store.load(id: id).map { ($0.displayName, $0.displayNameSource) }
        }

        // The production sidebar, installed as boot does; rows rebuild from the
        // record through the supervisor's rename hook.
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: WorkspaceSidebarConfig.defaultWidth, height: 2000))
        // Boot's managed-session sweep, without which the inbox publishes nothing.
        try f.delegate.reconciledManagedSessionSource.reconcile(
            registry: try RegistryStore(applicationSupportDirectory: f.tempRoot.appendingPathComponent("AppSupport", isDirectory: true)).loadOrEmpty(),
            reason: .continuumRestarted, now: Date())
        f.delegate.qaInstallWorkspaceSidebar(sidebar)
        f.delegate.qaRefreshAgentSurfaces()
        let inbox = sidebar.inboxForQA
        func rowTitle(_ id: AgentID) -> String? { inbox.pushedRowForQA(id: id.rawValue)?.title }
        // A real agent tile following the caller's record.
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "Rename witness",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 420), zPosition: .first,
            runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        tile.attach(agentID: f.agentId, supervisor: supervisor)
        let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tile
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        func tileTitle() -> String? { tile.chromeSnapshot?.title }
        let armed = f.canvas.armedZoneId
        let viewport = f.canvas.viewport
        let focus = f.focusBroker.activeSurface
        let generation = f.runtime.interactionGeneration
        let tiles = f.canvas.allWorkspaceTiles()
        let revision = f.runtime.structuralRevision

        // 1. The caller can see its own name and where it came from.
        let opening = try context(f.agentId)
        try expect(opening["nameSource"]?.string == "automatic" && opening["displayName"]?.string == supervisor.records[f.agentId]?.humanDisplayName,
                   "context must report the caller's automatic name, got \(String(describing: opening["displayName"])) / \(String(describing: opening["nameSource"]))")

        // 2. A proactive self-rename over an automatic name: no prompt, committed,
        //    persisted, and on the tile and the sidebar row.
        let first = try result(rename(f.agentId, "Fix parser tests", "proactive", key: "self-1"))
        try expect(first["durability"]?.string == "committed" && first["displayName"]?.string == "Fix parser tests"
                   && first["nameSource"]?.string == "agent", "self proactive rename must commit as agent, got \(first)")
        try expect(f.api.approvalPromptCount == 0, "self rename needs no prompt")
        try expect(supervisor.records[f.agentId]?.identityColor == nil && first["identityColor"] != nil,
                   "a name-only update leaves the colour alone and still reports it")
        try expect(try stored(f.agentId).map { $0 == ("Fix parser tests", .agent) } == true, "agent-set name survives a store reload")
        spin(0.3) { rowTitle(f.agentId) == "Fix parser tests" }
        try expect(rowTitle(f.agentId) == "Fix parser tests", "sidebar row shows the API name, got \(String(describing: rowTitle(f.agentId)))")
        try expect(tileTitle() == "Agent · Fix parser tests", "tile title shows the API name, got \(String(describing: tileTitle()))")
        try expect(try result(rename(f.agentId, "Fix parser tests", "proactive", key: "self-1")) == first, "same-key replay returns the original outcome")
        try error(rename(f.agentId, "Something else", "proactive", key: "self-1"), .idempotencyConflict)
        try expect(try result(rename(f.agentId, "Fix parser tests", "proactive"))["durability"]?.string == "unchanged", "same name is unchanged")
        try expect(try context(f.agentId)["nameSource"]?.string == "agent", "context reports the agent source")
        // An agent's own earlier choice is not protected from its next one.
        _ = try result(rename(f.agentId, "Parser tests green", "proactive"))

        // 3. A person renames it (the sidebar's and the tile's path). Proactive is
        //    then refused and changes nothing; a request may still rename it.
        try expect(supervisor.rename(agentID: f.agentId, to: "Dylan's title"), "user rename")
        try expect(try context(f.agentId)["nameSource"]?.string == "user", "context reports the user source")
        try error(rename(f.agentId, "Agent knows better", "proactive"), .targetConflict)
        try expect(supervisor.records[f.agentId]?.displayName == "Dylan's title"
                   && (try stored(f.agentId)).map { $0 == ("Dylan's title", .manual) } == true, "refused proactive rename changes nothing")
        let requested = try result(rename(f.agentId, "Requested title", "requested"))
        try expect(requested["nameSource"]?.string == "requested" && requested["durability"]?.string == "committed",
                   "a requested rename replaces a user name, got \(requested)")
        try error(rename(f.agentId, "Drift", "proactive"), .targetConflict)
        try expect(supervisor.records[f.agentId]?.displayName == "Requested title", "proactive may not replace a requested name either")
        spin(0.3) { rowTitle(f.agentId) == "Requested title" }
        try expect(rowTitle(f.agentId) == "Requested title" && tileTitle() == "Agent · Requested title",
                   "row and tile follow a requested rename: \(String(describing: rowTitle(f.agentId))) / \(String(describing: tileTitle()))")

        // 4. Refusals change nothing.
        let invalid: [(Any?, Any?)] = [("", "requested"), ("   \n ", "requested"), ("Name", nil), ("Name", "maybe"),
                                       (nil, "requested"), (42, "requested"), (f.agentId.rawValue.uuidString, "requested")]
        for (name, intent) in invalid { try error(rename(f.agentId, name, intent), .invalidRequest) }
        try error(f.api.dispatch(agentId: f.agentId, requestId: "rename-empty", op: "agent.update",
                                 payload: ["agentId": f.agentId.rawValue.uuidString]), .invalidRequest)
        try expect(supervisor.records[f.agentId]?.displayName == "Requested title", "invalid requests change nothing")

        // 5. Colour and name together.
        let both = try result(f.api.dispatch(agentId: f.agentId, requestId: "rename-both", op: "agent.update", payload: [
            "agentId": f.agentId.rawValue.uuidString, "identityColor": "blue",
            "displayName": "Blue and named", "nameIntent": "requested"]))
        try expect(both["identityColor"]?.string == "blue" && both["displayName"]?.string == "Blue and named",
                   "one update sets colour and name, got \(both)")

        // 6. Another agent: the canvas-write grant, as for colour. A proactive
        //    rename of a user-named agent is refused before anyone is asked.
        let sibling = supervisor.spawn(role: nil, prompt: nil, cwd: f.pbRoot, harness: .pi,
            model: "fixture/rename", thinking: "high", projectId: f.projectPb, projectRoot: f.pbRoot)
        let foreign = supervisor.spawn(role: nil, prompt: nil, cwd: f.paRoot, harness: .pi,
            model: "fixture/rename", thinking: "high", projectId: f.projectPa, projectRoot: f.paRoot)
        let siblingName = supervisor.records[sibling]?.displayName
        var approvalScopeCorrect = true
        f.api.approvalHandler = { prompt in
            approvalScopeCorrect = prompt.op == .canvasApply && prompt.checkout == f.pbHandle
            return .deny
        }
        try error(rename(sibling, "Sibling by agent", "proactive"), .scopeApprovalRequired)
        try expect(approvalScopeCorrect && supervisor.records[sibling]?.displayName == siblingName,
                   "denied cross-agent rename uses canvas scope and changes nothing")
        f.api.approvalHandler = { _ in .allowOnce }
        let cross = try result(rename(sibling, "Sibling by agent", "proactive"))
        try expect(cross["nameSource"]?.string == "agent" && (try stored(sibling)).map { $0 == ("Sibling by agent", .agent) } == true,
                   "granted cross-agent rename commits and persists, got \(cross)")
        try expect(supervisor.rename(agentID: sibling, to: "Sibling named by user"), "user names the sibling")
        let prompts = f.api.approvalPromptCount
        try error(rename(sibling, "Overwrite", "proactive"), .targetConflict)
        try expect(f.api.approvalPromptCount == prompts, "a refused proactive rename never prompts")
        f.api.approvalHandler = { _ in .allowForSession }
        _ = try result(rename(sibling, "Asked to rename", "requested"))
        try expect(supervisor.records[sibling]?.displayNameSource == .requested, "another agent's explicit request may rename it")
        try error(rename(foreign, "Elsewhere", "requested"), .permissionDenied)
        try expect(supervisor.records[foreign]?.displayNameSource != .requested, "outside the project is refused")

        // 7. Both provider entries reach the same operation.
        let native = f.api.handleMCPRequest([
            "agentId": f.agentId.rawValue.uuidString, "requestId": "native-rename", "op": "agent.update",
            "payload": ["agentId": f.agentId.rawValue.uuidString, "displayName": "Via MCP", "nameIntent": "requested"]])
        try expect(native["status"] as? String == "ok" && supervisor.records[f.agentId]?.displayName == "Via MCP",
                   "Claude/Codex MCP entry renames")
        final class ReplyBox: @unchecked Sendable { var response: PiHostToolResponse? }
        let pi = ReplyBox()
        let call = PiHostToolCall(request: PiHostToolRequest(
            piRequestId: "pi-rename", requestId: "pi-rename", op: "agent.update",
            payload: ["agentId": f.agentId.rawValue.uuidString, "displayName": "Via pi", "nameIntent": "requested"],
            receivedAt: Date())) { response, _ in pi.response = response }
        f.api.handle(agentId: f.agentId, call: call)
        try expect(pi.response?.status == .ok && supervisor.records[f.agentId]?.displayName == "Via pi", "Pi bridge entry renames")

        // 8. A real filesystem failure: nothing changes in memory or on screen.
        let file = store.layout.agentFile(id: f.agentId)
        let backup = file.appendingPathExtension("witness-backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try error(rename(f.agentId, "Unsaved", "requested"), .outcomeUnknown)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        try expect(supervisor.records[f.agentId]?.displayName == "Via pi" && tileTitle() == "Agent · Via pi",
                   "a failed save neither changes memory nor the tile")

        try expect(f.canvas.armedZoneId == armed && f.canvas.viewport == viewport && f.focusBroker.activeSurface == focus
                   && f.runtime.interactionGeneration == generation && f.canvas.allWorkspaceTiles() == tiles
                   && f.runtime.structuralRevision == revision, "renames preserve presentation, geometry and structural revision")

        try checkAutomaticTitlerYields()
        print("Agent rename API: context source, self/cross-agent proactive and requested renames, user-name protection, refusals, colour+name, MCP/pi entries, tile/sidebar/store, save failure and titler yield passed")
    }

    /// The automatic titler, through its production trigger (a finished turn
    /// reading claude's own `ai-title`), never replaces a name an agent set.
    /// A sentinel-named twin in the same run is the positive control: it DOES
    /// take the title, so the titler really ran.
    private static func checkAutomaticTitlerYields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-titler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true)),
            makeRunner: { _ in ScriptedAgentRunner(script: []) },
            nameTitlerCommand: { _ in nil },
            claudeSessionTitle: { _, _ in "Harness title" })
        func agent() -> AgentID {
            supervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .claudeCode,
                             model: "anthropic/claude-opus-5-5", thinking: "medium")
        }
        let control = agent()
        let proactive = agent()
        let requested = agent()
        try expect(supervisor.rename(agentID: proactive, to: "Agent chose this", source: .agent)
                   && supervisor.rename(agentID: requested, to: "Asked for this", source: .requested), "seed agent names")
        for id in [control, proactive, requested] {
            supervisor.qaDeliver(.turnCompleted(threadId: AgentSupervisor.threadId(for: id), turnId: "t1",
                                                outcome: .completed, errorMessage: nil), to: id)
        }
        spin(2) { supervisor.records[control]?.displayName == "Harness title" }
        try expect(supervisor.records[control]?.displayName == "Harness title",
                   "positive control: the titler must name a sentinel agent, got \(String(describing: supervisor.records[control]?.displayName))")
        try expect(supervisor.records[proactive]?.displayName == "Agent chose this" && supervisor.records[proactive]?.displayNameSource == .agent,
                   "the titler replaced an agent-set name: \(String(describing: supervisor.records[proactive]?.displayName))")
        try expect(supervisor.records[requested]?.displayName == "Asked for this" && supervisor.records[requested]?.displayNameSource == .requested,
                   "the titler replaced a requested name: \(String(describing: supervisor.records[requested]?.displayName))")
        // A person still wins over an agent-set name.
        try expect(supervisor.rename(agentID: proactive, to: "Person wins") && supervisor.records[proactive]?.displayNameSource == .manual,
                   "a user rename must replace an agent-set name")
    }
}
