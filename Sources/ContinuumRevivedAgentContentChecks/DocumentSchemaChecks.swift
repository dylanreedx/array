import ContinuumRevivedAgentContent
import Foundation

// Ticket: docs/38-tickets/91-agent-tile-ux/P1.1-document-schema.md

private func nodeID(_ value: String) -> AgentNodeID {
    guard let id = AgentNodeID(rawValue: value) else { fail("fixture node id \(value) is invalid") }
    return id
}

private func assertSendable<T: Sendable>(_: T.Type) {}
private func assertCodable<T: Codable>(_: T.Type) {}

func runDocumentSchemaChecks() {
    assertSendable(AgentDocument.self)
    assertCodable(AgentDocument.self)
    assertSendable(AgentBlockPayload.self)
    assertCodable(AgentBlockPayload.self)
    assertSendable(AgentInline.self)
    assertCodable(AgentInline.self)

    let richInline: [AgentInline] = [
        .text("Read "),
        .emphasis([.text("carefully")]),
        .text(" and "),
        .strong([.text("verify")]),
        .softBreak,
        .code("swift build"),
        .text(" at "),
        .link(destination: "https://example.invalid/docs", title: "Docs", children: [.text("the guide")]),
        .hardBreak,
        .text("Done.")
    ]
    let item = AgentBlock(
        id: nodeID("block.list-item.1"),
        revision: 2,
        kind: .listItem,
        sourceRange: AgentSourceRange(lowerBound: 12, upperBound: 48),
        payload: .listItem,
        children: [
            AgentBlock(
                id: nodeID("block.paragraph.1"),
                revision: 1,
                kind: .paragraph,
                payload: .paragraph(richInline)
            )
        ]
    )
    let document = AgentDocument(version: 7, entries: [
        AgentEntry(
            id: nodeID("entry.user.1"),
            revision: 1,
            role: .user,
            provenance: .localPrompt(promptID: "prompt-1"),
            blocks: [AgentBlock(
                id: nodeID("block.user.1"),
                kind: .paragraph,
                payload: .paragraph([.text("Inspect the change")])
            )]
        ),
        AgentEntry(
            id: nodeID("entry.assistant.1"),
            revision: 4,
            role: .assistant,
            provenance: .providerItem(provider: "fixture", itemID: "item-7"),
            blocks: [
                AgentBlock(id: nodeID("block.heading.1"), kind: .heading, payload: .heading(level: 2, content: [.text("Result")])),
                AgentBlock(id: nodeID("block.list.1"), kind: .list, payload: .list(.init(ordered: true, start: 3)), children: [item]),
                AgentBlock(id: nodeID("block.quote.1"), kind: .quote, payload: .quote, children: [AgentBlock(id: nodeID("block.quote.p"), kind: .paragraph, payload: .paragraph([.text("Evidence")]))]),
                AgentBlock(id: nodeID("block.rule.1"), kind: .thematicBreak, payload: .thematicBreak),
                AgentBlock(id: nodeID("block.code.1"), kind: .fencedCode, payload: .fencedCode(.init(language: "swift", code: "print(1)", isComplete: false))),
                AgentBlock(id: nodeID("block.tool.1"), kind: .toolCall, payload: .toolCall(.init(name: "read", summary: "Read a fixture", arguments: .object(["path": .string("fixture.md")]), status: .inProgress))),
                AgentBlock(id: nodeID("block.output.1"), kind: .commandOutput, payload: .commandOutput(.init(text: "ok", exitCode: 0, status: .completed))),
                AgentBlock(id: nodeID("block.plan.1"), kind: .plan, payload: .plan(.init(title: "Two steps", status: .pending)), children: [item]),
                AgentBlock(id: nodeID("block.diff.1"), kind: .diff, payload: .diff(.init(text: "@@ -1 +1 @@", language: "diff"))),
                AgentBlock(id: nodeID("block.approval.1"), kind: .approval, payload: .approval(.init(prompt: [.text("Allow?")], status: .pending, choices: ["Allow", "Deny"]))),
                AgentBlock(id: nodeID("block.question.1"), kind: .question, payload: .question(.init(prompt: [.text("Which option?")], status: .pending, choices: ["A", "B"]))),
                AgentBlock(id: nodeID("block.image.1"), kind: .image, payload: .image(.init(
                    attachment: .init(id: AgentImageAttachmentID(rawValue: "image-1")!, displayName: "sketch.png", contentType: "image/png", byteCount: 12, pixelWidth: 2, pixelHeight: 3),
                    caption: [.text("Sketch")]
                ))),
                AgentBlock(id: nodeID("block.gallery.1"), kind: .imageGallery, payload: .imageGallery(.init(images: [
                    .init(attachment: .init(id: AgentImageAttachmentID(rawValue: "image-2")!, displayName: "a.jpg")),
                    .init(attachment: .init(id: AgentImageAttachmentID(rawValue: "image-3")!, displayName: "b.jpg"))
                ]))),
                AgentBlock(id: nodeID("block.error.1"), kind: .error, payload: .error(.init(message: "Runner stopped", code: "runner.exit", isRecoverable: true))),
                AgentBlock(id: nodeID("block.notice.1"), kind: .notice, payload: .notice(.init(message: [.text("Detached")], status: .interrupted))),
                AgentBlock(id: nodeID("block.unknown.1"), kind: AgentBlockKind(rawValue: "provider.future-card")!, payload: .opaque(.init(debugLabel: "future-card", value: .object(["version": .integer(2), "enabled": .bool(true), "ratio": .number(0.5), "items": .array([.null, .string("value")])]))))
            ]
        ),
        AgentEntry(id: nodeID("entry.notice.1"), role: .system, provenance: .localNotice(reason: "detached")),
        AgentEntry(id: nodeID("entry.reasoning.1"), role: .reasoning, provenance: .providerItem(provider: "fixture", itemID: nil))
    ])

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
        let encoded = try encoder.encode(document)
        let decoded = try JSONDecoder().decode(AgentDocument.self, from: encoded)
        expect(decoded == document, "representative mixed AgentDocument must round-trip through JSON exactly")
        let reencoded = try encoder.encode(decoded)
        expect(reencoded == encoded, "representative mixed AgentDocument JSON bytes must be stable after round-trip")
    } catch {
        fail("representative mixed AgentDocument JSON round-trip failed: \(error)")
    }

    let builtIns: [AgentBlockKind] = [
        .paragraph, .heading, .list, .listItem, .quote, .thematicBreak, .fencedCode,
        .toolCall, .commandOutput, .plan, .diff, .approval, .question, .image, .imageGallery, .error, .notice, .unknown
    ]
    expect(Set(builtIns.map(\.rawValue)).count == 18, "all 18 built-in semantic block kinds must be distinct")
    expect(AgentBlockKind(rawValue: "extension.vendor-card.v2") != nil, "namespaced future block kind must be accepted")

    let invalidKinds = ["", "Paragraph", "tool call", "tool..call", "tool-", "_tool", "éclair"]
    expect(invalidKinds.allSatisfy { AgentBlockKind(rawValue: $0) == nil },
           "invalid block kind syntax must be rejected: \(invalidKinds.filter { AgentBlockKind(rawValue: $0) != nil })")
    expect(AgentNodeID(rawValue: "") == nil && AgentNodeID(rawValue: "line\nbreak") == nil,
           "empty/control-bearing node identities must be rejected")
    expect(AgentSourceRange(lowerBound: 9, upperBound: 8) == nil,
           "a source range whose upper bound precedes its lower bound must be rejected")

    // Codable must not provide an unchecked construction path around validation.
    for invalidJSON in ["\"Tool Call\"", "\"tool..call\""] {
        expect((try? JSONDecoder().decode(AgentBlockKind.self, from: Data(invalidJSON.utf8))) == nil,
               "AgentBlockKind Codable accepted invalid semantic key \(invalidJSON)")
    }

    print("Document schema checks passed: 4 entry roles, 18 built-in block kinds, 17 typed built-in payloads plus an opaque fallback, 7 inline forms, image/gallery payloads, validated IDs/kinds/ranges, and exact mixed-document JSON round-trip")
}
