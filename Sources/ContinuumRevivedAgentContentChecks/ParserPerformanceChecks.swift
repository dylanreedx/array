import ContinuumRevivedAgentContent
import Foundation

func runParserPerformanceChecks() {
    let fixture = TranscriptFixtureCorpus.fixture("stream-5000-deltas")
    let deltas = TranscriptFixtureCorpus.deltas(for: fixture, count: 5_000)
    let entryID = AgentNodeID(rawValue: "entry:parser-performance")!
    let baseline = MarkdownAgentMarkupParser().parse(fixture.source, entryID: entryID, previous: [])

    let theoreticalFiveSecondCeiling = 152 // first parse + 5 s × 30 Hz + final flush
    let p50CeilingSeconds = 0.25
    let worstCeilingSeconds = 1.0

    @discardableResult
    func runCoalescedWorkload(label: String) -> (seconds: Double, parseCount: Int) {
        // Every run owns fresh parser, buffer, scheduler, and prior AST state.
        // A deterministic 1,000-delta/second clock models a five-second provider
        // burst; wall time never decides whether a parse occurs.
        let started = ContinuousClock.now
        let parser = MarkdownAgentMarkupParser()
        var buffer = StreamingMarkupBuffer()
        var scheduler = StreamingMarkupParseScheduler(maximumParsesPerSecond: 30)
        var parsed = AgentMarkupParse(blocks: [])
        var parseCount = 0

        for (index, delta) in deltas.enumerated() {
            buffer.append(delta)
            scheduler.requestParse()
            if scheduler.shouldParse(now: Double(index) / 1_000) {
                parsed = parser.parse(buffer.source, entryID: entryID, previous: parsed.blocks)
                parseCount += 1
            }
        }
        if scheduler.flush() {
            parsed = parser.parse(buffer.source, entryID: entryID, previous: parsed.blocks)
            parseCount += 1
        }
        let elapsed = started.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        // Count and convergence remain the primary performance contract and are
        // independently asserted for the warm-up and every measured sample.
        expect(buffer.source == fixture.source, "\(label): 5,000 streamed deltas lost or duplicated semantic source")
        expect(parseCount > 100, "\(label): only \(parseCount) parses; the sustained coalescing path was not exercised")
        expect(parseCount <= theoreticalFiveSecondCeiling,
               "\(label): 5,000 deltas caused \(parseCount) parses, above the 30 Hz algorithmic ceiling \(theoreticalFiveSecondCeiling)")
        expect(parseCount < deltas.count / 20,
               "\(label): parser count \(parseCount) is too close to one parse per delta")
        expect(parsed == baseline, "\(label): coalesced stream did not converge to the deterministic unstreamed AST")
        return (elapsedSeconds, parseCount)
    }

    // Warm caches before collecting five independent full-workload samples.
    runCoalescedWorkload(label: "warm-up")
    let measured = (1...5).map { runCoalescedWorkload(label: "measured run \($0)") }
    let sortedSamples = measured.map { $0.seconds }.sorted()
    let p50 = sortedSamples[sortedSamples.count / 2]
    let worst = sortedSamples.last!

    // Fixed ceilings provide explicit headroom and cannot expand to fit the
    // current run. The tighter median gate catches repeatable regressions while
    // the larger worst-case ceiling tolerates a single locally noisy sample.
    expect(p50 < p50CeilingSeconds,
           String(format: "5-run coalesced workload p50 %.3f s exceeded fixed %.2f s ceiling", p50, p50CeilingSeconds))
    expect(worst < worstCeilingSeconds,
           String(format: "5-run coalesced workload worst %.3f s exceeded fixed %.1f s ceiling", worst, worstCeilingSeconds))

    // Keep the algorithmic negative discriminator explicit and independent of
    // wall time: one parse per delta necessarily exceeds both count ceilings.
    let uncoalescedParseCount = deltas.count
    expect(uncoalescedParseCount > theoreticalFiveSecondCeiling && uncoalescedParseCount >= deltas.count / 20,
           "negative witness no longer discriminates one-parse-per-delta behavior")

    let renderedCounts = measured.map { String($0.parseCount) }.joined(separator: ", ")
    let renderedSamples = sortedSamples.map { String(format: "%.3f", $0) }.joined(separator: ", ")
    print(String(format: "Parser performance checks passed: five 5,000-delta runs, parse counts [\(renderedCounts)] (≤%d) and AST-equal; sorted samples [\(renderedSamples)] s, p50 %.3f s (<%.2f), worst %.3f s (<%.1f)", theoreticalFiveSecondCeiling, p50, p50CeilingSeconds, worst, worstCeilingSeconds))
}
