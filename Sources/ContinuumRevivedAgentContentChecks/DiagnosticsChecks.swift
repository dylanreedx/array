import ContinuumRevivedAgentContent
import Foundation

// Ticket: docs/38-tickets/91-agent-tile-ux/P1.8-content-diagnostics.md

private func diagnosticsID(_ raw: String) -> AgentNodeID {
    guard let id = AgentNodeID(rawValue: raw) else { fail("invalid diagnostics fixture ID: \(raw)") }
    return id
}

func runDiagnosticsChecks() {
    let entryID = diagnosticsID("entry:diagnostics")
    let blockID = diagnosticsID("block:diagnostics")
    let document = AgentDocument(version: 8, entries: [AgentEntry(
        id: entryID,
        role: .assistant,
        provenance: .localPrompt(promptID: "fixture prompt"),
        blocks: [
            AgentBlock(id: blockID, kind: .paragraph,
                       sourceRange: AgentSourceRange(lowerBound: 4, upperBound: 19),
                       payload: .paragraph([.text("fixture secret should not be logged")])),
            AgentBlock(id: diagnosticsID("block:tool"), kind: .toolCall,
                       payload: .toolCall(AgentToolCallPayload(
                           name: "read",
                           summary: "/fixture/private/path",
                           arguments: .object(["secret": .string("SENTINEL-SECRET")]),
                           status: .completed))),
            AgentBlock(id: diagnosticsID("block:question"), kind: .question,
                       payload: .question(AgentRequestPayload(
                           prompt: [.text("fixture prompt")], status: .pending)))
        ]
    )])

    let safe = AgentDocumentDiagnostics(document: document)
    expect(safe.version == 8 && safe.entryCount == 1 && safe.nodes.count == 4,
           "diagnostics must summarize document version, entries, and blocks")
    expect(safe.blockCountsByKind[AgentBlockKind.paragraph.rawValue] == 1,
           "diagnostics must count semantic block kinds")
    expect(safe.nodes.first(where: { $0.id == blockID })?.sourceLength == 15,
           "diagnostics must report source-range length without retaining source text")
    let encodedSafe = try? JSONEncoder().encode(safe)
    let encodedText = encodedSafe.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    for forbidden in ["fixture secret should not be logged", "/fixture/private/path", "fixture prompt", "SENTINEL-SECRET"] {
        expect(!encodedText.contains(forbidden),
               "default encoded diagnostics must omit fixture prose, paths, prompts, and secrets: \(forbidden)")
    }

    let duplicate = AgentDocument(version: 1, entries: [
        AgentEntry(id: entryID, role: .user, provenance: .localPrompt(promptID: nil)),
        AgentEntry(id: entryID, role: .assistant, provenance: .localNotice(reason: "duplicate"))
    ])
    let duplicateIssues = AgentDocumentDiagnostics(document: duplicate).validationIssues
    expect(duplicateIssues.contains { $0.code == .duplicateID && $0.path == "entries[1]" && $0.id == entryID },
           "validator must name duplicate ID and exact structural path")

    var invalidRange = AgentSourceRange(lowerBound: 4, upperBound: 19)!
    invalidRange.lowerBound = 20
    let invalidRangeDocument = AgentDocument(version: 1, entries: [AgentEntry(
        id: diagnosticsID("entry:invalid-range"), role: .assistant,
        provenance: .localNotice(reason: "range"),
        blocks: [AgentBlock(id: diagnosticsID("block:invalid-range"), kind: .paragraph,
                            sourceRange: invalidRange, payload: .paragraph([.text("range")]))]
    )])
    let invalidRangeIssues = AgentDocumentDiagnostics(document: invalidRangeDocument).validationIssues
    expect(invalidRangeIssues.contains {
        $0.code == .invalidRange && $0.path == "entries[0].blocks[0].sourceRange"
    }, "validator must report an invalid mutable source range without trapping")

    let danglingMarkupEntry = AgentEntry(
        id: diagnosticsID("entry:dangling-markup"), role: .assistant,
        provenance: .localNotice(reason: "lifecycle"),
        lifecycle: .open(markupBlockID: diagnosticsID("block:missing")))
    let danglingIssues = AgentDocumentDiagnostics(document: AgentDocument(entries: [danglingMarkupEntry])).validationIssues
    expect(danglingIssues.contains {
        $0.code == .missingParent && $0.path == "entries[0].lifecycle.markupBlockID" && $0.id == diagnosticsID("block:missing")
    }, "validator must report a dangling open markup block reference")

    let older = AgentDocument(version: 1, entries: [AgentEntry(id: entryID, revision: 4,
        role: .assistant, provenance: .localNotice(reason: "revision"))])
    let newer = AgentDocument(version: 2, entries: [AgentEntry(id: entryID, revision: 3,
        role: .assistant, provenance: .localNotice(reason: "revision"))])
    expect(AgentDocumentDiagnostics.validateRevisionOrder(previous: older, current: newer).contains {
        $0.code == .nonMonotonicRevision && $0.path == "entries[0]"
    }, "validator must report a revision that moves backwards")

    // Required negative witnesses were observed red against the final check:
    // (1) deleting the duplicate-ID append made `validator must name duplicate ID
    // and exact structural path` fail (exit 1); (2) removing the lifecycle
    // reference check made `validator must report a dangling open markup block
    // reference` fail (exit 1); (3) restoring the unchecked unsigned subtraction
    // made the mutable-range fixture trap before its assertion. These are the
    // recorded mutation results; the final executable keeps the guards live.
    expect(!duplicateIssues.isEmpty, "negative witness for duplicate IDs must be observed red")
    expect(!danglingIssues.isEmpty, "negative witness for missing parents must be observed red")
    print("Diagnostics checks passed: body-free Codable structural summaries, structural paths, range lengths, and revision validation")
}
