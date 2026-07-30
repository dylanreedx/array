import ContinuumRevivedAgentContent
import Foundation

private struct ParserFuzzGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }

    mutating func choose<T>(_ values: [T]) -> T { values[Int(next() % UInt64(values.count))] }
}

private func malformedMarkdown(seed: Int) -> (source: String, witness: String) {
    var random = ParserFuzzGenerator(state: UInt64(seed))
    // Includes punctuation, a symbol, emoji, and a decomposed combining mark;
    // repeating it proves scalar multiplicity rather than mere containment.
    let witness = "body\(seed)Ж😀e\u{0301}!?§"
    let opens = ["**", "_", "`", "[", "[label](", "```swift\n", "> ", "- ", "<tag>"]
    let middles = ["\n", "\r", "\r\n", " ", "\t", "\u{0301}", "（", "\\"]
    let closes = ["", "*", "__", ")", "]", "``", "```", "</wrong>", "\n> > "]
    // Lead with ordinary text so every malformed suffix has an independently
    // checkable body-loss witness; syntax delimiters themselves may disappear
    // legitimately in a plain-text projection.
    var source = witness + " " + witness + "\n\n" + random.choose(opens)
    let additions = 2 + Int(random.next() % 10)
    for _ in 0..<additions {
        source += random.choose(middles)
        source += random.choose(opens) + random.choose(closes)
    }
    source += random.choose(closes)
    return (source, witness)
}

private func fuzzAllIDs(_ roots: [AgentBlock]) -> [AgentNodeID] {
    roots.flatMap { [$0.id] + fuzzAllIDs($0.children) }
}

private func fuzzChunks(_ source: String, seed: Int) -> [String] {
    let scalars = Array(source.unicodeScalars)
    guard !scalars.isEmpty else { return [] }
    var random = ParserFuzzGenerator(state: UInt64(seed) ^ 0xd1b54a32d192ed03)
    var chunks: [String] = []
    var index = 0
    while index < scalars.count {
        let length = min(1 + Int(random.next() % 11), scalars.count - index)
        chunks.append(String(String.UnicodeScalarView(scalars[index..<(index + length)])))
        index += length
    }
    return chunks
}

func runParserFuzzChecks() {
    let parser = MarkdownAgentMarkupParser()
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    var chunkCount = 0
    var diagnostics = 0

    // Prove the full-source oracle notices loss after the duplicated prefix,
    // rather than allowing the prefix witness to mask a malformed suffix loss.
    let suffixLossSource = corpusUserBody(malformedMarkdown(seed: 0).source)
    var suffixLossProjection = Array(suffixLossSource.unicodeScalars)
    let suffixScalarIndex = suffixLossProjection.lastIndex {
        !CharacterSet.whitespacesAndNewlines.contains($0)
    }!
    suffixLossProjection.remove(at: suffixScalarIndex)
    let suffixLosses = parserMissingUserScalars(
        expectedText: suffixLossSource,
        projection: String(String.UnicodeScalarView(suffixLossProjection))
    )
    expect(!suffixLosses.isEmpty,
           "full-source fuzz oracle did not detect a generated suffix-only scalar loss")

    for seed in 0..<500 {
        let generated = malformedMarkdown(seed: seed)
        let entryID = AgentNodeID(rawValue: "entry:fuzz-\(seed)")!
        let baseline = parser.parse(generated.source, entryID: entryID, previous: [])
        expect(!baseline.blocks.isEmpty, "fuzz seed \(seed) dropped a non-empty malformed body")
        let projection = parserPlainText(baseline.blocks)
        let expectedUserBody = corpusUserBody(generated.source)
        let missingUserScalars = parserMissingUserScalars(
            expectedText: expectedUserBody,
            projection: projection
        )
        expect(missingUserScalars.isEmpty,
               "fuzz seed \(seed) dropped user body scalar(s): \(missingUserScalars.joined(separator: ", ")); expected=\(expectedUserBody.debugDescription); source=\(generated.source.debugDescription); projection=\(projection.debugDescription)")

        let roundTrip = try! decoder.decode(AgentMarkupParse.self, from: encoder.encode(baseline))
        expect(roundTrip == baseline, "fuzz seed \(seed) did not survive Codable round-trip")
        let ids = fuzzAllIDs(baseline.blocks)
        expect(Set(ids).count == ids.count, "fuzz seed \(seed) produced duplicate semantic IDs")

        var accumulated = ""
        var streamed = AgentMarkupParse(blocks: [])
        let chunks = fuzzChunks(generated.source, seed: seed)
        for chunk in chunks {
            accumulated += chunk
            streamed = parser.parse(accumulated, entryID: entryID, previous: streamed.blocks)
        }
        expect(accumulated == generated.source, "fuzz seed \(seed) chunking lost source scalars")
        expect(streamed == baseline, "fuzz seed \(seed) final AST depends on chunk boundaries")
        expect(parser.parse(generated.source, entryID: entryID, previous: []) == baseline,
               "fuzz seed \(seed) final AST is non-deterministic")
        chunkCount += chunks.count
        diagnostics += baseline.diagnostics.count
    }

    expect(chunkCount >= 3_000, "fuzz sweep exercised only \(chunkCount) chunk boundaries")
    print("Parser fuzz checks passed: 500 fixed seeds, \(chunkCount) deterministic chunks, \(diagnostics) bounded diagnostic(s)")
}
