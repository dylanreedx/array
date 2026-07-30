import ContinuumRevivedAgentContent
import Foundation

private func parserID(_ raw: String) -> AgentNodeID {
    guard let id = AgentNodeID(rawValue: raw) else { fail("invalid parser check ID: \(raw)") }
    return id
}

func runMarkupParserChecks() {
    let parser: any AgentMarkupParsing = MarkdownAgentMarkupParser()
    let entryID = parserID("entry:parser-seam")
    let source = "The indexer keeps one open segment per shard."

    let first = parser.parse(source, entryID: entryID, previous: [])
    expect(first.diagnostics.isEmpty, "plain paragraph parse produced diagnostics: \(first.diagnostics)")
    expect(first.blocks.count == 1, "plain source must parse to exactly one semantic block")
    guard let paragraph = first.blocks.first else { fail("plain paragraph block is missing") }
    expect(paragraph.kind == .paragraph, "plain source must produce paragraph kind")
    expect(paragraph.payload == .paragraph([.text(source)]),
           "plain source must produce one exact AgentInline.text run")
    expect(paragraph.children.isEmpty && paragraph.sourceRange == nil,
           "plain paragraph seam must not invent children or a source range")

    let priorID = parserID("block:existing-paragraph")
    let prior = AgentBlock(id: priorID, kind: .paragraph, payload: .paragraph([.text("partial")]))
    let repeated = parser.parse(source, entryID: entryID, previous: [prior])
    expect(repeated.blocks.first?.id == priorID,
           "reparsing a plain paragraph must preserve its previous stable semantic ID")

    let maximumLengthEntryID = parserID(String(repeating: "e", count: 512))
    let longScope = parser.parse(source, entryID: maximumLengthEntryID, previous: [])
    expect(longScope.diagnostics.isEmpty && longScope.blocks.count == 1,
           "a valid entry ID beyond the derived-child scope bound must not drop plain source")
    expect(longScope.blocks.first?.payload == .paragraph([.text(source)]),
           "long entry scopes must preserve the exact parsed paragraph")
    expect(longScope.blocks.first?.id != maximumLengthEntryID,
           "a long entry scope must still receive a distinct semantic block ID")
    let longScopeRepeated = parser.parse(source, entryID: maximumLengthEntryID, previous: [])
    expect(longScopeRepeated.blocks.first?.id == longScope.blocks.first?.id,
           "the compact parser ID for a long entry scope must be deterministic")

    let unsupportedSource = "# Heading"
    let unsupported = parser.parse(unsupportedSource, entryID: entryID, previous: first.blocks)
    expect(unsupported.blocks.count == 1,
           "unsupported Markdown structure must remain present as one semantic block")
    guard let opaque = unsupported.blocks.first else { fail("unsupported Markdown fallback block is missing") }
    expect(opaque.kind == .unknown,
           "the paragraph-only seam must not flatten a Markdown heading into prose")
    expect(opaque.payload == .opaque(.init(
        debugLabel: "markdown.unsupported-structure",
        value: .string(unsupportedSource)
    )), "unsupported Markdown fallback must preserve the exact source losslessly")
    expect(unsupported.diagnostics.map(\.code) == ["markdown.unsupported-structure"],
           "unsupported Markdown structure must produce one owned diagnostic")

    let unsupportedRepeated = parser.parse(
        "# Heading extended",
        entryID: entryID,
        previous: unsupported.blocks
    )
    expect(unsupportedRepeated.blocks.first?.id == opaque.id,
           "reparsing unsupported Markdown must preserve its previous stable semantic ID")

    // Required negative witness observed red against this final check: changing
    // the adapter's paragraph payload to `.paragraph([.text(paragraph.plainText + "!")])`
    // made `plain source must produce one exact AgentInline.text run` fail with
    // exit 1. Restoring the exact AST-derived text returned the leg to green.
    print("Markup parser checks passed: owned seam converts one plain CommonMark paragraph to a stable semantic block and diagnoses unsupported structure")
}
