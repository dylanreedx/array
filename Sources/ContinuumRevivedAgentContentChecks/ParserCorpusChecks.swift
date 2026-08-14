import ContinuumRevivedAgentContent
import Foundation

private func corpusInlineText(_ inlines: [AgentInline]) -> String {
    inlines.map { inline in
        switch inline {
        case let .text(value), let .code(value): return value
        case let .emphasis(children), let .strong(children): return corpusInlineText(children)
        case let .link(_, _, children): return corpusInlineText(children)
        case .softBreak, .hardBreak: return "\n"
        }
    }.joined()
}

/// Renderer-independent readable projection used by the closing parser gates.
/// Delimiters, link destinations, and container markers are intentionally not
/// copied: this is plain text, not a reconstruction of the Markdown source.
func parserPlainText(_ blocks: [AgentBlock]) -> String {
    func project(_ block: AgentBlock) -> String {
        let own: String
        switch block.payload {
        case let .paragraph(content): own = corpusInlineText(content)
        case let .heading(_, content): own = corpusInlineText(content)
        case let .fencedCode(code): own = code.code
        case let .toolCall(tool): own = [tool.name, tool.summary].compactMap { $0 }.joined(separator: "\n")
        case let .commandOutput(output): own = output.text
        case let .plan(plan): own = plan.title ?? ""
        case let .diff(diff): own = diff.text
        case let .approval(request), let .question(request): own = corpusInlineText(request.prompt)
        case let .image(image): own = image.attachment.displayName ?? ""
        case let .imageGallery(gallery): own = gallery.images.compactMap { $0.attachment.displayName }.joined(separator: "\n")
        case let .fileReferences(references): own = references.files.map(\.displayName).joined(separator: "\n")
        case let .error(error): own = error.message
        case let .notice(notice): own = corpusInlineText(notice.message)
        case let .opaque(opaque):
            if case let .string(value) = opaque.value { own = value } else { own = "" }
        case .list, .listItem, .quote, .thematicBreak: own = ""
        }
        return ([own] + block.children.map(project)).filter { !$0.isEmpty }.joined(separator: "\n")
    }
    return blocks.map(project).filter { !$0.isEmpty }.joined(separator: "\n")
}

private func corpusAllBlocks(_ roots: [AgentBlock]) -> [AgentBlock] {
    roots.flatMap { [$0] + corpusAllBlocks($0.children) }
}

private func corpusReplacing(_ pattern: String, in source: String, with replacement: String = "") -> String {
    let expression = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    return expression.stringByReplacingMatches(in: source, range: range, withTemplate: replacement)
}

private func canonicalUserScalars(_ text: String) -> [Unicode.Scalar] {
    text.unicodeScalars.compactMap { rawScalar in
        guard !CharacterSet.whitespacesAndNewlines.contains(rawScalar) else { return nil }
        // swift-markdown applies its documented smart-quote typography. Treat
        // that as a representation change, not body loss, while still retaining
        // every authored quote scalar in the ordered comparison.
        return ["\u{2018}", "\u{2019}"].contains(rawScalar) ? "'" :
            (["\u{201C}", "\u{201D}"].contains(rawScalar) ? "\"" : rawScalar)
    }
}

/// Removes only Markdown notation that has no readable plain-text counterpart.
/// Every remaining non-whitespace Unicode scalar is user body: punctuation,
/// symbols, emoji, combining marks, and repeated scalars are all counted.
func corpusUserBody(_ source: String) -> String {
    var body = source.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    body = corpusReplacing(#"(?m)^[ \t]*(?:(?:>[ \t]*)|(?:(?:[-+*]|\d+[.)])[ \t]+))*```[^\n]*$"#, in: body)
    body = corpusReplacing(#"(?m)^\s*(?:[-*_]\s*){3,}$"#, in: body)
    body = corpusReplacing(#"(?m)^\s*\|?(?:\s*:?-+:?\s*\|)+\s*$"#, in: body)
    body = corpusReplacing(#"(?m)^[ \t]*(?:(?:>[ \t]*)|(?:(?:[-+*]|\d+[.)])[ \t]+))+"#, in: body)
    body = corpusReplacing(#"(?m)^[ \t]*#{1,6}[ \t]+"#, in: body)
    body = corpusReplacing(#"(?<!\\)\[([^\[\]\n]*)\]\([^\)]*\)"#, in: body, with: "$1")
    body = corpusReplacing(#"<(https?://[^>\n]+)>"#, in: body, with: "$1")
    body = corpusReplacing(#"(?<!\\)</?[A-Za-z][A-Za-z0-9-]*(?:\s[^>\n]*)?/?>"#, in: body)
    // A backtick adjacent to malformed runs can become a code-span/fence
    // delimiter even when preceded by a backslash; it has no stable readable
    // counterpart in that case, so remove the escape and delimiter together.
    body = corpusReplacing(#"\\`"#, in: body)
    body = corpusReplacing(#"(?<!\\)[`*_]"#, in: body)
    body = corpusReplacing(#"\\([*_{}\[\]()#+.!\\><-])"#, in: body, with: "$1")
    return body
}

func parserMissingUserScalars(expectedText: String, projection: String) -> [String] {
    let expected = canonicalUserScalars(expectedText)
    let actual = canonicalUserScalars(projection)
    var actualIndex = 0
    var missing: [Unicode.Scalar: Int] = [:]
    for scalar in expected {
        while actualIndex < actual.count && actual[actualIndex] != scalar { actualIndex += 1 }
        if actualIndex < actual.count {
            actualIndex += 1
        } else {
            missing[scalar, default: 0] += 1
        }
    }
    return missing.map { scalar, count in
        (scalar.value, "U+\(String(scalar.value, radix: 16, uppercase: true)) \(String(scalar))×\(count)")
    }.sorted { $0.0 < $1.0 }.map(\.1)
}

private func expectCorpusBodyPreserved(_ fixture: TranscriptFixture, blocks: [AgentBlock], prefix: String = "fixture") {
    let missing = parserMissingUserScalars(
        expectedText: corpusUserBody(fixture.source),
        projection: parserPlainText(blocks)
    )
    expect(missing.isEmpty,
           "\(prefix) \(fixture.id) lost user body scalar(s): \(missing.prefix(12).joined(separator: ", "))")
}

private func observeParserCorpusNegativeWitness() {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("continuum-parser-negative-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    do {
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        for name in ["Package.swift", "Package.resolved"] {
            try fileManager.copyItem(at: repoRoot.appendingPathComponent(name),
                                     to: temporaryRoot.appendingPathComponent(name))
        }
        let thirdParty = temporaryRoot.appendingPathComponent("ThirdParty", isDirectory: true)
        try fileManager.createDirectory(at: thirdParty, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: thirdParty.appendingPathComponent("GhosttyKit.xcframework"),
            withDestinationURL: repoRoot.appendingPathComponent("ThirdParty/GhosttyKit.xcframework").resolvingSymlinksInPath()
        )
        let sources = temporaryRoot.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.copyItem(at: repoRoot.appendingPathComponent("Sources", isDirectory: true), to: sources)

        let parserURL = sources.appendingPathComponent("ContinuumRevivedAgentContent/MarkdownAgentMarkupParser.swift")
        let original = try String(contentsOf: parserURL, encoding: .utf8)
        let seam = "guard !source.isEmpty else { return AgentMarkupParse(blocks: []) }"
        let mutation = seam + "\n        if entryID.rawValue == \"entry:corpus-prose-plain\" { return AgentMarkupParse(blocks: []) } // negative witness: final corpus parser body loss"
        let mutated = original.replacingOccurrences(of: seam, with: mutation)
        expect(mutated != original, "negative witness could not locate the production parser return seam")
        try mutated.write(to: parserURL, atomically: true, encoding: .utf8)
    } catch {
        fail("could not prepare source-mutated parser negative witness: \(error)")
    }

    let logURL = temporaryRoot.appendingPathComponent("negative-witness.log")
    fileManager.createFile(atPath: logURL.path, contents: nil)
    guard let log = try? FileHandle(forWritingTo: logURL) else { fail("could not open parser negative witness log") }
    defer { try? log.close() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "swift", "run", "--package-path", temporaryRoot.path,
        "--scratch-path", temporaryRoot.appendingPathComponent(".build").path,
        "ContinuumRevivedAgentContentChecks"
    ]
    process.environment = ProcessInfo.processInfo.environment.merging([
        "CONTINUUM_PARSER_NEGATIVE_WITNESS": "body-loss"
    ]) { _, mutation in mutation }
    process.standardOutput = log
    process.standardError = log
    do { try process.run() } catch { fail("could not execute source-mutated parser negative witness: \(error)") }
    process.waitUntilExit()
    try? log.synchronize()
    let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    expect(process.terminationStatus == 1 && output.contains("FAIL: markup corpus fixture prose-plain lost its entire body"),
           "source-mutated parser negative witness did not reach the ordinary corpus whole-body assertion; status=\(process.terminationStatus), output=\(output.suffix(2_000))")
    print("Parser negative witness observed red: production parser source mutated to return empty blocks → ordinary prose-plain whole-body assertion exited 1")
}

func runParserCorpusChecks() {
    let parser = MarkdownAgentMarkupParser()
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let fixtures = TranscriptFixtureCorpus.all.filter { $0.form == .markup }
    expect(fixtures.count >= 10, "parser corpus must retain at least ten markup fixtures")

    var parsedBlocks = 0
    var projectedScalars = 0
    for fixture in fixtures {
        let entryID = AgentNodeID(rawValue: "entry:corpus-\(fixture.id)")!
        let parsed = parser.parse(fixture.source, entryID: entryID, previous: [])
        expect(!parsed.blocks.isEmpty, "markup corpus fixture \(fixture.id) lost its entire body")

        let encoded = try! encoder.encode(parsed)
        let decoded = try! decoder.decode(AgentMarkupParse.self, from: encoded)
        expect(decoded == parsed, "fixture \(fixture.id) changed during parse→encode→decode")
        expect(parser.parse(fixture.source, entryID: entryID, previous: []) == parsed,
               "fixture \(fixture.id) produced a non-deterministic final AST")

        let text = parserPlainText(decoded.blocks)
        expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               "fixture \(fixture.id) has no readable plain-text projection")
        expectCorpusBodyPreserved(fixture, blocks: decoded.blocks)
        let ids = corpusAllBlocks(decoded.blocks).map(\.id)
        expect(Set(ids).count == ids.count, "fixture \(fixture.id) produced duplicate semantic IDs")
        parsedBlocks += ids.count
        projectedScalars += text.unicodeScalars.count
    }

    expect(parsedBlocks >= 25, "corpus produced only \(parsedBlocks) semantic blocks; traversal is unexpectedly shallow")
    expect(projectedScalars >= 1_000, "corpus projected only \(projectedScalars) readable scalars; broad body coverage was lost")
    // A source-mutated child executes this same ordinary corpus gate. Suppress
    // only its attempt to create a recursive grandchild after all fixtures pass;
    // the intentional mutation should instead exit above on prose-plain.
    if ProcessInfo.processInfo.environment["CONTINUUM_PARSER_NEGATIVE_WITNESS"] != "body-loss" {
        observeParserCorpusNegativeWitness()
    }
    print("Parser corpus checks passed: \(fixtures.count) markup fixtures, \(parsedBlocks) semantic blocks, \(projectedScalars) projected scalars round-tripped with per-fixture body preservation")
}
