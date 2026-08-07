import ContinuumRevivedAgentContent
import Foundation

private func streamingID(_ suffix: String) -> AgentNodeID {
    AgentNodeID(rawValue: "entry:streaming-\(suffix)")!
}

private func scalarPrefixes(_ source: String) -> [String] {
    let scalars = source.unicodeScalars
    return (0...scalars.count).map { count in
        String(String.UnicodeScalarView(scalars.prefix(count)))
    }
}

private func parseChunks(
    _ chunks: [String],
    parser: MarkdownAgentMarkupParser,
    entryID: AgentNodeID
) -> (StreamingMarkupBuffer, AgentMarkupParse) {
    var buffer = StreamingMarkupBuffer()
    var result = AgentMarkupParse(blocks: [])
    for chunk in chunks {
        buffer.append(chunk)
        result = parser.parse(buffer.source, entryID: entryID, previous: result.blocks)
    }
    return (buffer, result)
}

private func inlineVisibleText(_ inlines: [AgentInline]) -> String {
    inlines.map { inline in
        switch inline {
        case let .text(text), let .code(text): return text
        case let .emphasis(children), let .strong(children): return inlineVisibleText(children)
        case let .link(_, _, children): return inlineVisibleText(children)
        case .softBreak, .hardBreak: return "\n"
        }
    }.joined()
}

private func blockVisibleText(_ block: AgentBlock) -> String {
    let own: String
    switch block.payload {
    case let .paragraph(inlines): own = inlineVisibleText(inlines)
    case let .heading(_, inlines): own = inlineVisibleText(inlines)
    case let .fencedCode(code): own = code.code
    case let .opaque(opaque):
        if case let .string(value) = opaque.value { own = value } else { own = "" }
    default: own = ""
    }
    return ([own] + block.children.map(blockVisibleText)).joined(separator: "\n")
}

private func parsedVisibleText(_ parsed: AgentMarkupParse) -> String {
    parsed.blocks.map(blockVisibleText).joined(separator: "\n")
}

private func verifyStreamingAccumulationNegativeWitness() {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("continuum-streaming-buffer-witness-\(UUID().uuidString)", isDirectory: true)
    let copiedSources = temporaryRoot.appendingPathComponent("Sources/ContinuumRevivedAgentContent", isDirectory: true)
    let witnessSources = temporaryRoot.appendingPathComponent("Sources/ContinuumRevivedAgentContentChecks", isDirectory: true)
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

        let bufferURL = copiedSources.appendingPathComponent("StreamingMarkupBuffer.swift")
        var source = try String(contentsOf: bufferURL, encoding: .utf8)
        let correct = "chunks.append(delta)"
        expect(source.components(separatedBy: correct).count == 2,
               "negative witness must find exactly one source-accumulation expression")
        source = source.replacingOccurrences(of: correct, with: "chunks = [delta]")
        try source.write(to: bufferURL, atomically: true, encoding: .utf8)

        let package = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "StreamingBufferNegativeWitness",
            platforms: [.macOS(.v13)],
            dependencies: [
                .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0")
            ],
            targets: [
                .target(
                    name: "ContinuumRevivedAgentContent",
                    dependencies: [.product(name: "Markdown", package: "swift-markdown")]
                ),
                .executableTarget(
                    name: "ContinuumRevivedAgentContentChecks",
                    dependencies: ["ContinuumRevivedAgentContent"]
                )
            ]
        )
        """
        try package.write(to: temporaryRoot.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        // Run the actual final streaming-check source, not a smaller assertion
        // that could drift away from this gate. Only its recursive mutation is
        // disabled in the child process.
        try fileManager.copyItem(
            at: repoRoot.appendingPathComponent("Sources/ContinuumRevivedAgentContentChecks/StreamingMarkupChecks.swift"),
            to: witnessSources.appendingPathComponent("StreamingMarkupChecks.swift")
        )
        let harness = #"""
        import ContinuumRevivedAgentContent
        import Foundation

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                fputs("FAIL: \(message)\n", stderr)
                Foundation.exit(1)
            }
        }
        func fail(_ message: String) -> Never {
            fputs("FAIL: \(message)\n", stderr)
            Foundation.exit(1)
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        runStreamingMarkupChecks()
        """#
        try harness.write(to: witnessSources.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
    } catch {
        fail("cannot prepare isolated streaming-buffer mutation: \(error)")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "swift", "run", "--quiet",
        "--package-path", temporaryRoot.path,
        "--scratch-path", temporaryRoot.appendingPathComponent(".build").path,
        "ContinuumRevivedAgentContentChecks"
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["CONTINUUM_SKIP_STREAMING_NEGATIVE_WITNESS"] = "1"
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors
    do { try process.run() } catch { fail("cannot launch isolated streaming-buffer mutation: \(error)") }
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let errorText = String(decoding: errorData, as: UTF8.self)
    expect(process.terminationStatus == 1,
           "dropping accumulated source must make the final streaming check exit 1, got \(process.terminationStatus): \(errorText)")
    expect(errorText.contains("FAIL: two-delta accumulation lost source") ||
           errorText.contains("FAIL: coalescing parser requests must never coalesce semantic source"),
           "dropping accumulated source must fail a final streaming accumulation assertion, stderr was: \(errorText)")
    print("Streaming markup negative witness passed: mutated production source made the final streaming check exit 1")
}

func runStreamingMarkupChecks() {
    let parser = MarkdownAgentMarkupParser()
    let fixtures = [
        "**Strong 😀 text** and _emphasis_ with `code`.",
        "## Streaming heading\n\n- first\n- second",
        "[documentation](https://example.com/路径?q=one)",
        "Before\n\n```swift\nlet greeting = \"héllo 🌍\"\n```\n\nAfter"
    ]

    var checkedPrefixes = 0
    var checkedSplits = 0
    for (fixtureIndex, source) in fixtures.enumerated() {
        let entryID = streamingID("fixture-\(fixtureIndex)")
        let baseline = parser.parse(source, entryID: entryID, previous: [])
        let prefixes = scalarPrefixes(source)

        // Every Unicode-scalar prefix is independently safe to parse and has a
        // semantic representation whenever it contains something visible.
        // This inspects the parsed result rather than treating the raw buffer as
        // proof that renderers received content.
        for prefix in prefixes {
            var buffer = StreamingMarkupBuffer()
            buffer.append(prefix)
            expect(buffer.source == prefix,
                   "streaming source accumulation must preserve prefix bytes exactly")
            let parsed = parser.parse(buffer.source, entryID: entryID, previous: [])
            if prefix.contains(where: { !$0.isWhitespace }) {
                expect(!parsed.blocks.isEmpty,
                       "visible scalar prefix disappeared from the semantic AST: \(prefix.debugDescription)")
            }
            checkedPrefixes += 1
        }

        // Exercise every legal scalar split, parsing the first prefix before the
        // remainder. The completed owned AST (including semantic IDs) must equal
        // an unstreamed parse and therefore cannot depend on delta boundaries.
        for split in 0...source.unicodeScalars.count {
            let scalarView = source.unicodeScalars
            let boundary = scalarView.index(scalarView.startIndex, offsetBy: split)
            let chunks = [
                String(String.UnicodeScalarView(scalarView[..<boundary])),
                String(String.UnicodeScalarView(scalarView[boundary...]))
            ]
            let (buffer, streamed) = parseChunks(chunks, parser: parser, entryID: entryID)
            expect(buffer.source == source,
                   "two-delta accumulation lost source at scalar split \(split)")
            expect(streamed == baseline,
                   "completed AST depends on delta split \(split) for fixture \(fixtureIndex)")
            checkedSplits += 1
        }

        let scalarChunks = source.unicodeScalars.map(String.init)
        let scalarStream = parseChunks(scalarChunks, parser: parser, entryID: entryID)
        expect(scalarStream.0.source == source && scalarStream.1 == baseline,
               "one-scalar deltas must converge to the unstreamed AST")
    }

    // Unmatched inline syntax must remain literal text until its closing
    // delimiter/destination arrives. These are the vulnerable intermediate
    // states from the fixtures above, asserted against the semantic AST itself.
    let incompleteInlineCases = [
        "**Strong", "_emphasis", "`", "`code",
        "[", "[documentation]", "[documentation]("
    ]
    for (index, source) in incompleteInlineCases.enumerated() {
        let parsed = parser.parse(source, entryID: streamingID("incomplete-inline-\(index)"), previous: [])
        expect(parsedVisibleText(parsed) == source,
               "incomplete Markdown must remain visible literal text: \(source.debugDescription) became \(parsedVisibleText(parsed).debugDescription)")
    }

    let emptyOpenFence = parser.parse(
        "```swift\n",
        entryID: streamingID("empty-open-fence"),
        previous: []
    )
    guard case let .fencedCode(emptyCode)? = emptyOpenFence.blocks.first?.payload else {
        fail("an empty open fence disappeared from the semantic AST")
    }
    expect(!emptyCode.isComplete && emptyCode.language == "swift" && emptyCode.code.isEmpty,
           "an empty open fence must remain a typed code-in-progress block")

    let openFence = parser.parse(
        "```swift\nlet value = \"unfinished",
        entryID: streamingID("open-fence"),
        previous: []
    )
    guard case let .fencedCode(code)? = openFence.blocks.first?.payload else {
        fail("an open streaming fence disappeared instead of becoming code-in-progress")
    }
    expect(!code.isComplete && code.language == "swift" && code.code == "let value = \"unfinished",
           "an incomplete fence must retain its exact body and incomplete status")

    var buffer = StreamingMarkupBuffer()
    var scheduler = StreamingMarkupParseScheduler(maximumParsesPerSecond: 30)
    buffer.append("first")
    scheduler.requestParse()
    expect(scheduler.shouldParse(now: 10), "the first requested parse must run immediately")
    buffer.append(" second")
    scheduler.requestParse()
    expect(!scheduler.shouldParse(now: 10.01), "parser requests inside 30 Hz must coalesce")
    buffer.append(" third")
    scheduler.requestParse()
    expect(buffer.source == "first second third",
           "coalescing parser requests must never coalesce semantic source")
    expect(scheduler.shouldParse(now: 10.04) && !scheduler.hasPendingRequest,
           "a pending request must run after the interval and be consumed once")
    scheduler.requestParse()
    expect(scheduler.flush() && !scheduler.flush(),
           "finishing an entry must flush exactly one pending parser request")

    if ProcessInfo.processInfo.environment["CONTINUUM_SKIP_STREAMING_NEGATIVE_WITNESS"] != "1" {
        verifyStreamingAccumulationNegativeWitness()
    }
    print("Streaming markup checks passed: \(checkedPrefixes) scalar prefixes, \(checkedSplits) split points, literal partial syntax, deterministic final AST, open fence, and independent 30 Hz coalescing")
}
