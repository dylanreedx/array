import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// `--agent-message-placement-check` — an agent's message never splits a reply.
///
/// Dylan's lead tile: a reply was streaming ("…as long as each test still fails
/// on the b"), another agent's message arrived, and the reply went on below the
/// card ("ug it guards against…"). Echoing the message closed the open text run,
/// so the rest of the reply streamed into a second entry. The card also carried
/// a 3 pt bar of the sender's colour down its left edge only.
///
/// A real claude stream-json reply, through the production `ClaudeEventTranslator`,
/// streams into a managed-agent tile attached to a supervisor; halfway through a
/// word the supervisor consumes a helper steer and echoes the message into the tile.
/// Asserted on what the tile DRAWS:
///
/// - the reply is one entry and one contiguous drawn run ("fails on the bug it
///   guards against"), and the card is drawn after it;
/// - the supervisor's persisted projection, fed the same way, agrees;
/// - in light and dark, the card's left and right edges draw the same pixels: an
///   even border, no one-sided bar.
///
/// Red before the fix: two assistant entries, the card between the halves, and
/// the left edge purple where the right is a hairline.
@MainActor
enum AgentMessagePlacementChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    /// Only the provider I/O is scripted. Consumption uses the supervisor's
    /// production steer receipt, transcript persistence and tile echo routes.
    final class SteeringRunner: AgentSteeringRunning, @unchecked Sendable {
        let base = ScriptedAgentRunner(script: [.sessionStateChanged(.ready)], holdUntilStopped: true)
        private let lock = NSLock()
        private var disposition: (@Sendable (UUID, AgentSteerDisposition) -> Void)?
        var acceptsSteerNow: Bool { base.runCount > base.completedRuns }
        var hasBackgroundWork: Bool { false }
        func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
            try base.run(prompt: prompt, onEvent: onEvent)
        }
        func emit(_ event: AgentRuntimeEvent) -> Bool { base.emit(event) }
        func stop() { base.stop() }
        func interrupt() throws { base.stop() }
        func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) { base.observeSpawnRequests(handler) }
        func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {
            base.observeRuntimeObservations(handler)
        }
        func observeSteerDispositions(_ handler: @escaping @Sendable (UUID, AgentSteerDisposition) -> Void) {
            lock.withLock { disposition = handler }
        }
        func steer(_ prompt: AgentPrompt, id: UUID) throws {
            guard acceptsSteerNow, let handler = lock.withLock({ disposition }) else {
                throw AgentSteerNotAccepted("no live turn or disposition observer")
            }
            handler(id, .consumed)
        }
    }

    static let firstHalf = ["Each guard stays in ", "the suite as long as each test ", "still fails on the b"]
    static let secondHalf = ["ug it guards against.", " Then it can be retired."]
    static var reply: String { (firstHalf + secondHalf).joined() }
    static let messageText = "Stabilize native refresh frame uptime before the gate."

    /// One claude reply with `--include-partial-messages`, split where the
    /// message arrives.
    static func streamLines() -> (before: [String], after: [String]) {
        func json(_ object: Any) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
        }
        func delta(_ text: String) -> String {
            json(["type": "stream_event", "parent_tool_use_id": NSNull(), "session_id": "amp",
                  "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]]])
        }
        let head = [
            json(["type": "system", "subtype": "init", "session_id": "amp", "cwd": "/fixture", "model": "fixture-claude"]),
            json(["type": "stream_event", "parent_tool_use_id": NSNull(), "session_id": "amp",
                  "event": ["type": "message_start", "message": ["id": "msg_amp", "role": "assistant", "content": []]]]),
            json(["type": "stream_event", "parent_tool_use_id": NSNull(), "session_id": "amp",
                  "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]]),
        ] + firstHalf.map(delta)
        let tail = secondHalf.map(delta) + [
            json(["type": "stream_event", "parent_tool_use_id": NSNull(), "session_id": "amp",
                  "event": ["type": "content_block_stop", "index": 0]]),
            json(["type": "assistant", "parent_tool_use_id": NSNull(), "session_id": "amp",
                  "message": ["id": "msg_amp", "role": "assistant", "content": [["type": "text", "text": reply]]]]),
            json(["type": "stream_event", "parent_tool_use_id": NSNull(), "session_id": "amp",
                  "event": ["type": "message_stop"]]),
            json(["type": "result", "subtype": "success", "is_error": false, "session_id": "amp",
                  "usage": ["input_tokens": 3, "output_tokens": 20]]),
        ]
        return (head, tail)
    }

    static func run(borderOnly: Bool = false) throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-message-placement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let runner = SteeringRunner()
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: { _ in runner },
            claudeSessionTitle: { _, _ in nil },
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: support),
            transcriptStore: AgentTranscriptStore(root: support.appendingPathComponent("transcripts", isDirectory: true)))
        defer { supervisor.stopAll() }
        AgentModelCatalog.shared.resetForQA(snapshot: .init(
            harness: .claudeCode, readiness: .ready, models: ["fixture/placement"],
            displayNames: ["fixture/placement": "Offline placement fixture"],
            contextWindows: ["fixture/placement": 200_000]))
        func spawn(_ name: String) -> AgentID {
            supervisor.spawn(role: nil, prompt: nil, cwd: support, harness: .claudeCode, model: "fixture/placement",
                             thinking: "low", projectId: UUID(), projectRoot: support, tileId: UUID(), displayName: name)
        }
        let sender = spawn("Native refresh")
        try expect(supervisor.setIdentityColor(agentID: sender, "purple"), "the sender must take its identity colour")
        let lead = spawn("Lead")
        _ = supervisor.setWorkspaceToolsEnabled(agentID: lead, true)

        let tile = Tile(id: UUID(), kind: .managedAgent, title: "Lead",
                        frame: TileFrame(x: 0, y: 0, width: 560, height: 640),
                        zPosition: .fromLegacyRank(1), zoneId: nil, runtimeRef: nil, metadata: TileMetadata())
        let view = ManagedAgentTileNSView(tile: tile)
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 640)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        view.attach(agentID: lead, supervisor: supervisor)

        func pump(_ seconds: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        try expect(supervisor.send("Explain the guards.", to: lead), "the lead refused its prompt")
        pump(0.1)

        var translator = ClaudeEventTranslator(runToken: "placement")
        let lines = streamLines()
        let message = AgentPrompt(AgentMessageEnvelope.wrap(messageText, senderID: sender.rawValue, senderName: "Native refresh"))
        func feed(_ batch: [String]) throws {
            for event in translator.translate(stream: batch) {
                try expect(runner.emit(event), "the runner had no live handler")
                pump(0.02)
            }
        }
        try feed(lines.before)
        // Mid-word, consume a steer through the same receipt and echo path as
        // the real composer rail. No synthetic tool boundary closes the reply.
        var accepted = false, handed = false, completed = false, echoes = 0
        var deliveryError: String?
        let echoToken = supervisor.addPromptEchoObserver(for: lead) { _ in echoes += 1 }
        defer { supervisor.removePromptEchoObserver(echoToken, for: lead) }
        Task { @MainActor in
            do {
                let occurrence = UUID()
                // This is the host-owned helper admission, not a person's typed
                // text (which correctly neutralizes agent-envelope examples).
                try await supervisor.stageScheduledWakeup(occurrence, text: message.text, for: lead, helperSteer: true)
                accepted = true
                supervisor.finishScheduledAdmission(occurrence)
                handed = await supervisor.sendQueuedItemNow(occurrence, for: lead)
            } catch { deliveryError = String(describing: error) }
            completed = true
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && (!completed || echoes == 0) { pump(0.01) }
        try expect(accepted && handed && echoes == 1, "the production helper steer must be consumed and echoed exactly once: \(deliveryError ?? "no admission error")")
        if let stillsDir = ProcessInfo.processInfo.environment["CONTINUUM_AGENT_MESSAGE_STILLS"],
           let canvas = view.qaCanvasTranscript {
            try FileManager.default.createDirectory(atPath: stillsDir, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                view.appearance = NSAppearance(named: appearance)
                pump()
                canvas.flushPendingVisualUpdate()
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: stillsDir).appendingPathComponent("agent-message-reply-during-arrival-\(name).png"))
                }
            }
        }
        try feed(lines.after)
        pump(0.2)

        func shape(_ document: AgentDocument, _ who: String) throws {
            let assistant = document.entries.filter { $0.role == .assistant }
            let texts = assistant.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }
            try expect(assistant.count == 1 && texts.first == reply,
                       "\(who): the reply must be ONE entry reading the whole reply; got \(assistant.count): \(texts)")
            let replyIndex = document.entries.firstIndex { $0.role == .assistant }!
            let cardIndex = document.entries.firstIndex { entry in
                entry.blocks.contains { if case .agentMessage = $0.payload { return true }; return false }
            }
            try expect(cardIndex.map { $0 > replyIndex } == true,
                       "\(who): the message card must follow the reply it arrived during (reply \(replyIndex), card \(String(describing: cardIndex)))")
        }
        if !borderOnly {
            try shape(view.qaDocumentForChecks, "tile")
            guard let document = supervisor.transcriptDocumentProjection(for: lead) else {
                throw Failure(description: "the supervisor has no transcript")
            }
            try shape(document, "supervisor projection")
        }

        guard let canvas = view.qaCanvasTranscript else { throw Failure(description: "the tile has no drawn transcript") }
        func settle() throws {
            canvas.flushPendingVisualUpdate()
            view.layoutSubtreeIfNeeded()
            if let error = canvas.qaRenderingErrorDescription { throw Failure(description: "the transcript failed to render: \(error)") }
        }
        try settle()
        let drawn = canvas.qaLaidOutText
        let whole = "still fails on the bug it guards against."
        guard let cardRange = drawn.range(of: messageText) else {
            throw Failure(description: "the drawn transcript must hold \"\(whole)\" in one run and the card's text; it drew: \(drawn)")
        }
        if !borderOnly {
            try expect(drawn.range(of: whole).map { $0.upperBound <= cardRange.lowerBound } == true,
                       "the card must be drawn after the whole reply; it drew: \(drawn)")
        }

        // The card's edges, in both appearances.
        let stillsDir = ProcessInfo.processInfo.environment["CONTINUUM_AGENT_MESSAGE_STILLS"]
        guard let cardBlockID = view.qaDocumentForChecks.entries.flatMap(\.blocks).first(where: { $0.kind == .agentMessage })?.id else {
            throw Failure(description: "the trusted helper message must render as an agent-message card")
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            view.appearance = NSAppearance(named: appearance)
            pump(0.1)
            try settle()
            canvas.needsDisplay = true
            canvas.displayIfNeeded()
            guard let card = canvas.qaMessageCard(for: cardBlockID), card.body == messageText, card.bodyFits else {
                throw Failure(description: "\(name): the agent-message card body must draw completely")
            }
            let point = NSPoint(x: card.frame.midX, y: card.frame.midY)
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
                throw Failure(description: "\(name): could not capture the transcript")
            }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            if let stillsDir, let tileRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: tileRep)
                try FileManager.default.createDirectory(atPath: stillsDir, withIntermediateDirectories: true)
                try tileRep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: stillsDir).appendingPathComponent("agent-message-reply-after-arrival-\(name).png"))
            }
            if let stillsDir, let cardRep = canvas.bitmapImageRepForCachingDisplay(in: card.frame.insetBy(dx: -2, dy: -2)) {
                canvas.cacheDisplay(in: card.frame.insetBy(dx: -2, dy: -2), to: cardRep)
                try cardRep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: stillsDir).appendingPathComponent("agent-message-card-\(name).png"))
            }
            try evenEdges(rep: rep, bounds: canvas.bounds, flipped: canvas.isFlipped, at: point, name: name)
        }
        if !borderOnly { try AgentMessageBoundaryChecks.run() }
        print("agent message placement: one reply entry, one drawn run, card after it; even card edges in light and dark")
    }

    /// Scans one pixel row through the card's text: from the left edge of the
    /// transcript to the first non-background pixel, and from the right to the
    /// last. An even border draws the same few pixels at both edges; a bar down
    /// one side does not.
    private static func evenEdges(rep: NSBitmapImageRep, bounds: NSRect, flipped: Bool, at point: NSPoint, name: String) throws {
        let scale = CGFloat(rep.pixelsWide) / max(1, bounds.width)
        let row = Int(((flipped ? point.y : bounds.height - point.y) * scale).rounded(.down))
        func rgb(_ x: Int) -> (CGFloat, CGFloat, CGFloat) {
            let c = rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB) ?? .clear
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        func close(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat), _ tolerance: CGFloat = 0.06) -> Bool {
            abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
        }
        let background = rgb(0)
        guard let left = (0..<rep.pixelsWide).first(where: { !close(rgb($0), background, 0.01) }),
              let right = (0..<rep.pixelsWide).reversed().first(where: { !close(rgb($0), background, 0.01) }),
              right - left > Int(40 * scale) else {
            throw Failure(description: "\(name): the card's edges were not found on row \(row)")
        }
        let depth = Int((5 * scale).rounded())
        var mismatches: [String] = []
        for k in 0..<depth where !close(rgb(left + k), rgb(right - k)) {
            mismatches.append("\(k)px: left \(rgb(left + k)) right \(rgb(right - k))")
        }
        try expect(mismatches.isEmpty, "\(name): the card's left edge differs from its right (a one-sided border): \(mismatches.prefix(3))")
    }
}
