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

    let structuredSource = "# Heading\n\nFirst paragraph.\n\nSecond paragraph."
    let structured = parser.parse(structuredSource, entryID: entryID, previous: [])
    expect(structured.diagnostics.isEmpty, "paragraphs and headings must parse without diagnostics")
    expect(structured.blocks.count == 3, "blank lines must separate two paragraphs without spacer blocks")
    expect(structured.blocks.map(\.kind) == [.heading, .paragraph, .paragraph],
           "Markdown block order must preserve heading and paragraph semantics")
    guard case let .heading(level, content) = structured.blocks[0].payload else {
        fail("ATX heading payload is missing")
    }
    expect(level == 1 && content == [.text("Heading")],
           "ATX heading must preserve level and inline content")
    expect(structured.blocks[1].id != structured.blocks[2].id,
           "two paragraphs must receive distinct stable semantic IDs")
    let reparsedStructured = parser.parse(structuredSource, entryID: entryID, previous: structured.blocks)
    expect(reparsedStructured.blocks.map(\.id) == structured.blocks.map(\.id),
           "reparsing two paragraphs and their heading must preserve every stable block ID")

    let mixedUnsupportedSource = "# Heading\n\n---\n\nBody paragraph."
    let mixedUnsupported = parser.parse(mixedUnsupportedSource, entryID: entryID, previous: [])
    expect(mixedUnsupported.blocks.count == 3 && mixedUnsupported.blocks.map(\.kind) == [.heading, .unknown, .paragraph],
           "unsupported structures in mixed Markdown must remain one block between neighboring semantic blocks")
    guard case let .opaque(mixedPayload) = mixedUnsupported.blocks[1].payload else {
        fail("mixed unsupported structure payload is missing")
    }
    expect(mixedPayload.value == .string("---"),
           "unsupported structure must preserve only its child literal, not the complete document")

    let setext = parser.parse("Setext title\n===\nBody", entryID: entryID, previous: [])
    guard case let .heading(setextLevel, setextContent) = setext.blocks.first?.payload else {
        fail("setext heading payload is missing")
    }
    expect(setextLevel == 1 && setextContent == [.text("Setext title")],
           "setext heading must map to level one with inline content")

    let encoded = try? JSONEncoder().encode(structured.blocks[0])
    let decoded = encoded.flatMap { try? JSONDecoder().decode(AgentBlock.self, from: $0) }
    expect(decoded == structured.blocks[0], "heading level and inline content must survive JSON round-trip")
    expect(inlinePlainText(content) == "Heading", "heading plain-text copy must expose only readable inline content")

    let unsupportedSource = "---"
    let unsupported = parser.parse(unsupportedSource, entryID: entryID, previous: [])
    guard let opaque = unsupported.blocks.first else { fail("unsupported Markdown fallback block is missing") }
    expect(opaque.kind == .unknown && unsupported.diagnostics.map(\.code) == ["markdown.unsupported-structure"],
           "unsupported structure must remain an opaque diagnosed semantic block")
    expect(opaque.payload == .opaque(.init(
        debugLabel: "markdown.unsupported-structure", value: .string(unsupportedSource)
    )), "unsupported Markdown fallback must preserve the exact source losslessly")

    // Required negative witness observed red against this final check: changing
    // the Heading conversion to `.paragraph` made the exact `[.heading, .paragraph,
    // .paragraph]` assertion fail with exit 1. Restoring semantic heading blocks
    // returned the leg to green.
    print("Markup parser checks passed: paragraphs, ATX/setext headings, stable IDs, round-trip, plain-text copy, and diagnosed fallback")
}

func runHeadingBlockChecks() {
    let parser = MarkdownAgentMarkupParser()
    let entryID = parserID("entry:heading-blocks")
    let parsed = parser.parse("## Section\n\nOne paragraph.\n\nTwo paragraphs.", entryID: entryID, previous: [])
    expect(parsed.diagnostics.isEmpty, "heading block corpus must be diagnostic-free")
    expect(parsed.blocks.map(\.kind) == [.heading, .paragraph, .paragraph],
           "heading and paragraph blocks must preserve source order")
    guard case let .heading(level, inline) = parsed.blocks[0].payload else {
        fail("heading block payload is missing")
    }
    expect(level == 2 && inline == [.text("Section")],
           "heading block must preserve its level and inline content")
    expect(parsed.blocks[1].id != parsed.blocks[2].id,
           "separate paragraphs must never share a semantic block ID")

    let roundTrip = try? JSONDecoder().decode(
        AgentBlock.self,
        from: JSONEncoder().encode(parsed.blocks[0])
    )
    expect(roundTrip == parsed.blocks[0], "heading block JSON round-trip must preserve hierarchy")
    expect(inlinePlainText(inline) == "Section", "heading plain-text copy must omit Markdown markers")

    // Required negative witness: changing Heading's payload to paragraph makes
    // the exact kind/level assertions above fail with exit 1.
    print("Heading block checks passed: hierarchy, paragraph separation, stable IDs, JSON round-trip, and plain-text copy")
}

private func paragraphInlines(_ parse: AgentMarkupParse, _ context: String) -> [AgentInline] {
    guard parse.blocks.count == 1,
          parse.blocks[0].kind == .paragraph,
          case let .paragraph(inlines) = parse.blocks[0].payload
    else { fail("\(context) did not produce exactly one semantic paragraph") }
    return inlines
}

private func inlinePlainText(_ inlines: [AgentInline]) -> String {
    inlines.map { inline in
        switch inline {
        case let .text(value), let .code(value): return value
        case let .emphasis(children), let .strong(children): return inlinePlainText(children)
        case let .link(_, _, children): return inlinePlainText(children)
        case .softBreak, .hardBreak: return "\n"
        }
    }.joined()
}

func runInlineMarkupChecks() {
    let parser = MarkdownAgentMarkupParser()
    let entryID = parserID("entry:inline-runs")
    let source = "Escaped \\*stars\\*; **strong with _nested emphasis_ and `literal * code`**.\n" +
        "soft continuation\nhard continuation  \nafter hard"
    let parse = parser.parse(source, entryID: entryID, previous: [])
    expect(parse.diagnostics.isEmpty,
           "supported inline markup produced diagnostics: \(parse.diagnostics.map(\.code))")
    let expected: [AgentInline] = [
        .text("Escaped *stars*; "),
        .strong([
            .text("strong with "),
            .emphasis([.text("nested emphasis")]),
            .text(" and "),
            .code("literal * code")
        ]),
        .text("."),
        .softBreak,
        .text("soft continuation"),
        .softBreak,
        .text("hard continuation"),
        .hardBreak,
        .text("after hard")
    ]
    let actual = paragraphInlines(parse, "nested inline source")
    expect(actual == expected,
           "escapes, nested marks, code, and break kinds must match the exact semantic AST; got \(actual)")
    expect(inlinePlainText(actual) == "Escaped *stars*; strong with nested emphasis and literal * code.\nsoft continuation\nhard continuation\nafter hard",
           "plain-text projection must preserve readable source content modulo Markdown delimiters")

    let unsupportedSource = "pré [label](https://example.invalid/path) post"
    let unsupported = parser.parse(unsupportedSource, entryID: entryID, previous: parse.blocks)
    expect(paragraphInlines(unsupported, "unsupported inline source") == [.text(unsupportedSource)],
           "an unsupported inline node must preserve its exact literal spelling and merge with adjacent text")
    expect(unsupported.diagnostics.map(\.code) == ["markdown.unsupported-inline"],
           "an unsupported inline node must emit one structural diagnostic")
    expect(!unsupported.diagnostics.map(\.code).contains(where: { $0.contains("example") || $0.contains("label") }),
           "inline diagnostics must not carry source text or destinations")
    expect(unsupported.blocks[0].id == parse.blocks[0].id,
           "adding inline semantics must not replace the existing paragraph identity")

    let deepSource = String(repeating: "*", count: 130) + "x" + String(repeating: "*", count: 130)
    let deep = parser.parse(deepSource, entryID: entryID, previous: unsupported.blocks)
    expect(deep.diagnostics.map(\.code) == ["markdown.inline-nesting-limit"],
           "over-deep supported marks must stop at the owned depth cap and produce one diagnostic")
    expect(inlinePlainText(paragraphInlines(deep, "deep inline source")).contains("x"),
           "the inline depth cap must preserve the nested source rather than dropping it")

    // Required negative witness: changing the `.hardBreak` conversion to
    // `.softBreak` makes the exact-AST assertion above fail (exit 1) with the
    // observed run reporting softBreak where hardBreak is required.
    print("Inline markup checks passed: exact escapes/nesting/code/break AST, readable projection, merged text, and lossless diagnosed fallback")
}
