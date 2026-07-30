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
