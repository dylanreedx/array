import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/91-agent-tile-ux/P0.5-compatibility-pipeline-harness.md
//
// The compatibility floor for the transcript pipeline, replayed on the REAL path:
//
//   corpus fixture text
//     → Pi `--mode json` lines
//     → PiEventTranslator
//     → AgentRuntimeEvent.withThreadId(tile thread)      (the wiring boundary)
//     → an AgentTranscriptProjecting projection
//     → TranscriptCompatibilitySnapshot
//
// Nothing here stands in for a production seam: the translator is the shipped
// one, the remap is the shipped one, and the projection is the shipped card
// model. Only the process (PiAgentRunner) and the view are absent, and neither
// decides transcript order, identity, or status.
//
// The floor is DELIBERATELY EXACT — literal ids, kinds, bodies, statuses. P1.x
// is allowed to change what the transcript shows, but not by accident and not
// without this file's expectations changing in the same commit, which is a
// reviewable diff instead of a silent regression.
//
// What this file is NOT: it does not define or reserve any part of the semantic
// document. `transcriptProjectionsUnderTest` is the seam: both shipped
// projections are registered there and every corpus script runs against both,
// with `transcriptSnapshotDivergences` reporting any field that disagrees.

// MARK: - the floor's vocabulary

struct TranscriptCompatibilitySnapshot: Equatable, Sendable {
    var ids: [String]
    var kinds: [String]
    var bodies: [String]
    var statuses: [ItemStatus?]
    var activeToolCount: Int
    var status: AgentStatus

    static func capture(_ projection: some AgentTranscriptProjecting) -> Self {
        let rows = projection.compatibilityRows
        return Self(
            ids: rows.map(\.id),
            kinds: rows.map(\.kind),
            bodies: rows.map(\.body),
            statuses: rows.map(\.status),
            activeToolCount: projection.activeToolCount,
            status: projection.currentStatus
        )
    }
}

/// Field-level disagreement between two projections of the same script. Returns
/// every difference rather than the first, so a parity failure names the whole
/// gap instead of one symptom of it.
func transcriptSnapshotDivergences(
    _ lhs: TranscriptCompatibilitySnapshot,
    _ rhs: TranscriptCompatibilitySnapshot
) -> [String] {
    var divergences: [String] = []
    if lhs.ids != rhs.ids { divergences.append("ids \(lhs.ids) vs \(rhs.ids)") }
    if lhs.kinds != rhs.kinds { divergences.append("kinds \(lhs.kinds) vs \(rhs.kinds)") }
    if lhs.bodies != rhs.bodies {
        let first = zip(lhs.bodies, rhs.bodies).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? min(lhs.bodies.count, rhs.bodies.count)
        divergences.append("bodies differ from row \(first) (\(lhs.bodies.count) vs \(rhs.bodies.count) row(s))")
    }
    if lhs.statuses != rhs.statuses { divergences.append("statuses \(lhs.statuses) vs \(rhs.statuses)") }
    if lhs.activeToolCount != rhs.activeToolCount {
        divergences.append("activeToolCount \(lhs.activeToolCount) vs \(rhs.activeToolCount)")
    }
    if lhs.status != rhs.status { divergences.append("status \(lhs.status) vs \(rhs.status)") }
    return divergences
}

// MARK: - the replay harness

enum TranscriptCompatibilityStep: Sendable {
    /// One line of Pi `--mode json` output, translated by the shipped translator.
    case providerLine(String)
    /// A prompt the USER submitted. Not a provider event by design (see
    /// `ManagedAgentTranscriptModel.appendUserPrompt`), so it enters the
    /// projection directly, exactly as the tile does it.
    case userPrompt(String)
    case notice(id: String, title: String, text: String)
}

struct TranscriptCompatibilityScript: Sendable {
    var name: String
    var steps: [TranscriptCompatibilityStep]
}

enum TranscriptCompatibilityHarness {
    /// The tile's own thread. Pi synthesises its own from the session id, and the
    /// wiring boundary rebinds every event to this one before ingest; a harness
    /// that skipped the rebind would be testing a stream the tile filters out.
    static let tileThread = "managed-P05"
    static let piSessionID = "SID-P05"

    static func line(_ object: [String: Any]) -> TranscriptCompatibilityStep {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            fputs("FAIL: transcript compatibility harness could not encode a provider line from \(object)\n", stderr)
            Foundation.exit(1)
        }
        return .providerLine(String(decoding: data, as: UTF8.self))
    }

    static var sessionPrefix: [TranscriptCompatibilityStep] {
        [
            line(["type": "session", "version": 3, "id": piSessionID, "cwd": "/work/lumen-atlas"]),
            line(["type": "agent_start"])
        ]
    }

    static var turnStart: TranscriptCompatibilityStep { line(["type": "turn_start"]) }
    static var turnEnd: TranscriptCompatibilityStep { line(["type": "turn_end", "message": ["role": "assistant"]]) }
    static var settled: TranscriptCompatibilityStep { line(["type": "agent_settled"]) }

    static func textDelta(_ delta: String) -> TranscriptCompatibilityStep {
        line(["type": "message_update",
              "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": delta]])
    }

    static func thinkingDelta(_ delta: String) -> TranscriptCompatibilityStep {
        line(["type": "message_update",
              "assistantMessageEvent": ["type": "thinking_delta", "contentIndex": 0, "delta": delta]])
    }

    static func toolStart(callID: String, tool: String, args: [String: Any]) -> TranscriptCompatibilityStep {
        line(["type": "tool_execution_start", "toolCallId": callID, "toolName": tool, "args": args])
    }

    static func toolEnd(callID: String, tool: String, isError: Bool) -> TranscriptCompatibilityStep {
        line(["type": "tool_execution_end", "toolCallId": callID, "toolName": tool, "isError": isError])
    }

    /// Drive one script through one projection type. Generic over the seam, so
    /// the second projection needs no second harness.
    static func replay<Projection: AgentTranscriptProjecting>(
        _ script: TranscriptCompatibilityScript,
        into _: Projection.Type
    ) -> TranscriptCompatibilitySnapshot {
        var translator = PiEventTranslator()
        var projection = Projection(threadId: tileThread)
        for step in script.steps {
            switch step {
            case .providerLine(let line):
                for event in translator.translate(line: line) {
                    projection.ingest(event.withThreadId(tileThread))
                }
            case .userPrompt(let text):
                projection.appendUserPrompt(text)
            case .notice(let id, let title, let text):
                projection.appendNotice(id: id, title: title, text: text)
            }
        }
        return .capture(projection)
    }
}

/// A projection the floor is asserted against, wrapped in a closure so the array
/// below can hold heterogeneous types without existential mutation.
struct TranscriptProjectionUnderTest: Sendable {
    var name: String
    var replay: @Sendable (TranscriptCompatibilityScript) -> TranscriptCompatibilitySnapshot

    static let cardModel = Self(name: "ManagedAgentTranscriptModel") {
        TranscriptCompatibilityHarness.replay($0, into: ManagedAgentTranscriptModel.self)
    }

    static let semanticDocument = Self(name: "AgentTranscriptProjection") {
        TranscriptCompatibilityHarness.replay($0, into: AgentTranscriptProjection.self)
    }
}

/// THE migration seam. Keep both production projections on the same translated
/// corpus until the compatibility-removal ticket retires the card model.
let transcriptProjectionsUnderTest: [TranscriptProjectionUnderTest] = [.cardModel, .semanticDocument]

// MARK: - a stub that disagrees, so the parity comparison is not vacuous today

/// Deliberately WRONG on two axes: it drops completion status and it merges
/// consecutive assistant runs across turn boundaries — the exact two regressions
/// this ticket's "Done when" names. It exists only to prove that the parity
/// comparison would report a second projection that behaved this way; it is
/// never part of `transcriptProjectionsUnderTest`, and it is not a model of
/// anything the 91 program intends to build.
struct DivergentTranscriptProjectionStub: AgentTranscriptProjecting {
    private let threadId: String
    private var rows: [AgentTranscriptCompatibilityRow] = []
    private var openAssistantIndex: Int?

    init(threadId: String) { self.threadId = threadId }

    var currentStatus: AgentStatus { .idle }
    var activeToolCount: Int { 0 }
    var compatibilityRows: [AgentTranscriptCompatibilityRow] { rows }

    mutating func ingest(_ event: AgentRuntimeEvent) {
        switch event {
        case .contentDelta(let tid, _, .assistant, let delta) where tid == threadId:
            if let index = openAssistantIndex {
                rows[index].body += delta          // never ends the run: turns merge
            } else {
                rows.append(.init(id: "assistant-\(rows.count + 1)", kind: "message", body: delta))
                openAssistantIndex = rows.count - 1
            }
        case .itemStarted(let tid, let itemID, _, _) where tid == threadId:
            openAssistantIndex = nil
            rows.append(.init(id: itemID, kind: "toolCall", body: ""))   // status: never set
        default:
            break
        }
    }

    mutating func appendUserPrompt(_ text: String) {
        openAssistantIndex = nil
        rows.append(.init(id: "user-\(rows.count + 1)", kind: "userMessage", body: text))
    }

    mutating func appendNotice(id: String, title _: String, text: String) {
        rows.append(.init(id: id, kind: "message", body: text))
    }
}

// MARK: - the scripts, built from the one corpus

private enum TranscriptCompatibilityScripts {
    /// `prose-plain` is two paragraphs; the pre-tool/post-tool script needs both
    /// to be distinguishable, so a fixture edit that collapsed them must fail
    /// here rather than silently make the ordering assertion trivial.
    static let proseParagraphs: [String] = {
        let paragraphs = AgentTranscriptFixtures.source("prose-plain")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        expect(paragraphs.count == 2,
               "prose-plain now holds \(paragraphs.count) paragraph(s); the pre-tool/post-tool ordering script needs exactly 2 distinct bodies")
        expect(paragraphs[0] != paragraphs[1], "prose-plain's two paragraphs are identical; the ordering script could not tell them apart")
        return paragraphs
    }()

    /// The tool call is the corpus's real provider record, parsed rather than
    /// retyped: its call id becomes the item id, its arguments ride the provider
    /// line, and leg 2 proves those arguments never reach a transcript row.
    static var toolCall: (callID: String, tool: String, args: [String: Any], sensitive: [String]) {
        let source = AgentTranscriptFixtures.source("tool-call-arguments")
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = object["tool"] as? String,
              let callID = object["call_id"] as? String,
              let args = object["arguments"] as? [String: Any],
              let command = args["command"] as? String,
              let cwd = args["cwd"] as? String
        else {
            expect(false, "tool-call-arguments must parse as a provider tool-call record with tool/call_id/arguments{command,cwd}")
            fatalError("unreachable: expect() exits")
        }
        return (callID, tool, args, [command, cwd])
    }

    static var preToolProseToolPostToolProse: TranscriptCompatibilityScript {
        let head = String(proseParagraphs[0].prefix(40))
        let tail = String(proseParagraphs[0].dropFirst(40))
        return TranscriptCompatibilityScript(
            name: "pre-tool prose, tool record, post-tool prose",
            steps: TranscriptCompatibilityHarness.sessionPrefix + [
                TranscriptCompatibilityHarness.turnStart,
                TranscriptCompatibilityHarness.textDelta(head),
                TranscriptCompatibilityHarness.textDelta(tail),
                TranscriptCompatibilityHarness.toolStart(callID: toolCall.callID, tool: toolCall.tool, args: toolCall.args),
                TranscriptCompatibilityHarness.toolEnd(callID: toolCall.callID, tool: toolCall.tool, isError: false),
                TranscriptCompatibilityHarness.textDelta(proseParagraphs[1]),
                TranscriptCompatibilityHarness.turnEnd,
                TranscriptCompatibilityHarness.settled
            ]
        )
    }

    static var twoTurns: TranscriptCompatibilityScript {
        TranscriptCompatibilityScript(
            name: "a new turn does not append into the previous turn",
            steps: TranscriptCompatibilityHarness.sessionPrefix + [
                TranscriptCompatibilityHarness.turnStart,
                TranscriptCompatibilityHarness.textDelta(proseParagraphs[0]),
                TranscriptCompatibilityHarness.turnEnd,
                TranscriptCompatibilityHarness.turnStart,
                TranscriptCompatibilityHarness.textDelta(proseParagraphs[1]),
                TranscriptCompatibilityHarness.turnEnd,
                TranscriptCompatibilityHarness.settled
            ]
        )
    }

    /// The same claim where it is load-bearing: a turn that never ended. Pi emits
    /// `turn_end` on a clean turn, so `twoTurns` above would still split if only
    /// the completion boundary reset the open run — an interrupted or dropped turn
    /// is the case that proves `turn_start` itself ends it.
    static var turnStartWithoutPreviousEnd: TranscriptCompatibilityScript {
        TranscriptCompatibilityScript(
            name: "a turn that never ended does not absorb the next turn",
            steps: TranscriptCompatibilityHarness.sessionPrefix + [
                TranscriptCompatibilityHarness.turnStart,
                TranscriptCompatibilityHarness.textDelta(proseParagraphs[0]),
                TranscriptCompatibilityHarness.turnStart,
                TranscriptCompatibilityHarness.textDelta(proseParagraphs[1])
            ]
        )
    }

    static var userPromptThenReply: TranscriptCompatibilityScript {
        TranscriptCompatibilityScript(
            name: "the user's prompt is its own row above the reply",
            steps: TranscriptCompatibilityHarness.sessionPrefix + [
                .userPrompt(AgentTranscriptFixtures.source("user-question")),
                TranscriptCompatibilityHarness.turnStart,
                TranscriptCompatibilityHarness.textDelta(proseParagraphs[0]),
                TranscriptCompatibilityHarness.turnEnd,
                TranscriptCompatibilityHarness.settled
            ]
        )
    }

    static var activeTool: TranscriptCompatibilityScript {
        TranscriptCompatibilityScript(
            name: "an unfinished tool remains active",
            steps: TranscriptCompatibilityHarness.sessionPrefix + [
                TranscriptCompatibilityHarness.turnStart,
                TranscriptCompatibilityHarness.toolStart(callID: toolCall.callID, tool: toolCall.tool, args: toolCall.args)
            ]
        )
    }

    static var failedTool: TranscriptCompatibilityScript {
        TranscriptCompatibilityScript(
            name: "a failed tool keeps its failure",
            steps: TranscriptCompatibilityHarness.sessionPrefix + [
                TranscriptCompatibilityHarness.turnStart,
                TranscriptCompatibilityHarness.toolStart(callID: toolCall.callID, tool: toolCall.tool, args: toolCall.args),
                TranscriptCompatibilityHarness.toolEnd(callID: toolCall.callID, tool: toolCall.tool, isError: true),
                TranscriptCompatibilityHarness.turnEnd,
                TranscriptCompatibilityHarness.settled
            ]
        )
    }

    static var reasoningAndAssistant: TranscriptCompatibilityScript {
        TranscriptCompatibilityScript(
            name: "reasoning and assistant text do not share a row",
            steps: TranscriptCompatibilityHarness.sessionPrefix + [
                TranscriptCompatibilityHarness.turnStart,
                TranscriptCompatibilityHarness.thinkingDelta("weighing the two shards"),
                TranscriptCompatibilityHarness.textDelta(proseParagraphs[0]),
                TranscriptCompatibilityHarness.thinkingDelta("checking the retention window"),
                TranscriptCompatibilityHarness.turnEnd,
                TranscriptCompatibilityHarness.settled
            ]
        )
    }

    /// The one row the whole streamed message must land in. 5,000 deltas is the
    /// corpus's own split (P0.4), so this is also the assertion that a token does
    /// not create a row.
    static var streamedMessage: TranscriptCompatibilityScript {
        let deltas = AgentTranscriptFixtures.deltas(
            AgentTranscriptFixtures.streamingFixtureID,
            count: AgentTranscriptFixtures.streamingDeltaCount
        )
        return TranscriptCompatibilityScript(
            name: "a 5,000-delta message is one row",
            steps: TranscriptCompatibilityHarness.sessionPrefix
                + [TranscriptCompatibilityHarness.turnStart]
                + deltas.map { TranscriptCompatibilityHarness.textDelta($0) }
                + [TranscriptCompatibilityHarness.turnEnd, TranscriptCompatibilityHarness.settled]
        )
    }

    static var repeatedNotice: TranscriptCompatibilityScript {
        let text = AgentTranscriptFixtures.source("notice-local")
        return TranscriptCompatibilityScript(
            name: "the same notice does not stack up",
            steps: [
                .notice(id: "notice-previous-session", title: "previous session", text: text),
                .notice(id: "notice-previous-session", title: "previous session", text: text)
            ]
        )
    }
}

// MARK: - the checks

func runAgentTranscriptCompatibilityChecks() {
    let cards = TranscriptProjectionUnderTest.cardModel
    let scripts = TranscriptCompatibilityScripts.self
    let prose = scripts.proseParagraphs
    let tool = scripts.toolCall

    // MARK: 1 · the floor — every script's exact projection today
    //
    // Stated as whole-snapshot equality on purpose: a changed id, a lost
    // completion status, a merged turn, a reordered row, or a leaked active-tool
    // count each fail here, and each names the field that moved.
    var floors: [(TranscriptCompatibilityScript, TranscriptCompatibilitySnapshot)] = []

    floors.append((scripts.preToolProseToolPostToolProse, TranscriptCompatibilitySnapshot(
        ids: ["assistant-1", tool.callID, "assistant-3"],
        kinds: ["message", "toolCall", "message"],
        bodies: [prose[0], "", prose[1]],
        statuses: [nil, .completed, nil],
        activeToolCount: 0,
        status: .done
    )))

    floors.append((scripts.twoTurns, TranscriptCompatibilitySnapshot(
        ids: ["assistant-1", "assistant-2"],
        kinds: ["message", "message"],
        bodies: [prose[0], prose[1]],
        statuses: [nil, nil],
        activeToolCount: 0,
        status: .done
    )))

    floors.append((scripts.turnStartWithoutPreviousEnd, TranscriptCompatibilitySnapshot(
        ids: ["assistant-1", "assistant-2"],
        kinds: ["message", "message"],
        bodies: [prose[0], prose[1]],
        statuses: [nil, nil],
        activeToolCount: 0,
        // No turn ever completed and the session is still running.
        status: .working
    )))

    floors.append((scripts.userPromptThenReply, TranscriptCompatibilitySnapshot(
        ids: ["user-1", "assistant-2"],
        kinds: ["userMessage", "message"],
        bodies: [AgentTranscriptFixtures.source("user-question"), prose[0]],
        statuses: [nil, nil],
        activeToolCount: 0,
        status: .done
    )))

    floors.append((scripts.activeTool, TranscriptCompatibilitySnapshot(
        ids: [tool.callID],
        kinds: ["toolCall"],
        bodies: [""],
        statuses: [.inProgress],
        activeToolCount: 1,
        status: .working
    )))

    floors.append((scripts.failedTool, TranscriptCompatibilitySnapshot(
        ids: [tool.callID],
        kinds: ["toolCall"],
        bodies: [""],
        statuses: [.failed],
        activeToolCount: 0,
        status: .done
    )))

    floors.append((scripts.reasoningAndAssistant, TranscriptCompatibilitySnapshot(
        ids: ["reasoning-1", "assistant-2", "reasoning-3"],
        kinds: ["message", "message", "message"],
        bodies: ["weighing the two shards", prose[0], "checking the retention window"],
        statuses: [nil, nil, nil],
        activeToolCount: 0,
        status: .done
    )))

    floors.append((scripts.streamedMessage, TranscriptCompatibilitySnapshot(
        ids: ["assistant-1"],
        kinds: ["message"],
        bodies: [AgentTranscriptFixtures.source(AgentTranscriptFixtures.streamingFixtureID)],
        statuses: [nil],
        activeToolCount: 0,
        status: .done
    )))

    floors.append((scripts.repeatedNotice, TranscriptCompatibilitySnapshot(
        ids: ["notice-previous-session"],
        kinds: ["message"],
        bodies: [AgentTranscriptFixtures.source("notice-local")],
        statuses: [nil],
        // No provider event ever arrived, so the projection is still where a
        // freshly-constructed tile starts.
        activeToolCount: 0,
        status: .configuring
    )))

    for (script, expected) in floors {
        let actual = cards.replay(script)
        let divergences = transcriptSnapshotDivergences(actual, expected)
        expect(divergences.isEmpty,
               "\(cards.name) — \(script.name): the compatibility floor moved: \(divergences.joined(separator: "; "))")
    }

    // Ordering is the floor's headline claim, so it is also asserted directly:
    // the tool row sits BETWEEN the two prose rows, not before or after both.
    let ordered = cards.replay(scripts.preToolProseToolPostToolProse)
    guard let toolRow = ordered.ids.firstIndex(of: tool.callID) else {
        expect(false, "the tool record is missing from the replayed transcript entirely")
        return
    }
    expect(toolRow == 1 && ordered.ids.count == 3,
           "pre-tool prose / tool / post-tool prose must be rows 0,1,2 — got \(ordered.ids)")
    expect(ordered.bodies[0] == prose[0] && ordered.bodies[2] == prose[1],
           "the post-tool paragraph must be its own row below the tool, not appended to the pre-tool row")

    // MARK: 2 · what the projection may not carry
    //
    // The provider line above carries the fixture's real arguments (a command
    // line and a cwd). The translator drops them by construction; this asserts
    // the same thing one layer later, where the floor can see it, so a future
    // projection that "helpfully" surfaced tool arguments is red here.
    let projected = (ordered.ids + ordered.kinds + ordered.bodies).joined(separator: "\n")
    for secret in tool.sensitive {
        expect(!projected.contains(secret),
               "a transcript row carries the tool's arguments (\(secret)); AgentRuntimeEvent has no field for them and the projection must not invent one")
    }
    let sentinelReplay = cards.replay(TranscriptCompatibilityScript(
        name: "sentinel secrets in provider text",
        steps: TranscriptCompatibilityHarness.sessionPrefix + [
            TranscriptCompatibilityHarness.turnStart,
            TranscriptCompatibilityHarness.textDelta(
                AgentTranscriptFixtures.source(AgentTranscriptFixtures.sentinelBearingFixtureID)),
            TranscriptCompatibilityHarness.turnEnd
        ]
    ))
    // The complement: text the provider actually STREAMED is transcript body and
    // must survive verbatim. I5 is about the sync boundary, not about the tile
    // silently eating what the agent said.
    for sentinel in AgentTranscriptFixtures.sensitiveSentinels {
        expect(sentinelReplay.bodies.contains(where: { $0.contains(sentinel) }),
               "streamed assistant text must reach the transcript verbatim; \(sentinel) was dropped on the way")
    }

    // MARK: 3 · the parity comparator, proven on a projection that disagrees
    //
    // The two production projections are compared in leg 4. The deliberately
    // divergent projection additionally proves that the comparator itself bites
    // on the two regressions named by the compatibility floor.
    let divergentScripts = [scripts.twoTurns, scripts.preToolProseToolPostToolProse]
    for script in divergentScripts {
        let reference = cards.replay(script)
        let stub = TranscriptCompatibilityHarness.replay(script, into: DivergentTranscriptProjectionStub.self)
        let divergences = transcriptSnapshotDivergences(stub, reference)
        expect(!divergences.isEmpty,
               "the parity comparator found no difference between the card model and a projection built to merge turns and drop status — it would not catch a real divergence either (\(script.name))")
    }
    let mergedTurns = TranscriptCompatibilityHarness.replay(scripts.twoTurns, into: DivergentTranscriptProjectionStub.self)
    expect(transcriptSnapshotDivergences(mergedTurns, cards.replay(scripts.twoTurns)).contains(where: { $0.hasPrefix("ids ") }),
           "a projection that merged two turns into one row must be reported as an id divergence, got \(transcriptSnapshotDivergences(mergedTurns, cards.replay(scripts.twoTurns)))")
    let droppedStatus = TranscriptCompatibilityHarness.replay(scripts.preToolProseToolPostToolProse, into: DivergentTranscriptProjectionStub.self)
    expect(transcriptSnapshotDivergences(droppedStatus, cards.replay(scripts.preToolProseToolPostToolProse))
               .contains(where: { $0.hasPrefix("statuses ") }),
           "a projection that dropped the tool's completion status must be reported as a status divergence, got \(transcriptSnapshotDivergences(droppedStatus, cards.replay(scripts.preToolProseToolPostToolProse)))")
    // And a projection compared with ITSELF must be silent, or every parity
    // failure above would be indistinguishable from noise.
    expect(transcriptSnapshotDivergences(reference: cards, script: scripts.preToolProseToolPostToolProse).isEmpty,
           "the comparator reported a difference between two replays of the same projection — it is not deterministic")

    // MARK: 4 · every registered production projection agrees
    for script in floors.map(\.0) {
        let snapshots = transcriptProjectionsUnderTest.map { ($0.name, $0.replay(script)) }
        guard let (referenceName, referenceSnapshot) = snapshots.first else {
            expect(false, "no transcript projection is registered — the compatibility floor asserts nothing")
            return
        }
        for (name, snapshot) in snapshots.dropFirst() {
            let divergences = transcriptSnapshotDivergences(snapshot, referenceSnapshot)
            expect(divergences.isEmpty,
                   "\(name) disagrees with \(referenceName) on \(script.name): \(divergences.joined(separator: "; "))")
        }
    }
    expect(transcriptProjectionsUnderTest.contains(where: { $0.name == TranscriptProjectionUnderTest.cardModel.name }),
           "the card model must stay registered until the compatibility-removal ticket: it is the floor everything else is compared to")
    expect(transcriptProjectionsUnderTest.contains(where: { $0.name == TranscriptProjectionUnderTest.semanticDocument.name }),
           "the semantic document projection must stay registered beside the card model")
    expect(transcriptProjectionsUnderTest.count == 2,
           "the compatibility corpus must exercise exactly the card and semantic production projections")

    print("Agent transcript compatibility checks passed: \(floors.count) replayed script(s) on the real translator→remap→projection path, \(transcriptProjectionsUnderTest.count) registered projection(s), tool arguments absent from every row, comparator proven against a divergent stub")
}

/// Two replays of the same projection must produce the same snapshot.
private func transcriptSnapshotDivergences(
    reference: TranscriptProjectionUnderTest,
    script: TranscriptCompatibilityScript
) -> [String] {
    transcriptSnapshotDivergences(reference.replay(script), reference.replay(script))
}
