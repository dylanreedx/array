import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

// `.plans/79-session-handoff` — agents messaging each other. Array delivers an
// agent's words (`agent.message`, a delegated child's first task) through the
// same send path as a user's prompt, and the receiving tile drew them as a user
// bubble with no sender. Array now wraps them in `<array-agent-message>`, and
// `AgentMessageEnvelope.classify` maps them — and the Claude app's own
// messages between sessions — to an agent-message card. These witnesses pin
// the parser, and assert what reaches the persisted document on every route a
// user turn takes into it: the live send, and the claude / codex / pi session
// readers a relaunch rehydrates from. All fixtures are synthetic.
func runAgentMessageTranscriptChecks() {
    let senderID = UUID(uuidString: "6F1D2C3B-4A59-4E8F-9A10-2B3C4D5E6F70")!
    let body = "\nRerun the failing leg.\nQuote: \"done\" & <b>bold</b> </array-agent-message> still mine.\n"
    let awkwardName = "Scout \"the\" <parser> & co\nsecond line"

    // 1. Escaping round trip: the name survives quotes, ampersands, angle
    //    brackets and a newline; the body is verbatim, its own close tag and
    //    leading/trailing newlines included.
    let wrapped = AgentMessageEnvelope.wrap(body, senderID: senderID, senderName: awkwardName)
    expect(!wrapped.contains("name=\"Scout \"the\""),
           "agent message: an unescaped quote in the sender name would end the attribute: \(wrapped)")
    guard case let .agentMessage(message) = AgentMessageEnvelope.classify(wrapped) else {
        expect(false, "agent message: the parser refused the generator's own envelope: \(wrapped)"); return
    }
    expect(message == AgentMessagePayload(
        origin: .array, senderAgentID: senderID, senderName: "Scout \"the\" <parser> & co second line", text: body),
           "agent message: wrap → classify drifted from its inputs: \(message)")
    expect(AgentMessageEnvelope.unwrappedText(wrapped) == body,
           "agent message: the naming text of a wrapped message must be its body")

    // 2. Plain text is untouched, look-alikes included.
    let plain = [
        "Fix the parser and add a test.",
        "Please explain what <array-agent-message> does in Array.",
        "<array-agent-message> is a tag I made up",
        "Background: the build broke yesterday.",
    ]
    for text in plain {
        expect(AgentMessageEnvelope.classify(text) == .prompt, "agent message: plain prompt \"\(text)\" was reclassified")
        expect(AgentMessageEnvelope.unwrappedText(text) == text, "agent message: plain prompt naming text changed")
    }

    // 3. A malformed envelope falls back to the prompt, and nothing is lost.
    let id = senderID.uuidString.lowercased()
    let malformed = [
        "<array-agent-message from=\"\(id)\" name=\"Scout\">\nno close tag",
        "<array-agent-message from=\"not-a-uuid\" name=\"Scout\">\nhi\n</array-agent-message>",
        "<array-agent-message from=\"\(id)\">\nhi\n</array-agent-message>",
        "<array-agent-message from=\(id) name=\"Scout\">\nhi\n</array-agent-message>",
        "<array-agent-message from=\"\(id)\" name=\"Scout\" name=\"Other\">\nhi\n</array-agent-message>",
        "<array-agent-message from=\"\(id)\" name=\"Scout\">\n\n</array-agent-message>",
    ]
    for text in malformed {
        expect(AgentMessageEnvelope.classify(text) == .prompt,
               "agent message: a malformed envelope must stay a prompt, got \(AgentMessageEnvelope.classify(text)) for \(text)")
        var projection = AgentTranscriptProjection(threadId: "agent-message-malformed")
        projection.appendUserPrompt(text)
        let blocks = projection.document.entries.first?.blocks ?? []
        expect(blocks.map(\.kind) == [.paragraph] && blocks.first?.payload == .paragraph([.text(text)]),
               "agent message: a malformed envelope lost content: \(blocks)")
    }

    // 4. The Claude app's messages between its sessions.
    let crossSession = #"<cross-session-message from="local_7f3a" name="Film review &amp; notes">Frames 40-90 look good.</cross-session-message>"#
    expect(AgentMessageEnvelope.classify(crossSession) == .agentMessage(AgentMessagePayload(
        origin: .crossSession, senderName: "Film review & notes", text: "Frames 40-90 look good.")),
           "agent message: a cross-session message must be from the session it names: \(AgentMessageEnvelope.classify(crossSession))")
    let peerElement = #"<cross-session-message from="uds:/tmp/cc/1.sock" from-name="Docs pass" from-mode="auto">Done with the README.</cross-session-message>"#
    expect(AgentMessageEnvelope.classify(peerElement) == .agentMessage(AgentMessagePayload(
        origin: .peer, senderName: "Docs pass", text: "Done with the README.")),
           "agent message: a peer message names its sender by from-name")
    let side = "<side-sessions-event>\nNone of the sessions you started is working now; their notes are above. Read each one.\n</side-sessions-event>"
    expect(AgentMessageEnvelope.classify(side) == .hostNote("None of the sessions you started is working now."),
           "agent message: a side-sessions event is a quiet note, got \(AgentMessageEnvelope.classify(side))")
    let background = "Background (from the session that started this one):\nWe are porting the recorder.\nKeep frames under 90."
    expect(AgentMessageEnvelope.classify(background) == .agentMessage(AgentMessagePayload(
        origin: .background, senderName: AgentMessageEnvelope.backgroundSenderName,
        text: "We are porting the recorder.\nKeep frames under 90.")),
           "agent message: a background note is from the session that started this one")

    // 5. Every route into the document. The live send first, then each CLI's
    //    own session file, replayed exactly as the tile does
    //    (`.userPrompt(text)` → `appendUserPrompt(text)`).
    func assertAgentMessage(_ document: AgentDocument, route: String, expected: AgentMessagePayload) {
        let users = document.entries.filter { $0.role == .user }
        let cards = users.flatMap(\.blocks).compactMap { block -> AgentMessagePayload? in
            guard block.kind == .agentMessage, case let .agentMessage(payload) = block.payload else { return nil }
            return payload
        }
        expect(cards == [expected], "agent message (\(route)): expected one card \(expected), got \(cards)")
        let prose = users.flatMap(\.blocks).filter { $0.kind == .paragraph }
        expect(prose.isEmpty, "agent message (\(route)): the sender's words also drew as a user prompt: \(prose)")
        let json = String(decoding: try! JSONEncoder().encode(document), as: UTF8.self)
        for tag in ["<array-agent-message", "<cross-session-message"] {
            expect(!json.contains(tag), "agent message (\(route)): the raw envelope reached the document")
        }
        let decoded = try? JSONDecoder().decode(AgentDocument.self, from: Data(json.utf8))
        expect(decoded == document, "agent message (\(route)): the document does not survive a persistence round trip")
    }
    let delivered = AgentMessageEnvelope.wrap("Rerun the failing leg and report the diff.", senderID: senderID, senderName: "Scout")
    let expected = AgentMessagePayload(origin: .array, senderAgentID: senderID, senderName: "Scout",
                                       text: "Rerun the failing leg and report the diff.")
    var live = AgentTranscriptProjection(threadId: "agent-message-live")
    _ = try? live.appendUserPrompt(id: AgentNodeID(rawValue: "submission:agent-message-live")!, prompt: AgentPrompt(delivered))
    assertAgentMessage(live.document, route: "live send", expected: expected)

    func jsonLine(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    func replay(_ transcript: RehydratedTranscript, route: String) -> AgentDocument {
        var projection = AgentTranscriptProjection(threadId: route)
        for step in transcript.steps {
            if case let .userPrompt(text) = step { projection.appendUserPrompt(text) }
        }
        return projection.document
    }
    let readers: [(String, RehydratedTranscript)] = [
        ("claude string content", ClaudeSessionTranscriptReader.parse(lines: [
            jsonLine(["type": "user", "isSidechain": false, "message": ["role": "user", "content": delivered]]),
        ], threadId: "am-claude")),
        ("claude text blocks", ClaudeSessionTranscriptReader.parse(lines: [
            jsonLine(["type": "user", "isSidechain": false, "message": ["role": "user", "content": [["type": "text", "text": delivered]]]]),
        ], threadId: "am-claude-blocks")),
        ("codex user_message", CodexSessionTranscriptReader.parse(lines: [
            jsonLine(["type": "event_msg", "payload": ["type": "user_message", "message": delivered]]),
        ], threadId: "am-codex")),
        ("codex item_completed", CodexSessionTranscriptReader.parse(lines: [
            jsonLine(["type": "event_msg", "payload": ["type": "item_completed", "item": [
                "type": "UserMessage", "content": [["type": "text", "text": delivered]]]]]),
        ], threadId: "am-codex-item")),
        ("pi", PiSessionTranscriptReader.parse(lines: [
            jsonLine(["type": "message", "message": ["role": "user", "content": [["type": "text", "text": delivered]]]]),
        ], threadId: "am-pi")),
    ]
    for (route, transcript) in readers {
        assertAgentMessage(replay(transcript, route: route), route: route, expected: expected)
    }

    // 6. The Claude app's own session lines, as its files carry them: a
    //    desktop cross-session message after a system reminder, Claude Code's
    //    peer message (logged `isMeta`, wrapped in a sentence and a reminder
    //    for the model), a side-sessions note, and a background note.
    let desktop = ClaudeSessionTranscriptReader.parse(lines: [
        jsonLine(["type": "user", "isSidechain": false, "message": ["role": "user",
            "content": "<system-reminder>\nREMINDER_SECRET\n</system-reminder>\n" + crossSession]]),
    ], threadId: "am-desktop")
    assertAgentMessage(replay(desktop, route: "claude desktop"), route: "claude desktop",
                       expected: AgentMessagePayload(origin: .crossSession, senderName: "Film review & notes",
                                                     text: "Frames 40-90 look good."))
    let peer = ClaudeSessionTranscriptReader.parse(lines: [
        jsonLine(["type": "user", "isSidechain": false, "isMeta": true,
                  "origin": ["kind": "peer", "from": "uds:/tmp/cc/1.sock", "name": "Docs pass", "body": "Done with the README."],
                  "message": ["role": "user", "content":
                    "Another Claude session sent a message:\n" + peerElement
                    + "\n\nThis came from another Claude session — not typed by your user. PEER_INSTRUCTION_SECRET"]]),
        // A peer line with nothing readable in it stays hidden.
        jsonLine(["type": "user", "isSidechain": false, "isMeta": true,
                  "origin": ["kind": "peer", "from": "x"], "message": ["role": "user", "content": "PEER_UNREADABLE"]]),
    ], threadId: "am-peer")
    let peerDocument = replay(peer, route: "claude peer")
    assertAgentMessage(peerDocument, route: "claude peer",
                       expected: AgentMessagePayload(origin: .peer, senderName: "Docs pass", text: "Done with the README."))
    let peerJSON = String(decoding: try! JSONEncoder().encode(peerDocument), as: UTF8.self)
    for secret in ["PEER_INSTRUCTION_SECRET", "PEER_UNREADABLE", "Another Claude session sent"] {
        expect(!peerJSON.contains(secret), "agent message (claude peer): \(secret) crossed into the transcript")
    }
    let hostNotes = ClaudeSessionTranscriptReader.parse(lines: [
        jsonLine(["type": "user", "isSidechain": false, "message": ["role": "user",
            "content": "<system-reminder>\nREMINDER\n</system-reminder>\n" + side]]),
        jsonLine(["type": "user", "isSidechain": false, "message": ["role": "user", "content": background]]),
    ], threadId: "am-host-notes")
    let noteDocument = replay(hostNotes, route: "claude host notes")
    expect(noteDocument.entries.map(\.role) == [.system, .user],
           "agent message (claude host notes): a side-sessions note is a system notice and a background note a turn, got \(noteDocument.entries.map(\.role))")
    let noticeText = noteDocument.entries.first?.blocks.compactMap { block -> String? in
        guard case let .notice(notice) = block.payload else { return nil }
        return notice.message.map { if case let .text(text) = $0 { return text }; return "" }.joined()
    }.first
    expect(noticeText == "None of the sessions you started is working now.",
           "agent message (claude host notes): the side-sessions notice must carry its first sentence only, got \(noticeText ?? "nil")")
    let noteJSON = String(decoding: try! JSONEncoder().encode(noteDocument), as: UTF8.self)
    expect(!noteJSON.contains("side-sessions-event") && !noteJSON.contains("Read each one"),
           "agent message (claude host notes): the side-sessions markup or its model-facing rest reached the document")
    expect(noteDocument.entries.last?.blocks.map(\.kind) == [.agentMessage],
           "agent message (claude host notes): a background note must draw as a message card")

    // 7. The SENDER's restored row: its `array_message_agent` call replays the
    //    message text on the host-local channel, the one argument its live row
    //    carries, so the restored row says what was sent ("Messaged an agent" —
    //    the target's name came from the host's reply, which no session file
    //    keeps). Claude and pi session files carry the call's arguments.
    let sent = "Rerun the failing leg.\nThen report the diff."
    let callArguments: [String: Any] = ["agentId": senderID.uuidString, "text": sent, "idempotencyKey": "m1"]
    let senderSessions: [(String, RehydratedTranscript)] = [
        ("claude", ClaudeSessionTranscriptReader.parse(lines: [
            jsonLine(["type": "user", "isSidechain": false, "message": ["role": "user", "content": "message the child"]]),
            jsonLine(["type": "assistant", "isSidechain": false, "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu-msg", "name": "mcp__array_workspace__array_message_agent", "input": callArguments]]]]),
        ], threadId: "am-sender-claude")),
        ("pi", PiSessionTranscriptReader.parse(lines: [
            jsonLine(["type": "message", "message": ["role": "user", "content": [["type": "text", "text": "message the child"]]]]),
            jsonLine(["type": "message", "message": ["role": "assistant", "content": [
                ["type": "toolCall", "id": "pi-msg", "name": "array_message_agent", "arguments": callArguments]]]]),
        ], threadId: "am-sender-pi")),
    ]
    for (route, transcript) in senderSessions {
        let fields = transcript.steps.flatMap { step -> [(key: String, value: String)] in
            guard case let .observation(.toolDetail(_, detail)) = step, detail.phase == .started else { return [] }
            return detail.fields
        }
        expect(fields.contains { $0.key == AgentToolDetailObservation.messageTextKey && $0.value == sent },
               "agent message (\(route) sender restore): the restored call must carry the message text, got \(fields)")
        expect(!fields.contains { $0.value.contains("m1") || $0.value == senderID.uuidString },
               "agent message (\(route) sender restore): the key or the target id crossed with the text: \(fields)")
    }

    print("Agent message transcript checks passed: envelope escaping round-trips, plain and look-alike prompts stay verbatim, six malformed envelopes fall back with nothing lost, the Claude app's cross-session/peer/background messages map to their sender and its side-sessions note to a quiet notice; live and claude/codex/pi rehydrated turns project one agent-message card and no user prose")
}
