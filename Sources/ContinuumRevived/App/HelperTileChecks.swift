import AppKit
import ContinuumRevivedCore
import Foundation

/// Real mounted workspace -> array_delegate MCP -> supervisor -> scripted Pi.
/// No hand-made child records or checks-only canvas installation.
@MainActor
enum HelperTileChecks {
    typealias Bench = WorkspaceAgentReportChecks.Bench
    typealias Failure = WorkspaceAgentReportChecks.Failure
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: "helper-tiles: " + message) }
    }
    final class Clock { var now = Date() }

    static func bench(_ label: String) throws -> (Bench, Clock) {
        let b = try WorkspaceAgentReportChecks.makeBench(label: label)
        let executable = b.binDir.appendingPathComponent("pi")
        let script = WorkspaceAgentReportChecks.fakePi.replacingOccurrences(
            of: #"emit({"type": "turn_end", "message": {"role": "assistant"}})"#,
            with: #"emit({"type": "turn_end", "message": {"role": "assistant", "stopReason": "error" if "FAIL-TURN" in json.dumps(text) else "stop", "errorMessage": "fixture failure"}})"#)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let clock = Clock()
        b.supervisor.helperTileNow = { clock.now }
        try expect(b.supervisor.setMode(.managed, for: b.f.agentId), "cannot set lead mode")
        // Clear only fixture documents to leave a witnessed beside-lead slot.
        for tile in b.f.canvas.allWorkspaceTiles() where tile.zoneId == b.f.zoneB && tile.id != b.f.agentTileB {
            b.f.canvas.removeTile(id: tile.id)
        }
        return (b, clock)
    }
    static func child(_ b: Bench, _ label: String) async throws -> AgentID {
        let c = try b.configuration(for: b.f.agentId)
        let reply = try await WorkspaceAgentReportChecks.call(c, "array_delegate", [
            "task": label, "title": label, "idempotencyKey": UUID().uuidString])
        guard !reply.isError, let result = reply.reply["result"] as? [String: Any],
              let raw = result["childAgentId"] as? String, let uuid = UUID(uuidString: raw) else {
            throw Failure(description: "helper delegation failed: \(reply.reply)")
        }
        try expect(result["partial"] as? Bool == false, "tile-less creation reported partial failure")
        return AgentID(rawValue: uuid)
    }
    static func settled(_ b: Bench, _ id: AgentID) async throws {
        try await AgentPresenceChecks.eventually("helper never settled", timeout: 15) {
            b.supervisor.records[id]?.latestTurnAt != nil && !b.supervisor.isRunning(id)
        }
    }
    static func report(_ b: Bench, _ id: AgentID, fail: Bool = false) async throws {
        let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: id), "array_report", [
            "summary": "Inspected the ledger", "checks": [["what": "ledger balances", "result": fail ? "fail" : "pass"]]])
        try expect(!reply.isError, "report refused")
    }
    static func stored(_ id: AgentID) throws -> AgentRecord? { try AgentStore(smokeTest: false).load(id: id) }
    static func world(_ b: Bench, _ tile: UUID) throws -> CGRect {
        guard let frame = b.f.canvas.navigationTileSnapshot(for: tile)?.worldFrame else {
            throw Failure(description: "helper tile has no world snapshot")
        }
        return CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    static func lifecycle() async throws {
        let (b, _) = try bench("helper-tiles-lifecycle"); defer { b.tearDown() }
        let s = b.supervisor
        let count = b.f.canvas.allWorkspaceTiles().count
        let id = try await child(b, "HOLD running helper")
        try await AgentPresenceChecks.eventually("helper runner did not start") { s.isRunning(id) }
        try expect(s.records[id]?.tileId == nil && b.f.canvas.allWorkspaceTiles().count == count,
                   "managed delegate created a tile")
        try expect(try stored(id)?.tileId == nil && s.records[id]?.capabilities.locallyManaged == true,
                   "tile-less record is not durable/steerable")
        let leadRect = try world(b, b.f.agentTileB)
        let tile = try s.popOut(id)
        let rect = try world(b, tile)
        let zone = b.f.canvas.installedZonePlacement(for: b.f.zoneB)!
        let zoneRect = CGRect(x: zone.origin.x, y: zone.origin.y, width: zone.size.width, height: zone.size.height)
        try expect(zoneRect.contains(rect) && rect.minX >= leadRect.maxX && rect.minY == leadRect.minY,
                   "pop-out WORLD frame \(rect) is not beside lead \(leadRect) inside \(zoneRect)")
        try expect(b.f.runtime.document.lastActiveZoneId == b.f.zoneA, "pop-out armed the lead's zone")
        let saved = try b.f.storePb.loadCanvas()
        try expect(saved.tiles.contains { $0.id == tile && $0.frame.x == rect.minX && $0.frame.y == rect.minY }, "pop-out did not persist WORLD frame")
        try expect(saved.tiles.contains { $0.id == b.f.hiddenB }, "pop-out erased unhydrated tiles")
        try expect(try stored(id)?.tileId == tile, "pop-out binding not persisted")
        try expect(try s.setPinned(id, true) && stored(id)?.pinned == true, "pin did not persist")
        let restored = AgentSupervisor(store: AgentStore(smokeTest: false))
        _ = restored.restore()
        try expect(restored.records[id]?.tileId == tile && restored.records[id]?.pinned == true, "restore lost tile or pin")
        try await AgentPresenceChecks.eventually("helper transcript did not arrive") {
            s.qaFinalAssistantText(for: id) == WorkspaceAgentReportChecks.childFinalText
        }
        try s.foldBack(id)
        try expect(s.qaFinalAssistantText(for: id) == WorkspaceAgentReportChecks.childFinalText, "fold-back discarded transcript")
        try expect(s.isRunning(id) && s.records[id]?.tileId == nil && s.records[id]?.closeRequestedAt == nil,
                   "fold-back stopped or closed the running helper")
        try expect(try b.f.canvas.tileRecord(for: tile) == nil && !b.f.storePb.loadCanvas().tiles.contains { $0.id == tile }, "fold-back left the tile live or persisted")
        try expect(try stored(id)?.pinned == false && !s.setPinned(id, true), "tile-less pin survived/was accepted")
        try Data().write(to: b.f.pbRoot.appendingPathComponent("release.flag"))
        try await settled(b, id)
        let inspected = try await WorkspaceAgentReportChecks.call(b.configuration(for: b.f.agentId), "array_inspect_agent", ["agentId": id.rawValue.uuidString])
        try expect(!inspected.isError, "tile-less helper cannot be inspected")
        let handle = s.records[id]!.spawnResultHandle!
        let waited = try await WorkspaceAgentReportChecks.call(b.configuration(for: b.f.agentId), "wait_agents", ["handles": [handle], "timeoutSeconds": 5])
        let agents = (waited.reply["result"] as? [String: Any])?["agents"] as? [[String: Any]]
        try expect(!waited.isError && agents?.first?["status"] as? String == "completed", "folded helper lost wait_agents result")
        try expect(agents?.first?["finalText"] as? String == WorkspaceAgentReportChecks.childFinalText, "folded transcript did not reach wait_agents")
        let message = try await WorkspaceAgentReportChecks.call(b.configuration(for: b.f.agentId), "array_message_agent", [
            "agentId": id.rawValue.uuidString, "text": "NEXT HOLD after fold", "idempotencyKey": UUID().uuidString])
        try expect(!message.isError, "folded helper rejected a message")
        try await AgentPresenceChecks.eventually("folded helper did not run next message") { s.isRunning(id) }
        s.stop(id)
        try expect(!s.isRunning(id) && s.records[id] != nil, "tile-less stop failed/deleted the record")
        let parked = try s.popOut(id)
        b.f.runtime.warmSceneCapacity = 1
        try b.f.runtime.switchWorkspace(to: b.f.workspaceWB)
        try expect(b.f.runtime.parkedTileRecord(for: parked, projectId: b.f.projectPb) != nil, "fixture did not park the helper")
        try s.foldBack(id)
        try expect(b.f.runtime.parkedTileRecord(for: parked, projectId: b.f.projectPb) == nil, "fold-back left a parked tile")
        try b.f.runtime.switchWorkspace(to: b.f.workspaceWA)
        try expect(try b.f.canvas.tileRecord(for: parked) == nil && !b.f.storePb.loadCanvas().tiles.contains { $0.id == parked }, "warm remount resurrected helper")
        try expect(s.setMode(.free, for: b.f.agentId), "free mode refused")
        let free = try await child(b, "free child unchanged")
        try expect(s.records[free]?.tileId != nil, "free delegation lost its tile")
        print("Helper tile lifecycle passed: managed tile-less/free unchanged, real WORLD placement + persistence, pin restore, running fold, message/stop/wait")
    }

    static func cap() async throws {
        let (b, clock) = try bench("helper-tiles-cap"); defer { b.tearDown() }
        let s = b.supervisor
        var ids: [AgentID] = []
        for n in 0..<4 {
            let id = try await child(b, "cap \(n)"); try await settled(b, id)
            if n != 1 { try await report(b, id) } // A finished helper needs no report for cap eviction.
            ids.append(id)
        }
        ids.swapAt(0, 1) // Oldest pop-out is deliberately not oldest creation.
        for id in ids.prefix(3) { _ = try s.popOut(id); clock.now += 1 }
        _ = try s.popOut(ids[3])
        try expect(s.records[ids[0]]?.tileId == nil && ids.dropFirst().allSatisfy { s.records[$0]?.tileId != nil }, "cap did not fold oldest finished unpinned helper")
        try expect(s.setPinned(ids[1], true), "pin failed")
        try await report(b, ids[2], fail: true)
        _ = try s.popOut(ids[0])
        try expect(s.records[ids[3]]?.tileId == nil && s.records[ids[1]]?.tileId != nil && s.records[ids[2]]?.tileId != nil,
                   "cap folded pinned/failed helper instead of eligible one")
        try expect(s.send("HOLD cap", to: ids[0]), "cannot start cap running helper")
        try await AgentPresenceChecks.eventually("cap runner absent") { s.isRunning(ids[0]) }
        do { _ = try s.popOut(ids[3]); throw Failure(description: "cap allowed a fourth protected tile") }
        catch is AgentSupervisor.HelperTileError { }
        try expect(s.isRunning(ids[0]) && s.records[ids[3]]?.tileId == nil, "refused pop-out changed running helper")
        // A needs-you report/status is protected even with a successful result.
        s.stop(ids[0]); try s.foldBack(ids[0]); _ = try s.popOut(ids[3])
        let status = AgentDeclaredStatus(now: "Waiting", needsYou: "Choose a path", declaredAt: clock.now)
        try expect(s.declareStatus(status, for: ids[3]), "needs-you refused")
        do { _ = try s.popOut(ids[0]); throw Failure(description: "cap folded needs-you helper") }
        catch is AgentSupervisor.HelperTileError { }
        print("Helper tile cap passed: oldest eligible first; pinned, failed, running and needs-you protected; fourth refused without collateral folds")
    }

    static func automatic() async throws {
        let (b, clock) = try bench("helper-tiles-auto"); defer { b.tearDown() }
        let s = b.supervisor
        let good = try await child(b, "good"), failed = try await child(b, "failed"), pinned = try await child(b, "pinned")
        for id in [good, failed, pinned] { try await settled(b, id); try await report(b, id, fail: id == failed); _ = try s.popOut(id) }
        try expect(s.setPinned(pinned, true), "pin failed")
        s.sweepHelperTiles()
        clock.now += AgentSupervisor.helperFoldBackDelay - 0.01; s.sweepHelperTiles()
        try expect(s.records[good]?.tileId != nil, "auto-fold before delay")
        clock.now += 0.02
        // Let the production timer consume the injected clock, proving that
        // the sweep is actually scheduled by the supervisor's initializer.
        try await AgentPresenceChecks.eventually("production timer did not auto-fold", timeout: 3) { s.records[good]?.tileId == nil }
        try expect(s.records[good]?.tileId == nil, "successful reported helper did not auto-fold")
        try expect(s.records[failed]?.tileId != nil && s.records[pinned]?.tileId != nil, "failed/pinned auto-folded")
        try expect(s.send("FAIL-TURN", to: failed), "failed fixture turn refused")
        try await settled(b, failed); try await report(b, failed)
        try expect(s.records[failed]?.latestTerminalEvent?.outcome == .failed, "fixture did not fail through the runner")
        clock.now += 10; s.sweepHelperTiles()
        try expect(s.records[failed]?.tileId != nil, "failed stream with clean report auto-folded")
        try expect(s.setPinned(pinned, false), "unpin refused")
        try expect(s.declareStatus(AgentDeclaredStatus(now: "Waiting", needsYou: "Review", declaredAt: clock.now), for: pinned), "asking status refused")
        s.sweepHelperTiles(); clock.now += 10; s.sweepHelperTiles()
        try expect(s.records[pinned]?.tileId != nil, "asking helper auto-folded")
        // A fresh turn cancels eligibility; a stale report cannot hide its result.
        _ = try s.popOut(good)
        try expect(s.send("HOLD fresh", to: good), "fresh turn refused")
        s.sweepHelperTiles(); clock.now += 10; s.sweepHelperTiles()
        try expect(s.records[good]?.tileId != nil && s.isRunning(good), "running helper auto-folded")
        try Data().write(to: b.f.pbRoot.appendingPathComponent("release.flag"))
        try await settled(b, good)
        s.sweepHelperTiles(); clock.now += 10; s.sweepHelperTiles()
        try expect(s.records[good]?.tileId != nil, "stale report auto-folded a new turn")
        try expect(s.send("HOLD close", to: good), "closing turn refused")
        try await AgentPresenceChecks.eventually("closing helper did not start") { s.isRunning(good) }
        try expect(s.setPinned(pinned, true), "repin before lead close refused")
        // The production close intent folds every descendant, including pinned
        // and running helpers, without propagating close/stop to them.
        _ = s.requestClose(agentID: b.f.agentId)
        try expect([good, failed, pinned].allSatisfy { s.records[$0] != nil && s.records[$0]?.tileId == nil && s.records[$0]?.closeRequestedAt == nil }, "lead close did not fold helpers cleanly")
        try expect(s.isRunning(good), "closing lead stopped its helper")
        _ = s.reopen(agentID: b.f.agentId)
        _ = try s.popOut(good)
        let archive = s.archive(b.f.agentId)
        try expect(archive.recordDeleted && [good, failed, pinned].allSatisfy { s.records[$0] != nil && s.records[$0]?.tileId == nil } && s.isRunning(good), "lead archive stopped/deleted/left out helper")
        print("Helper auto-fold passed: five-second boundary, failed/pinned/running protection, lead close and archive fold without stopping descendants")
    }
}
