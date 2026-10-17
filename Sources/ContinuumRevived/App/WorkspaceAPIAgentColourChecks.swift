import AppKit
import ContinuumRevivedCore
import Foundation

/// Production boot mount and dispatch, with real supervisor persistence and views.
@MainActor
enum WorkspaceAPIAgentColourChecks {
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
    private static func same(_ lhs: CGColor?, _ rhs: CGColor) -> Bool {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let a = lhs?.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              let b = rhs.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0 - $1) < 0.01 }
    }

    static func run() throws {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(description: "agent-colour API check requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        let f = try WorkspaceAPIChecks.makeFixture()
        defer { f.tearDown() }
        let supervisor = f.delegate.qaAgentSupervisor
        supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        var serial = 0
        func update(_ target: AgentID, _ color: Any, key: String? = nil, cancelled: @escaping () -> Bool = { false }) -> WorkspaceAPIService.Reply {
            serial += 1
            var payload: [String: Any] = ["agentId": target.rawValue.uuidString, "identityColor": color]
            if let key { payload["idempotencyKey"] = key }
            return f.api.dispatch(agentId: f.agentId, requestId: "colour-\(serial)", op: "agent.update", payload: payload, isCancelled: cancelled)
        }
        let suiteName = "array.check.apiColour.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: f.agentTileB, kind: .managedAgent, title: "Colour witness",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 420), zPosition: .first,
            runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        tile.identityStyleDefaults = suite
        tile.attach(agentID: f.agentId, supervisor: supervisor)
        let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tile
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        let beforeRecords = supervisor.records
        let armed = f.canvas.armedZoneId
        let viewport = f.canvas.viewport
        let focus = f.focusBroker.activeSurface
        let selection = f.canvas.canvasState.lastActiveTileId
        let generation = f.runtime.interactionGeneration
        let workspace = f.runtime.workspaceId
        let tiles = f.canvas.allWorkspaceTiles()
        let revision = f.runtime.structuralRevision
        var notifications = 0
        let observer = supervisor.addIdentityColorObserver(for: f.agentId) { _ in notifications += 1 }
        defer { supervisor.removeIdentityColorObserver(observer, for: f.agentId) }

        let first = try result(update(f.agentId, "blue", key: "first"))
        try expect(first["durability"]?.string == "committed" && first["identityColor"]?.string == "blue", "self update must commit blue")
        try expect(first["operationId"]?.string != nil && first["revision"]?.object?["epoch"]?.string == f.api.epoch,
                   "result reports operation and revision")
        try expect(f.api.approvalPromptCount == 0, "self update needs no prompt")
        try expect(try result(update(f.agentId, "blue", key: "first")) == first, "same-key replay returns original outcome")
        try error(update(f.agentId, "red", key: "first"), .idempotencyConflict)
        try expect(try result(update(f.agentId, "blue"))["durability"]?.string == "unchanged", "same colour is unchanged")
        try expect(notifications == 1, "unchanged/replayed requests announce nothing")
        // Read through a fresh store, never the supervisor's in-memory record.
        let store = AgentStore()
        try expect(try store.load(id: f.agentId)?.identityColor == "blue", "blue survives store reload")
        tile.layoutSubtreeIfNeeded()
        let blue = ZoneChromeNSView.color(named: "blue")
        try expect(same(tile.qaIdentityBar?.color, blue.withAlphaComponent(ManagedAgentTileNSView.identityBarAlpha).cgColor), "API update repaints title bar")
        suite.set(AgentIdentityColorStyle.border.rawValue, forKey: AgentIdentityColorConfig.styleKey)
        tile.applyTokens()
        try expect(tile.qaIdentityBar == nil && tile.layer?.borderWidth == ManagedAgentTileNSView.identityBorderWidth
                   && same(tile.layer?.borderColor, blue.withAlphaComponent(ManagedAgentTileNSView.identityBorderAlpha).cgColor), "API colour renders full border")

        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let inboxWindow = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        inboxWindow.contentView = inbox
        inboxWindow.orderFrontOffscreenForChecks()
        defer { inboxWindow.orderOut(nil) }
        func reloadInbox() {
            let now = Date()
            inbox.reload(rows: [AgentInboxRowBuilder.row(
                from: AgentsBoardRow(agentId: f.agentId.rawValue, status: .idle, lastSummary: "", recent: [], updatedAt: now),
                record: supervisor.records[f.agentId], now: now)])
            inbox.layoutSubtreeIfNeeded()
        }
        reloadInbox()
        try expect(same(inbox.identityDotForQA(agentId: f.agentId.rawValue)?.dot?.colour.cgColor,
                        AgentInboxView.identityDotColour(named: "blue").cgColor), "sidebar draws API colour")
        _ = try result(update(f.agentId, NSNull()))
        try expect(supervisor.records[f.agentId]?.identityColor == nil && tile.qaIdentityBar == nil && tile.layer?.borderWidth == 0, "null clears record and tile")
        reloadInbox()
        try expect(inbox.identityDotForQA(agentId: f.agentId.rawValue)?.dot == nil, "null removes sidebar dot")
        try expect(try store.load(id: f.agentId)?.identityColor == nil, "clear persists")
        try expect(try result(update(f.agentId, NSNull()))["durability"]?.string == "unchanged", "repeated clear unchanged")

        for invalid: Any in ["#ff0000", "ultraviolet", 42, true] { try error(update(f.agentId, invalid), .invalidRequest) }
        try error(f.api.dispatch(agentId: f.agentId, requestId: "missing", op: "agent.update",
                                 payload: ["agentId": f.agentId.rawValue.uuidString]), .invalidRequest)
        let sibling = supervisor.spawn(role: nil, prompt: nil, cwd: f.pbRoot, harness: .pi,
            model: "fixture/colour", thinking: "high", projectId: f.projectPb, projectRoot: f.pbRoot)
        let foreign = supervisor.spawn(role: nil, prompt: nil, cwd: f.paRoot, harness: .pi,
            model: "fixture/colour", thinking: "high", projectId: f.projectPa, projectRoot: f.paRoot)
        var approvalScopeCorrect = true
        f.api.approvalHandler = { prompt in
            approvalScopeCorrect = prompt.op == .canvasApply && prompt.checkout == f.pbHandle
            return .deny
        }
        try error(update(sibling, "red"), .scopeApprovalRequired)
        try expect(approvalScopeCorrect && supervisor.records[sibling]?.identityColor == nil, "denial uses canvas scope and changes nothing")
        f.api.approvalHandler = { _ in .allowOnce }
        _ = try result(update(sibling, "red"))
        let prompts = f.api.approvalPromptCount
        f.api.approvalHandler = { _ in .deny }
        try error(update(sibling, "purple"), .scopeApprovalRequired)
        try expect(f.api.approvalPromptCount == prompts + 1, "once grant consumed")
        f.api.approvalHandler = { _ in .allowForSession }
        _ = try result(update(sibling, "purple"))
        let sessionPrompts = f.api.approvalPromptCount
        _ = try result(update(sibling, "mint"))
        try expect(f.api.approvalPromptCount == sessionPrompts, "session grant reused")
        // Older records may have no projectId. Match canvas.apply's explicit
        // checkout lookup, never the currently armed project's controller.
        let legacy = supervisor.spawn(role: nil, prompt: nil, cwd: f.pbRoot, harness: .pi,
            model: "fixture/colour", thinking: "high", projectRoot: f.pbRoot)
        try expect(supervisor.records[legacy]?.projectId == nil, "legacy fixture has no project stamp")
        _ = try result(update(legacy, "teal"))
        supervisor.setWorkspaceToolsEnabled(agentID: legacy, true)
        _ = try result(f.api.dispatch(agentId: legacy, requestId: "legacy-colour", op: "agent.update",
            payload: ["agentId": sibling.rawValue.uuidString, "identityColor": "mint"]))
        try error(update(foreign, "blue"), .permissionDenied)
        try error(update(AgentID(rawValue: UUID()), "blue"), .permissionDenied)
        try expect(f.api.approvalPromptCount == sessionPrompts + 1 && supervisor.records[foreign]?.identityColor == nil, "outside scope refused before prompt; only legacy caller needed a new grant")
        try expect(try store.load(id: sibling)?.identityColor == "mint", "cross-agent change persists")

        var cancelled = false
        f.api._beforeCommitHook = { cancelled = true }
        guard case .cancelled = update(sibling, "orange", cancelled: { cancelled }) else { throw Failure(description: "cancel before effect") }
        f.api._beforeCommitHook = { f.api.revoke(agentId: f.agentId) }
        try error(update(sibling, "orange"), .permissionDenied)
        f.api._beforeCommitHook = nil
        try expect(supervisor.records[sibling]?.identityColor == "mint", "cancellation and revocation change nothing")
        supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, false)
        try error(update(f.agentId, "red"), .permissionDenied)
        supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)

        // Both provider adapter entries reach the same operation. The principal
        // is supplied by the host, independently of the target in the payload.
        let native = f.api.handleMCPRequest([
            "agentId": f.agentId.rawValue.uuidString, "requestId": "native-colour", "op": "agent.update",
            "payload": ["agentId": f.agentId.rawValue.uuidString, "identityColor": "teal"]])
        try expect(native["status"] as? String == "ok" && supervisor.records[f.agentId]?.identityColor == "teal", "Claude/Codex MCP entry commits colour")
        final class ReplyBox: @unchecked Sendable { var response: PiHostToolResponse? }
        let pi = ReplyBox()
        let call = PiHostToolCall(request: PiHostToolRequest(
            piRequestId: "pi-colour", requestId: "pi-colour", op: "agent.update",
            payload: ["agentId": f.agentId.rawValue.uuidString, "identityColor": NSNull()], receivedAt: Date())) { response, _ in
                pi.response = response
        }
        f.api.handle(agentId: f.agentId, call: call)
        try expect(pi.response?.status == .ok && supervisor.records[f.agentId]?.identityColor == nil, "Pi bridge entry clears colour")

        // A real filesystem failure, not a substituted setter: the persisted
        // record path is a directory, so load/write cannot complete.
        let file = store.layout.agentFile(id: f.agentId)
        let backup = file.appendingPathExtension("witness-backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.moveItem(at: backup, to: file)
        }
        let count = notifications
        try error(update(f.agentId, "yellow"), .outcomeUnknown)
        try expect(supervisor.records[f.agentId]?.identityColor == nil && notifications == count, "failed save neither publishes nor changes memory")
        try expect(tile.identityColor == nil, "failed save leaves view unchanged")

        var original = beforeRecords[f.agentId]!
        original.workspaceToolsEnabled = true
        try expect(supervisor.records[f.agentId] == original, "only identity colour was changed, then cleared")
        try expect(f.canvas.armedZoneId == armed && f.canvas.viewport == viewport && f.focusBroker.activeSurface == focus
                   && f.canvas.canvasState.lastActiveTileId == selection && f.runtime.interactionGeneration == generation
                   && f.runtime.workspaceId == workspace && f.canvas.allWorkspaceTiles() == tiles
                   && f.runtime.structuralRevision == revision, "API changes preserve presentation, geometry and structural revision")
        let context = try result(f.api.dispatch(agentId: f.agentId, requestId: "colour-context", op: "workspace.context", payload: [:]))
        try expect(context["capabilities"]?.array?.contains(where: { $0.string == "agent.update" }) == true, "context advertises self update")
        try expect(context["recentOperations"]?.array?.contains(where: { $0.object?["op"]?.string == "agent.update" }) == true, "recent operations include update")
        print("Agent colour API: self/cross-agent grants, null/unchanged/replay, rendered bar/border/sidebar, reload, refusals, cancellation/revocation and real save failure passed")
    }
}
