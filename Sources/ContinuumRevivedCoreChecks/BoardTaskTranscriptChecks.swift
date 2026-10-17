import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

// A board task sent to an agent. The composer hands the agent
// `BoardTaskContext.promptText` — title, an "Array task reference" carrying the
// board and card UUIDs and the observed revision, the task body, and the user's
// own instructions — and the transcript used to print all of it in the user's
// bubble verbatim. These witnesses assert what reaches the persisted, syncable
// document on every route a user turn takes into it: the live send, and the
// claude / codex / pi session readers a relaunch rehydrates from.
func runBoardTaskTranscriptChecks() {
    let boardID = UUID()
    let card = BoardCard(
        id: UUID(), columnId: UUID(), position: FracIndex(value: 0.5),
        title: "RST-42 Cart total is off by a cent",
        body: "## Rounding\nThe cart rounds each line before summing.\n\nRepro: three items at 0.335.",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let context = BoardTaskContext(boardID: boardID, card: card, revision: 17, imageAttachmentIDs: [])
    let instructions = "Keep the fix small and add a test."
    let promptText = context.promptText(additionalInstructions: instructions)
    let forbidden = ["boardId", "cardId", "observedRevision", "Array task reference",
                     boardID.uuidString.lowercased(), card.id.uuidString.lowercased()]
    let taskKind = AgentBlockKind(rawValue: "task-reference")!

    // The agent still receives the whole envelope, unchanged, from every adapter.
    let prompt = AgentPrompt(promptText)
    expect(ClaudeAgentRunner.promptArgument(prompt) == promptText,
           "task transcript: claude must receive the task envelope verbatim")
    expect(CodexCLIBackend.promptArgument(prompt) == promptText,
           "task transcript: codex must receive the task envelope verbatim")
    expect(PiRpcAgentRunner.promptPayloadText(prompt) == promptText,
           "task transcript: pi must receive the task envelope verbatim")

    func assertProjectsAsTask(_ document: AgentDocument, route: String, expectInstructions: Bool = true) {
        let json = String(decoding: try! JSONEncoder().encode(document), as: UTF8.self)
        for word in forbidden {
            expect(!json.contains(word),
                   "task transcript (\(route)): the user's turn still carries '\(word)' — the raw task envelope reached the document: \(json)")
        }
        guard let entry = document.entries.last(where: { $0.role == .user }) else {
            expect(false, "task transcript (\(route)): no user entry was projected"); return
        }
        let kinds = entry.blocks.map(\.kind)
        expect(kinds.first == taskKind,
               "task transcript (\(route)): the user turn must lead with a task-reference block, got \(kinds.map(\.rawValue))")
        expect(json.contains(card.title),
               "task transcript (\(route)): the task block lost the card title")
        expect(json.contains("The cart rounds each line before summing."),
               "task transcript (\(route)): the task block lost the description's first line")
        let prose = entry.blocks.compactMap { block -> String? in
            guard case let .paragraph(inlines) = block.payload else { return nil }
            return inlines.map { if case let .text(t) = $0 { return t }; return "" }.joined()
        }
        if expectInstructions {
            expect(prose.count == 1 && prose[0].hasPrefix(instructions),
                   "task transcript (\(route)): the user's own instructions must be the turn's only prose, got \(prose)")
        }
        expect(!prose.joined().contains("Repro: three items"),
               "task transcript (\(route)): the task body must not be printed as the user's prose")
        // Persisted form: the snapshot decodes back to the same document.
        let decoded = try? JSONDecoder().decode(AgentDocument.self, from: Data(json.utf8))
        expect(decoded == document, "task transcript (\(route)): the projected document does not survive a persistence round trip")
    }

    // 1. Live send.
    var live = AgentTranscriptProjection(threadId: "task-live")
    try! live.appendUserPrompt(id: AgentNodeID(rawValue: "submission:task-live")!, prompt: prompt)
    assertProjectsAsTask(live.document, route: "live send")

    // 1b. Task with no instructions: the chip alone, no empty prose block.
    var bare = AgentTranscriptProjection(threadId: "task-bare")
    try! bare.appendUserPrompt(id: AgentNodeID(rawValue: "submission:task-bare")!,
                               prompt: AgentPrompt(context.promptText(additionalInstructions: "  ")))
    assertProjectsAsTask(bare.document, route: "task without instructions", expectInstructions: false)
    expect(bare.document.entries.first?.blocks.count == 1,
           "task transcript: a task sent with no instructions must project the task block alone, got \(bare.document.entries.first?.blocks.map(\.kind.rawValue) ?? [])")

    // 2. Relaunch: each CLI's own session file, read back and replayed exactly
    //    as the tile does (`.userPrompt(text)` → `appendUserPrompt(text)`).
    func jsonLine(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    // Claude receives image/file references as trailing `@path` lines; a
    // rehydrated turn reads them back as part of the text.
    let claudeText = promptText + "\n@/tmp/proof.png"
    let routes: [(String, RehydratedTranscript)] = [
        ("claude rehydration", ClaudeSessionTranscriptReader.parse(lines: [
            jsonLine(["type": "user", "isSidechain": false, "message": ["role": "user", "content": claudeText]])
        ], threadId: "task-claude")),
        ("codex rehydration", CodexSessionTranscriptReader.parse(lines: [
            jsonLine(["type": "event_msg", "payload": ["type": "user_message", "message": promptText]])
        ], threadId: "task-codex")),
        ("pi rehydration", PiSessionTranscriptReader.parse(lines: [
            jsonLine(["type": "message", "message": ["role": "user", "content": [["type": "text", "text": promptText]]]])
        ], threadId: "task-pi")),
    ]
    for (route, transcript) in routes {
        var projection = AgentTranscriptProjection(threadId: route)
        var replayed = 0
        for step in transcript.steps {
            if case let .userPrompt(text) = step { projection.appendUserPrompt(text); replayed += 1 }
        }
        expect(replayed == 1, "task transcript (\(route)): the reader did not yield the user turn")
        assertProjectsAsTask(projection.document, route: route)
    }

    // 3. Generator → parser round trip, beside each other in BoardTaskContent.
    //    Shapes: body + instructions, no body, no instructions, neither, and a
    //    body that itself quotes the instructions heading.
    let shapes: [(body: String, instructions: String)] = [
        (card.body, instructions),
        ("", "Just do it."),
        ("Only a body.", ""),
        ("", ""),
        ("Template:\n\n# Additional instructions\nfill me in", "My real ask."),
    ]
    for (index, shape) in shapes.enumerated() {
        var shaped = card
        shaped.body = shape.body
        let shapedContext = BoardTaskContext(boardID: boardID, card: shaped, revision: UInt64(index), imageAttachmentIDs: [])
        let text = shapedContext.promptText(additionalInstructions: shape.instructions)
        guard let parsed = BoardTaskPromptEnvelope.parse(text) else {
            expect(false, "task envelope round trip \(index): the parser refused the generator's own output: \(text)"); continue
        }
        expect(parsed.title == card.title && parsed.boardID == boardID && parsed.cardID == card.id
                && parsed.revision == UInt64(index) && parsed.body == shape.body
                && parsed.additionalInstructions == shape.instructions,
               "task envelope round trip \(index): parse(promptText) drifted from its inputs: \(parsed)")
    }
    expect(BoardTaskPromptEnvelope.parse(promptText)?.transcriptReference
            == AgentTaskReferencePayload(title: card.title, summary: "The cart rounds each line before summing."),
           "task envelope: the transcript reference must carry the title and the body's first sentence, skipping its heading")

    // 4. Negative control: prose that merely LOOKS like a task heading is the
    //    user's own text and stays verbatim.
    let lookalike = "# Task: write the release notes\n\nboardId: is a field name I made up"
    var plain = AgentTranscriptProjection(threadId: "task-lookalike")
    try! plain.appendUserPrompt(id: AgentNodeID(rawValue: "submission:lookalike")!, prompt: AgentPrompt(lookalike))
    let plainBlocks = plain.document.entries.first?.blocks ?? []
    expect(plainBlocks.map(\.kind) == [.paragraph] && plainBlocks.first?.payload == .paragraph([.text(lookalike)]),
           "task transcript: a user's own '# Task:' prose must stay a verbatim paragraph, got \(plainBlocks)")

    print("Board task transcript checks passed: every adapter receives the envelope verbatim; live, no-instruction, and claude/codex/pi rehydrated turns project a task block plus the user's own words, with no board/card ids or revision in the persisted document; generator → parser round-trips five body/instruction shapes; look-alike prose stays verbatim")
}
