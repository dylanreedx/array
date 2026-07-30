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
    expect(mixedUnsupported.blocks.count == 3 && mixedUnsupported.blocks.map(\.kind) == [.heading, .thematicBreak, .paragraph],
           "thematic breaks in mixed Markdown must remain semantic blocks between their neighbors")
    expect(mixedUnsupported.blocks[1].payload == .thematicBreak,
           "thematic break must use its typed, childless payload")

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

    let unsupportedSource = "<section>opaque</section>"
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

private func allBlocks(_ roots: [AgentBlock]) -> [AgentBlock] {
    roots.flatMap { [$0] + allBlocks($0.children) }
}

private func maximumTreeDepth(_ roots: [AgentBlock], depth: Int = 0) -> Int {
    roots.map { block in
        block.children.isEmpty ? depth : maximumTreeDepth(block.children, depth: depth + 1)
    }.max() ?? depth
}

/// Mutates the final parser in an isolated package and proves the ordinary
/// ordered-list assertion turns red. The working tree remains untouched.
private func verifyOrderedListStartNegativeWitness() {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("continuum-list-start-witness-\(UUID().uuidString)", isDirectory: true)
    let copiedSources = temporaryRoot.appendingPathComponent("Sources/ContinuumRevivedAgentContent", isDirectory: true)
    let witnessSources = temporaryRoot.appendingPathComponent("Sources/ListStartWitness", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    do {
        try fileManager.createDirectory(
            at: temporaryRoot.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(
            at: repoRoot.appendingPathComponent("Sources/ContinuumRevivedAgentContent", isDirectory: true),
            to: copiedSources
        )
        try fileManager.createDirectory(at: witnessSources, withIntermediateDirectories: true)

        let parserURL = copiedSources.appendingPathComponent("MarkdownAgentMarkupParser.swift")
        var parserSource = try String(contentsOf: parserURL, encoding: .utf8)
        let preservingStart = "payload: .list(.init(ordered: true, start: Int(exactly: ordered.startIndex) ?? Int.max)),"
        let droppingStart = "payload: .list(.init(ordered: true)),"
        expect(parserSource.components(separatedBy: preservingStart).count == 2,
               "negative witness must find exactly one final ordered-list start conversion to mutate")
        parserSource = parserSource.replacingOccurrences(of: preservingStart, with: droppingStart)
        try parserSource.write(to: parserURL, atomically: true, encoding: .utf8)

        let package = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "ListStartNegativeWitness",
            platforms: [.macOS(.v13)],
            dependencies: [
                .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0")
            ],
            targets: [
                .target(
                    name: "ContinuumRevivedAgentContent",
                    dependencies: [.product(name: "Markdown", package: "swift-markdown")]
                ),
                .executableTarget(name: "ListStartWitness", dependencies: ["ContinuumRevivedAgentContent"])
            ]
        )
        """
        try package.write(
            to: temporaryRoot.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        let witness = #"""
        import ContinuumRevivedAgentContent
        import Foundation

        let parser = MarkdownAgentMarkupParser()
        let entryID = AgentNodeID(rawValue: "entry:list-start-negative-witness")!
        let parsed = parser.parse("3. Inner\n4. Next", entryID: entryID, previous: [])
        if parsed.blocks.first?.payload != .list(.init(ordered: true, start: 3)) {
            fputs("FAIL: ordered list must preserve its authored starting ordinal\n", stderr)
            Foundation.exit(1)
        }
        """#
        try witness.write(
            to: witnessSources.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )
    } catch {
        fail("cannot prepare isolated ordered-list start mutation: \(error)")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "swift", "run",
        "--package-path", temporaryRoot.path,
        "--scratch-path", temporaryRoot.appendingPathComponent(".build").path,
        "ListStartWitness"
    ]
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors

    do {
        try process.run()
    } catch {
        fail("cannot launch isolated ordered-list start mutation: \(error)")
    }
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let errorText = String(decoding: errorData, as: UTF8.self)
    let expectedFailure = "FAIL: ordered list must preserve its authored starting ordinal"
    expect(process.terminationStatus == 1,
           "dropping the ordered-list start must make the isolated check exit 1, got \(process.terminationStatus): \(errorText)")
    expect(errorText.contains(expectedFailure),
           "dropping the ordered-list start must fail the ordinal assertion, stderr was: \(errorText)")

    print("List/quote/rule negative witness passed: mutated production parser exited 1 at the ordinal assertion")
}

func runListQuoteRuleBlockChecks() {
    let parser = MarkdownAgentMarkupParser()
    let entryID = parserID("entry:list-quote-rule")
    let source = "- Outer\n\n  3. Inner\n  4. Next\n- [ ] Review task syntax\n\n" +
        "> Quoted paragraph\n>\n> - Quoted child\n\n---"
    let parsed = parser.parse(source, entryID: entryID, previous: [])
    expect(parsed.diagnostics.isEmpty,
           "supported list/quote/rule corpus produced diagnostics: \(parsed.diagnostics.map(\.code))")
    expect(parsed.blocks.map(\.kind) == [.list, .quote, .thematicBreak],
           "list, quote, and thematic break must preserve exact root order")
    guard parsed.blocks.count == 3,
          case let .list(outerList) = parsed.blocks[0].payload,
          outerList == .init(ordered: false),
          parsed.blocks[0].children.count == 2
    else { fail("unordered root list payload or item positions are missing") }

    let firstItem = parsed.blocks[0].children[0]
    let taskItem = parsed.blocks[0].children[1]
    expect(firstItem.kind == .listItem && firstItem.payload == .listItem &&
           firstItem.children.map(\.kind) == [.paragraph, .list],
           "first list item must own its paragraph and nested ordered list")
    guard case let .list(nestedList) = firstItem.children[1].payload else {
        fail("nested ordered-list payload is missing")
    }
    expect(nestedList == .init(ordered: true, start: 3),
           "ordered list must preserve its authored starting ordinal")
    expect(firstItem.children[1].children.map(\.kind) == [.listItem, .listItem] &&
           firstItem.children[1].children.allSatisfy { $0.children.map(\.kind) == [.paragraph] },
           "ordered list must preserve two item containers and their paragraph children")
    expect(taskItem.kind == .listItem && taskItem.children.map(\.kind) == [.paragraph],
           "task syntax must remain ordinary list content")
    expect(!allBlocks(parsed.blocks).contains { $0.kind == .approval || $0.kind == .question },
           "Markdown task checkboxes must never become interactive approvals or questions")
    guard case let .paragraph(taskText) = taskItem.children[0].payload else {
        fail("task list item paragraph is missing")
    }
    expect(inlinePlainText(taskText) == "[ ] Review task syntax",
           "task checkbox syntax and label must remain ordinary readable content")

    let blankItems = parser.parse("-\n- filled", entryID: parserID("entry:blank-items"), previous: [])
    expect(blankItems.blocks.count == 1 && blankItems.blocks[0].children.count == 2,
           "blank list items must preserve their structural position")
    expect(blankItems.blocks[0].children[0].kind == .listItem &&
           blankItems.blocks[0].children[0].children.isEmpty,
           "a blank list item must remain an empty item container, not disappear")

    let quote = parsed.blocks[1]
    expect(quote.payload == .quote && quote.children.map(\.kind) == [.paragraph, .list],
           "block quote must own its paragraph and nested list without flattening")
    expect(quote.children[1].children.map(\.kind) == [.listItem],
           "quoted list must retain its item container")
    expect(parsed.blocks[2].payload == .thematicBreak && parsed.blocks[2].children.isEmpty,
           "thematic break must be a typed leaf block")

    let repeated = parser.parse(source, entryID: entryID, previous: parsed.blocks)
    expect(allBlocks(repeated.blocks).map(\.id) == allBlocks(parsed.blocks).map(\.id),
           "reparsing nested structures must preserve every semantic node ID")

    let insertedSource = source.replacingOccurrences(
        of: "- [ ] Review task syntax",
        with: "- Newly inserted sibling\n- [ ] Review task syntax"
    )
    let afterInsertion = parser.parse(insertedSource, entryID: entryID, previous: parsed.blocks)
    guard afterInsertion.blocks.first?.children.count == 3 else {
        fail("sibling insertion did not preserve the enclosing list")
    }
    let preservedTask = afterInsertion.blocks[0].children[2]
    expect(preservedTask.id == taskItem.id &&
           preservedTask.children.first?.id == taskItem.children.first?.id,
           "inserting a sibling before a completed item must preserve that item's subtree IDs")
    expect(afterInsertion.blocks[0].children[1].id != taskItem.id,
           "a newly inserted sibling must not steal the completed following item's ID")

    let deepSource = String(repeating: "> ", count: 48) + "bounded"
    let deep = parser.parse(deepSource, entryID: parserID("entry:block-depth"), previous: [])
    expect(deep.diagnostics.map(\.code) == ["markdown.block-nesting-limit"],
           "excessive block nesting must produce one bounded structural diagnostic")
    expect(maximumTreeDepth(deep.blocks) <= 32,
           "excessive nesting must stop at the parser-owned semantic depth cap")
    guard let fallback = allBlocks(deep.blocks).last else { fail("deep nesting fallback disappeared") }
    expect(fallback.kind == .unknown && fallback.children.isEmpty,
           "depth overflow must become a safe opaque leaf rather than recurse further")
    guard case let .opaque(value) = fallback.payload,
          case let .string(literal) = value.value
    else { fail("depth fallback payload is missing") }
    expect(value.debugLabel == "markdown.block-nesting-limit" && literal.contains("bounded"),
           "depth fallback must preserve the remaining literal source")

    verifyOrderedListStartNegativeWitness()
    print("List/quote/rule checks passed: exact nested tree, ordinal, stable IDs, passive tasks, typed rule, and bounded fallback")
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
