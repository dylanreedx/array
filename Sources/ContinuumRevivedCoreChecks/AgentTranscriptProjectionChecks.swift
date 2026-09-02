import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

private func resetRevisions(_ block: AgentBlock) -> AgentBlock {
    var result = block
    result.revision = 0
    result.children = block.children.map(resetRevisions)
    return result
}

private final class DeterministicProjectionClock: @unchecked Sendable {
    var time: TimeInterval

    init(_ time: TimeInterval = 1_000) {
        self.time = time
    }

    func now() -> TimeInterval { time }

    func advance(_ interval: TimeInterval) {
        time += interval
    }
}

func runAgentTranscriptProjectionChecks() {
    let thread = "projection-thread"
    var projection = AgentTranscriptProjection(threadId: thread)

    projection.appendUserPrompt("What changed?")
    let events: [AgentRuntimeEvent] = [
        .sessionStateChanged(.running),
        .turnStarted(threadId: thread, turnId: "turn-1"),
        .contentDelta(threadId: thread, turnId: "turn-1", streamKind: .assistant, delta: "I will check."),
        .itemStarted(threadId: thread, itemId: "cmd-1", kind: .commandExecution, title: "swift build"),
        .itemCompleted(threadId: thread, itemId: "cmd-1", kind: .commandExecution, status: .completed),
        .itemStarted(threadId: thread, itemId: "plan-1", kind: .plan, title: "Fix projection"),
        .itemCompleted(threadId: thread, itemId: "plan-1", kind: .plan, status: .completed),
        .itemStarted(threadId: thread, itemId: "diff-1", kind: .fileChange, title: "Sources/Safe.swift"),
        .itemCompleted(threadId: thread, itemId: "diff-1", kind: .fileChange, status: .completed),
        .itemStarted(threadId: thread, itemId: "error-1", kind: .error, title: "Provider rejected the operation"),
        .itemCompleted(threadId: thread, itemId: "error-1", kind: .error, status: .failed),
        .turnCompleted(threadId: thread, turnId: "turn-1", outcome: .completed, errorMessage: nil)
    ]
    events.forEach { projection.ingest($0) }

    var cardProjection = ManagedAgentTranscriptModel(threadId: thread)
    cardProjection.appendUserPrompt("What changed?")
    events.forEach { cardProjection.ingest($0) }
    let parity = transcriptSnapshotDivergences(
        TranscriptCompatibilitySnapshot.capture(projection),
        TranscriptCompatibilitySnapshot.capture(cardProjection)
    )
    expect(parity.isEmpty,
           "P1.5 six-kind fixture must preserve the compatibility card projection exactly: \(parity)")

    let rows = projection.compatibilityRows
    expect(rows.map(\.kind) == ["userMessage", "message", "toolCall", "plan", "diff", "error"],
           "P1.5 compatibility fixture must project all existing six kinds in order; got \(rows.map(\.kind))")
    expect(rows.map(\.status) == [nil, nil, .completed, .completed, .completed, .failed],
           "P1.5 item completion must survive the semantic projection")
    expect(projection.rejectedMutationCount == 0, "P1.5 valid runtime events must not produce rejected semantic mutations")

    let entries = projection.document.entries
    expect(entries.map(\.role) == [.user, .assistant, .system, .system, .system, .system],
           "P1.5 semantic entries must preserve authorship independently of card presentation")
    expect(entries.dropFirst(2).map { $0.blocks.first!.kind } == [.toolCall, .plan, .diff, .error],
           "P1.5 provider items must remain typed structured blocks")
    expect(entries.dropFirst(2).compactMap { entry -> String? in
        if case .providerItem(provider: "runtime", itemID: let itemID) = entry.provenance { return itemID }
        return nil
    } == ["cmd-1", "plan-1", "diff-1", "error-1"],
           "P1.5 provider item IDs must be stable entry provenance")

    // A kind switch, an interleaved item, and a new turn are all hard run
    // boundaries. This is the positive assertion for the named merge failure.
    var boundaries = AgentTranscriptProjection(threadId: thread)
    let boundaryEvents: [AgentRuntimeEvent] = [
        .turnStarted(threadId: thread, turnId: "turn-a"),
        .contentDelta(threadId: thread, turnId: "turn-a", streamKind: .assistant, delta: "assistant one"),
        .contentDelta(threadId: thread, turnId: "turn-a", streamKind: .reasoning, delta: "reasoning one"),
        .contentDelta(threadId: thread, turnId: "turn-a", streamKind: .assistant, delta: "assistant two"),
        .turnStarted(threadId: thread, turnId: "turn-b"),
        .contentDelta(threadId: thread, turnId: "turn-b", streamKind: .assistant, delta: "assistant three")
    ]
    boundaryEvents.forEach { boundaries.ingest($0) }
    expect(boundaries.document.entries.map(\.role) == [.assistant, .reasoning, .assistant, .assistant],
           "P1.5 assistant/reasoning runs must not merge across kind or turn boundaries")
    expect(Set(boundaries.document.entries.map(\.id)).count == 4,
           "P1.5 every separated stream run must retain a distinct stable identity")

    let markdownClock = DeterministicProjectionClock()
    var markdownStream = AgentTranscriptProjection(threadId: thread, monotonicNow: markdownClock.now)
    markdownStream.ingest(.turnStarted(threadId: thread, turnId: "turn-markdown"))
    markdownStream.ingest(.contentDelta(threadId: thread, turnId: "turn-markdown", streamKind: .assistant, delta: "**bo"))
    guard let partial = markdownStream.document.entries.first?.blocks.first,
          case .paragraph([.text("**bo")]) = partial.payload else {
        expect(false, "live Markdown stream must keep incomplete delimiters readable before they close")
        return
    }
    markdownClock.advance(0.05)
    markdownStream.ingest(.contentDelta(threadId: thread, turnId: "turn-markdown", streamKind: .assistant, delta: "ld**"))
    guard let streamedEntry = markdownStream.document.entries.first,
          case .paragraph([.strong([.text("bold")])]) = streamedEntry.blocks.first?.payload else {
        expect(false, "split streamed Markdown delimiter **bo + ld** must become a semantic strong inline")
        return
    }
    markdownStream.ingest(.turnCompleted(threadId: thread, turnId: "turn-markdown", outcome: .completed, errorMessage: nil))
    let oneShot = MarkdownAgentMarkupParser().parse("**bold**", entryID: streamedEntry.id, previous: []).blocks.map(resetRevisions)
    expect(markdownStream.document.entries.first?.blocks.map(resetRevisions) == oneShot,
           "final streamed assistant Markdown must converge with one-shot parsing and stable block IDs")

    let pauseClock = DeterministicProjectionClock()
    var paused = AgentTranscriptProjection(threadId: thread, monotonicNow: pauseClock.now)
    paused.ingest(.turnStarted(threadId: thread, turnId: "turn-paused"))
    paused.ingest(.contentDelta(threadId: thread, turnId: "turn-paused", streamKind: .assistant, delta: "**pa"))
    pauseClock.advance(0.001)
    paused.ingest(.contentDelta(threadId: thread, turnId: "turn-paused", streamKind: .assistant, delta: "used**"))
    expect(paused.streamingMarkupParseCount == 1,
           "inside-window delta must remain coalesced until the delayed production flush")
    pauseClock.advance(0.05)
    expect(paused.flushPendingStreamingMarkupIfDue(),
           "a paused provider must have a production scheduling seam that flushes after the coalescing deadline")
    guard case .paragraph([.strong([.text("paused")])]) = paused.document.entries.first?.blocks.first?.payload else {
        expect(false, "delayed flush must parse the latest lossless source after the provider pauses")
        return
    }
    expect(paused.streamingMarkupParseCount == 2,
           "pause-after-inside-window stream must parse once initially and once on the delayed flush")

    let structuralClock = DeterministicProjectionClock()
    var structural = AgentTranscriptProjection(threadId: thread, monotonicNow: structuralClock.now)
    structural.ingest(.turnStarted(threadId: thread, turnId: "turn-structural"))
    let structuralDeltas = [
        "# Héading 🙂\n\n- café",
        "\n- résumé\n\n> quo",
        "te\n\n```swift\nlet beverage = \"☕️\"\n",
        "```\n"
    ]
    var structuralSource = ""
    for delta in structuralDeltas {
        structuralSource += delta
        structural.ingest(.contentDelta(threadId: thread, turnId: "turn-structural", streamKind: .assistant, delta: delta))
        structuralClock.advance(0.05)
        _ = structural.flushPendingStreamingMarkupIfDue()
    }
    structural.ingest(.turnCompleted(threadId: thread, turnId: "turn-structural", outcome: .completed, errorMessage: nil))
    guard let structuralEntry = structural.document.entries.first else {
        expect(false, "long Unicode structural stream must create an assistant entry")
        return
    }
    let structuralOneShot = MarkdownAgentMarkupParser().parse(structuralSource, entryID: structuralEntry.id, previous: []).blocks.map(resetRevisions)
    expect(structuralEntry.blocks.map(resetRevisions) == structuralOneShot,
           "streamed Unicode heading/list/quote/fence Markdown must converge with one-shot parsing")

    let coalescedClock = DeterministicProjectionClock()
    let productionProjectionStarted = ContinuousClock.now
    var coalesced = AgentTranscriptProjection(threadId: thread, monotonicNow: coalescedClock.now)
    coalesced.ingest(.turnStarted(threadId: thread, turnId: "turn-coalesced"))
    let deltaCount = 5_000
    var coalescedSource = ""
    var firstBlockID: AgentNodeID?
    for index in 0..<deltaCount {
        let delta: String
        switch index {
        case 0: delta = "**"
        case deltaCount - 1: delta = "**"
        case 1_500, 3_000: delta = "é"
        default: delta = index.isMultiple(of: 97) ? "🙂" : "x"
        }
        coalescedSource += delta
        coalesced.ingest(.contentDelta(threadId: thread, turnId: "turn-coalesced", streamKind: .assistant, delta: delta))
        if firstBlockID == nil { firstBlockID = coalesced.document.entries.first?.blocks.first?.id }
        coalescedClock.advance(0.001)
    }
    let pacedParsesBeforeCompletion = coalesced.streamingMarkupParseCount
    expect((120...180).contains(pacedParsesBeforeCompletion),
           "5,000 paced assistant Markdown deltas over advancing monotonic time must parse near the 30Hz cadence, not once per token or only 1+flush; got \(pacedParsesBeforeCompletion)")
    expect(coalesced.finalizedCompatibilityMarkupSourceCount == 0,
           "open streamed Markdown source must not be retained in the finalized raw-source map before close; reintroducing per-delta raw-map assignment turns this red")
    let openCompatibilitySources = coalesced.compatibilityMarkupSourcesByEntryID
    expect(openCompatibilitySources.count == 1 && openCompatibilitySources.values.first == coalescedSource,
           "the one open compatibility source must be exposed on demand and remain lossless before close")
    var mutatedSourceSnapshot = openCompatibilitySources
    if let openEntryID = mutatedSourceSnapshot.keys.first { mutatedSourceSnapshot[openEntryID] = "MUTATED" }
    expect(coalesced.compatibilityMarkupSourcesByEntryID.values.first == coalescedSource,
           "compatibility source snapshots must not alias mutable projection storage")
    coalesced.ingest(.turnCompleted(threadId: thread, turnId: "turn-coalesced", outcome: .completed, errorMessage: nil))
    guard let coalescedEntry = coalesced.document.entries.first,
          let firstBlockID,
          let finalBlock = coalescedEntry.blocks.first else {
        expect(false, "coalesced Markdown stream must create one assistant entry with a stable markup block")
        return
    }
    let productionProjectionElapsed = productionProjectionStarted.duration(to: .now)
    let productionProjectionSeconds = Double(productionProjectionElapsed.components.seconds)
        + Double(productionProjectionElapsed.components.attoseconds) / 1e18
    let productionProjectionCeilingSeconds = 2.0
    let coalescedOneShot = MarkdownAgentMarkupParser().parse(coalescedSource, entryID: coalescedEntry.id, previous: []).blocks.map(resetRevisions)
    expect(coalesced.streamingMarkupParseCount <= pacedParsesBeforeCompletion + 1,
           "completion may add at most one pending final parse after a paced stream; got \(coalesced.streamingMarkupParseCount) from \(pacedParsesBeforeCompletion)")
    expect(coalesced.finalizedCompatibilityMarkupSourceCount == 1
               && coalesced.compatibilityMarkupSourcesByEntryID[coalescedEntry.id] == coalescedSource,
           "closed streamed Markdown source must be archived exactly once and remain byte-for-byte lossless")
    expect(productionProjectionSeconds < productionProjectionCeilingSeconds,
           String(format: "5,000-delta production projection+replaceMarkup path took %.3f s, above fixed %.1f s ceiling", productionProjectionSeconds, productionProjectionCeilingSeconds))
    expect(finalBlock.id == firstBlockID,
           "production projection must reconcile replaceMarkup blocks by stable identity across paced parses")
    expect(finalBlock.revision <= UInt64(coalesced.streamingMarkupParseCount + 1) &&
           coalesced.document.version <= UInt64(coalesced.streamingMarkupParseCount + 2),
           "projection/reducer revisions must be bounded by parsed presentations, not 5,000 raw deltas; block revision \(finalBlock.revision), document version \(coalesced.document.version), parses \(coalesced.streamingMarkupParseCount)")
    expect(coalescedEntry.blocks.map(resetRevisions) == coalescedOneShot,
           "coalesced 5,000-delta assistant Markdown with Unicode must converge with one-shot parsing")

    let reasoningClock = DeterministicProjectionClock()
    var reasoning = AgentTranscriptProjection(threadId: thread, monotonicNow: reasoningClock.now)
    reasoning.ingest(.contentDelta(threadId: thread, turnId: "turn-reasoning", streamKind: .reasoning, delta: "`rea"))
    reasoning.ingest(.contentDelta(threadId: thread, turnId: "turn-reasoning", streamKind: .reasoning, delta: "son`"))
    expect(reasoning.streamingMarkupParseCount == 1,
           "reasoning Markdown deltas must use the same coalesced parser path as assistant streams")
    reasoning.ingest(.runtimeError(threadId: thread, message: "runtime disconnected"))
    guard let reasoningEntry = reasoning.document.entries.first else {
        expect(false, "reasoning stream must create one reasoning entry before runtime-error boundary")
        return
    }
    let reasoningOneShot = MarkdownAgentMarkupParser().parse("`reason`", entryID: reasoningEntry.id, previous: []).blocks.map(resetRevisions)
    expect(reasoning.streamingMarkupParseCount == 2 && reasoningEntry.blocks.map(resetRevisions) == reasoningOneShot,
           "runtime-error boundary must flush pending reasoning Markdown before closing the entry")

    var interrupted = AgentTranscriptProjection(threadId: thread, monotonicNow: DeterministicProjectionClock().now)
    interrupted.ingest(.contentDelta(threadId: thread, turnId: "turn-interrupted", streamKind: .assistant, delta: "_inter"))
    interrupted.ingest(.contentDelta(threadId: thread, turnId: "turn-interrupted", streamKind: .assistant, delta: "rupted_"))
    interrupted.ingest(.turnCompleted(threadId: thread, turnId: "turn-interrupted", outcome: .interrupted, errorMessage: nil))
    expect(interrupted.streamingMarkupParseCount == 2,
           "interrupted turn completion must flush pending streamed Markdown before finish")

    var stopped = AgentTranscriptProjection(threadId: thread, monotonicNow: DeterministicProjectionClock().now)
    stopped.ingest(.contentDelta(threadId: thread, turnId: "turn-stopped", streamKind: .assistant, delta: "_stop"))
    stopped.ingest(.contentDelta(threadId: thread, turnId: "turn-stopped", streamKind: .assistant, delta: "ped_"))
    stopped.ingest(.sessionStateChanged(.stopped))
    expect(stopped.streamingMarkupParseCount == 2 && stopped.document.entries.first?.lifecycle == .finished,
           "session stop/reset close path must flush pending streamed Markdown before finishing the open entry")

    var outputs = AgentTranscriptProjection(threadId: thread)
    outputs.ingest(.contentDelta(threadId: thread, turnId: "turn-output", streamKind: .commandOutput, delta: "build output"))
    outputs.ingest(.runtimeError(threadId: thread, message: "runtime disconnected"))
    expect(outputs.document.entries.map { $0.blocks.first!.kind } == [.commandOutput, .error],
           "P1.5 command deltas and runtime errors must map to typed blocks")
    expect(outputs.compatibilityRows.map(\.body) == ["build output", "runtime disconnected"],
           "P1.5 explicit safe display text must survive projection")
    expect(outputs.streamingMarkupParseCount == 0,
           "explicit command-output/plain-text path must not invoke the Markdown parser")

    var filtering = AgentTranscriptProjection(threadId: thread)
    filtering.ingest(.contentDelta(threadId: "other-thread", turnId: "other-turn", streamKind: .assistant, delta: "must not appear"))
    expect(filtering.document.entries.isEmpty, "P1.5 must ignore body events belonging to another thread")

    let secretCommand = "printf SUPER_SECRET"
    var privacy = AgentTranscriptProjection(threadId: thread)
    privacy.ingest(.itemStarted(threadId: thread, itemId: "private-tool", kind: .commandExecution, title: "shell"))
    let encoded = try! JSONEncoder().encode(privacy.document)
    let projected = String(decoding: encoded, as: UTF8.self)
    expect(!projected.contains(secretCommand),
           "P1.5 must not invent or interpolate raw tool arguments absent from AgentRuntimeEvent")

    print(String(format: "Agent transcript projection checks passed: six compatibility kinds, stable provenance, stream boundaries, command/error typing, thread filter, and 5,000-delta production projection+replaceMarkup in %.3f s (%d parses, %d finalized raw source)", productionProjectionSeconds, coalesced.streamingMarkupParseCount, coalesced.finalizedCompatibilityMarkupSourceCount))

    // B6.2 — the compaction block kind. The projection must recognize
    // `ItemKind.compaction` AND the `.unknown("compaction")` spelling it
    // shipped as for one day (see AgentTranscriptProjection.isCompactionKind),
    // attribute it to the harness (never
    // user/assistant), decode its title back into real pre/post/automatic
    // fields, and never throw trying to complete a status this payload does
    // not carry.
    var compaction = AgentTranscriptProjection(threadId: thread)
    let compactionTitle = AgentCompactionPayload.encodeTitle(preTokens: 26268, postTokens: 2140, automaticCompaction: false)
    compaction.ingest(.itemStarted(
        threadId: thread, itemId: "compaction-1",
        kind: ItemKind.compaction, title: compactionTitle))
    compaction.ingest(.itemCompleted(
        threadId: thread, itemId: "compaction-1",
        kind: ItemKind.compaction, status: .completed))
    expect(compaction.rejectedMutationCount == 0,
           "B6.2: a compaction item must complete without a rejected status-transition mutation")
    let compactionEntry = compaction.document.entries.first { $0.blocks.first?.kind == .compaction }
    expect(compactionEntry?.role == .system,
           "B6.2: a compaction block must be attributed to the harness (.system), got \(String(describing: compactionEntry?.role))")
    if case .compaction(let payload) = compactionEntry?.blocks.first?.payload {
        expect(payload.preTokens == 26268 && payload.postTokens == 2140
                   && payload.automaticCompaction == false && payload.phase == "succeeded"
                   && payload.provider == nil && payload.boundaryID == nil,
               "B6.2: the legacy compaction payload must retain its real pre/post tokens and trigger while decoding as a successful boundary, got \(payload)")
    } else {
        expect(false, "B6.2: a compaction item must project to AgentBlockPayload.compaction, got \(String(describing: compactionEntry?.blocks.first?.payload))")
    }

    print("Agent compaction block checks passed: harness-attributed, real pre/post/automatic fields, no rejected status mutation")
}

func runLocalTranscriptNodeChecks() {
    let promptID = AgentNodeID(rawValue: "submission:local-42")!
    let noticeID = AgentNodeID(rawValue: "notice:previous-session")!
    var projection = AgentTranscriptProjection(threadId: "local-node-thread")
    let providerEvent = AgentRuntimeEvent.sessionStateChanged(.running)
    projection.ingest(providerEvent)
    let providerHistoryBeforeLocalNodes = projection.events

    let promptPatches = try! projection.appendUserPrompt(id: promptID, text: "Explain the failing guard.")
    expect(promptPatches.count == 3,
           "P1.6 a local prompt must expose each incremental reducer patch")
    expect(promptPatches[0].inserted == [promptID],
           "P1.6 the caller submission ID must be the inserted user entry ID")
    expect(zip(promptPatches, promptPatches.dropFirst()).allSatisfy { $0.toVersion == $1.fromVersion },
           "P1.6 local prompt patches must form a contiguous version chain")

    let prompt = projection.document.entries.first!
    expect(prompt.id == promptID && prompt.role == .user,
           "P1.6 a prompt must remain distinguishable as user-authored without presentation color")
    expect(prompt.provenance == .localPrompt(promptID: promptID.rawValue),
           "P1.6 a prompt must retain local provenance keyed by the caller submission ID")
    expect(prompt.blocks.first?.id == promptID.childID(stableKey: "prompt"),
           "P1.6 prompt block identity must derive from the submission ID, not transcript count")

    // Required negative witness: retrying the same submission ID with different
    // text must neither append a second entry nor replace the accepted body.
    let retryPatches = try! projection.appendUserPrompt(id: promptID, text: "DUPLICATE BODY")
    expect(retryPatches.isEmpty && projection.document.entries.count == 1,
           "P1.6 duplicate local submission IDs must be semantic no-ops")
    expect(projection.compatibilityRows.map(\.body) == ["Explain the failing guard."],
           "P1.6 a duplicate submission must not append or overwrite prompt content")

    let noticePatches = try! projection.appendNotice(
        id: noticeID,
        title: "previous session",
        body: "Earlier transcript content is unavailable."
    )
    expect(noticePatches.count == 3 && projection.document.entries.count == 2,
           "P1.6 a local notice must insert one semantic entry through incremental patches")
    let notice = projection.document.entries[1]
    expect(notice.role == .system && notice.provenance == .localNotice(reason: noticeID.rawValue),
           "P1.6 Continuum notices must retain local notice provenance")
    expect(notice.blocks.first?.kind == .notice,
           "P1.6 a local notice must remain typed instead of collapsing into assistant prose")
    if case .heading(level: 3, content: [.text("previous session")])? = notice.blocks.first?.children.first?.payload {
        // Exact semantic title shape verified.
    } else {
        expect(false, "P1.6 a local notice must preserve its title as semantic heading content")
    }

    let noticeRetry = try! projection.appendNotice(
        id: noticeID,
        title: "changed title",
        body: "DUPLICATE NOTICE"
    )
    expect(noticeRetry.isEmpty && projection.document.entries.count == 2,
           "P1.6 the previous-session notice must remain idempotent when tile wiring repeats")
    expect(projection.events == providerHistoryBeforeLocalNodes && projection.events == [providerEvent],
           "P1.6 locally authored prompts and notices must leave existing provider event history unchanged")
    expect(projection.rejectedMutationCount == 0,
           "P1.6 valid local node APIs must not hide rejected reducer mutations")

    print("Local transcript node checks passed: caller IDs, semantic roles/provenance, notice title, idempotent retries, and provider-history isolation")
}

func runAgentReferenceProjectionChecks() {
    let thread = "agent-reference-thread"
    let child = UUID(uuidString: "A3000000-0000-4000-8000-000000000001")!
    let parent = UUID(uuidString: "A3000000-0000-4000-8000-000000000002")!
    let event = AgentRuntimeEvent.childAgentSpawned(
        threadId: thread,
        childAgentID: child,
        parentAgentID: parent,
        displayName: "Stats review",
        sourceItemID: "spawn-call-1",
        provider: "pi",
        spawnedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    var projection = AgentTranscriptProjection(threadId: thread)
    projection.ingest(event)
    projection.ingest(event)
    let references = projection.document.entries.flatMap(\.blocks).compactMap { block -> AgentReferencePayload? in
        guard case let .agentReference(payload) = block.payload else { return nil }
        return payload
    }
    expect(references.count == 1, "duplicate child lifecycle events must produce one transcript milestone")
    expect(references.first?.agentID == child && references.first?.parentAgentID == parent,
           "agent-reference milestone must preserve durable parent/child identity")
    expect(references.first?.sourceItemID == "spawn-call-1",
           "agent-reference milestone must retain its safe provider correlation")
    let roundTrip = try! JSONDecoder().decode(AgentRuntimeEvent.self, from: JSONEncoder().encode(event))
    expect(roundTrip == event, "safe child lifecycle events must round-trip for encrypted transcript sync")
    print("Agent reference projection checks passed: stable identity, source correlation, Codable, and replay deduplication")
}
