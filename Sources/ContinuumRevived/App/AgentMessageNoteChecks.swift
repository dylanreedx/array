import AppKit
import ContinuumRevivedCore
import Foundation

/// `--agent-message-note-check`: an `agent.message` to anyone but the sender's
/// own helper is a NOTE unless the sender passes `wake: true`. Through the
/// production workspace API dispatch and the production supervisor, on the
/// steering pi fake (real rpc frames):
///
/// - a helper's message UP to its lead, and to a sibling, starts no turn on an
///   idle recipient, and says so in its result;
/// - the note is in the recipient's tile (its queue rail) at once;
/// - the recipient's next turn receives it (handed over at its tool call), and
///   the rail is empty after;
/// - `wake: true` still starts a turn on the lead;
/// - a message DOWN to the sender's own helper still starts a turn.
///
/// RED before the change: the message up started a lead turn and returned
/// `delivered`.
@MainActor
enum AgentMessageNoteChecks {
    static func run() async throws {
        let b = try WorkspaceAgentReportChecks.makeBench(label: "agent-message-note")
        defer { b.tearDown() }
        // Overwrite the bench's pi with the steering fake: it records every rpc
        // frame and takes a steer at a `TOOL` turn's tool call.
        try AgentSteeringQAFakes.install(.pi, in: b.binDir)
        let s = b.supervisor, lead = b.f.agentId
        func expect(_ ok: Bool, _ label: String) throws {
            guard ok else { throw WorkspaceAgentReportChecks.Failure(description: label) }
            print("agent-message-note-check: \(label) PASS")
        }
        func frames(_ type: String, containing marker: String) -> [String] {
            AgentSteeringQAFakes.receivedFrames(in: b.binDir).compactMap { frame in
                guard frame["type"] as? String == type, let message = frame["message"] as? String,
                      message.contains(marker) else { return nil }
                return message
            }
        }
        func send(from sender: AgentID, to recipient: AgentID, _ text: String, wake: Bool? = nil) throws -> [String: AnyHashableJSON] {
            var payload: [String: Any] = ["agentId": recipient.rawValue.uuidString, "text": text, "idempotencyKey": UUID().uuidString]
            if let wake { payload["wake"] = wake }
            let reply = b.f.api.dispatch(agentId: sender, requestId: UUID().uuidString, op: "agent.message", payload: payload)
            guard case let .result(result) = reply else {
                throw WorkspaceAgentReportChecks.Failure(description: "agent.message failed: \(reply)")
            }
            return result
        }
        func idle(_ id: AgentID) async -> Bool {
            await waitUntil(timeout: 20, pollInterval: 0.02) { !s.isRunning(id) && s.records[id]?.latestTerminalEvent != nil }
        }

        let helper = try b.delegate("note-helper"), sibling = try b.delegate("note-sibling")
        let helperIdle = await idle(helper), siblingIdle = await idle(sibling)
        try expect(helperIdle && siblingIdle, "both helpers settle after their first turn")
        // Their first results wake the lead (the eight-second batch hold,
        // skipped here); the note legs start from an idle lead.
        s.helperCompletionNow = { Date().addingTimeInterval(9) }
        await s.flushHelperCompletions()
        var quiet = 0
        for _ in 0..<600 where quiet < 50 {
            quiet = s.isRunning(lead) || s.queuedMessages(for: lead).contains(where: { !$0.helperNote }) ? 0 : quiet + 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try expect(quiet >= 50, "the lead is idle before the note legs")
        let promptsBeforeNote = AgentSteeringQAFakes.receivedFrames(in: b.binDir).filter { $0["type"] as? String == "prompt" }.count
        // The lead's tile, attached the way the canvas attaches it.
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: b.f.agentTileB, kind: .managedAgent, title: "note-lead",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 420), zPosition: .fromLegacyRank(1),
            runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
        tile.attach(agentID: lead, supervisor: s, projectName: "Pb")
        func railShows(_ marker: String) -> Bool {
            tile.qaComposerForChecks?.qaQueueRail.state.steers.contains { $0.text.contains(marker) } == true
        }

        // 1. Up to the lead, no wake: a note. No turn, said plainly, in the tile.
        let up = try send(from: helper, to: lead, "NOTE-UP taken, no need to follow up")
        try expect(up["delivery"]?.string == "note" && up["noteReason"]?.string?.contains("wake: true") == true,
                   "a helper's message up to its lead is a note and its result says how to wake: \(up)")
        let shown = await waitUntil(timeout: 5, pollInterval: 0.02) { railShows("NOTE-UP") }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let promptsAfterNote = AgentSteeringQAFakes.receivedFrames(in: b.binDir).filter { $0["type"] as? String == "prompt" }.count
        try expect(!s.isRunning(lead) && promptsAfterNote == promptsBeforeNote && frames("steer", containing: "NOTE-UP").isEmpty,
                   "the note starts no turn on the idle lead (running \(s.isRunning(lead)), prompts \(promptsBeforeNote)→\(promptsAfterNote))")
        try expect(shown && railShows("NOTE-UP"), "the note is visible in the lead's tile")

        // 2. To a sibling, no wake: a note too.
        let peer = try send(from: helper, to: sibling, "NOTE-PEER fyi only")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try expect(peer["delivery"]?.string == "note" && !s.isRunning(sibling) && frames("prompt", containing: "NOTE-PEER").isEmpty,
                   "a message to a peer is a note and starts no turn")

        // 3. The lead's next turn receives it at its tool call, once.
        try expect(s.send("TOOL run the next step", to: lead), "the lead accepts a user turn")
        let folded = await waitUntil(timeout: 15, pollInterval: 0.02) { !frames("steer", containing: "NOTE-UP").isEmpty }
        try expect(folded, "the note reaches the lead's next turn as input")
        let leadIdle = await idle(lead)
        try expect(leadIdle, "the lead's turn ends")
        let cleared = await waitUntil(timeout: 5, pollInterval: 0.02) { !railShows("NOTE-UP") }
        try expect(cleared && frames("steer", containing: "NOTE-UP").count == 1
                   && !s.queuedMessages(for: lead).contains { $0.text.contains("NOTE-UP") },
                   "the note is used once and leaves the tile's rail")

        // 4. wake: true still starts a turn on the lead.
        let promptsBefore = frames("prompt", containing: "WAKE-UP").count
        let woke = try send(from: helper, to: lead, "WAKE-UP the build is red, act now", wake: true)
        let started = await waitUntil(timeout: 15, pollInterval: 0.02) { frames("prompt", containing: "WAKE-UP").count > promptsBefore }
        try expect(woke["delivery"]?.string == "delivered" && woke["noteReason"] == nil && started,
                   "wake: true starts a turn on the lead: \(woke)")
        let wokenIdle = await idle(lead)
        try expect(wokenIdle, "the woken lead settles")

        // 5. Down to the sender's own helper, no wake: still a turn.
        let down = try send(from: lead, to: helper, "DOWN-1 run the next step")
        let ran = await waitUntil(timeout: 15, pollInterval: 0.02) { !frames("prompt", containing: "DOWN-1").isEmpty }
        try expect(down["delivery"]?.string == "delivered" && ran, "a message down to a helper still starts its turn: \(down)")
        _ = await idle(helper)
        print("AgentMessageNoteChecks passed")
    }
}
