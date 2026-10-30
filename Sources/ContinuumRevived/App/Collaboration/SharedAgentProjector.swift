import CryptoKit
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Where a host's projection batches go. Production is the collaboration
/// service; the witness also substitutes a lossy in-memory transport.
@MainActor
protocol SharedAgentProjectionSink: AnyObject {
    func publish(_ batch: Collaboration.AgentProjection.Batch) async throws
}

/// The two refusals a projector acts on. Anything else is transient: the
/// frames stay in the outbox for the next delivery.
enum SharedAgentProjectionRefusal: Error, Equatable {
    /// The receiver cannot continue from what it holds (a gap, no log yet).
    case resnapshotRequired
    /// A newer generation of this projection exists; this session is dead.
    case superseded
}

/// Host side of a published agent: bridges the supervisor's atomic
/// `transcriptAttachment` snapshot/tail into allowlisted, sequenced frames.
///
/// Read-only over the supervisor. It never sends, stops or spawns; capability
/// facts are read from the BOUND runner through `turnSnapshot`, never from the
/// record's harness. Everything the allowlist below does not name is dropped
/// here, on the host, before any byte is encoded.
@MainActor
final class SharedAgentProjector {
    typealias Projection = Collaboration.AgentProjection

    enum Unavailable: Error, Equatable {
        /// No semantic snapshot boundary: the compatibility tail would replay
        /// bounded history as if it were live, which could publish excluded turns.
        case noSnapshotBoundary
        case unknownAgent
    }

    let agent: AgentID
    let host: SharedArea.ID<SharedArea.Host>
    let object: SharedArea.ID<SharedArea.Object>
    let generation: UInt64
    private let supervisor: AgentSupervisor
    private let sink: SharedAgentProjectionSink
    private let salt = UUID().uuidString
    private(set) var log: Projection.Log
    /// Frames the sink has not acknowledged. Bounded; overflow resends `head`.
    private var outbox: [Projection.Frame] = []
    private var needsSnapshot = true
    private var tailTask: Task<Void, Never>?
    private var capabilityObserver: UUID?
    private var flushing: Task<Void, Never>?
    private var assistantRow: [String: String] = [:]
    private var segment: [String: Int] = [:]
    private(set) var lastError: (any Error)?
    private(set) var deliveredBatches = 0
    private(set) var superseded = false
    /// Called after a frame is queued, so an owner can schedule a flush.
    var onPending: (() -> Void)?

    /// `generation` must exceed every generation this host has published for
    /// `object`; `SharedAgentProjectionGenerations` persists that counter.
    init(supervisor: AgentSupervisor, agent: AgentID, host: SharedArea.ID<SharedArea.Host>,
         object: SharedArea.ID<SharedArea.Object>, generation: UInt64, history: Projection.History = .excluded,
         sink: SharedAgentProjectionSink) throws {
        guard supervisor.hasTranscriptSnapshotBoundary else { throw Unavailable.noSnapshotBoundary }
        guard supervisor.records[agent] != nil else { throw Unavailable.unknownAgent }
        self.supervisor = supervisor; self.agent = agent; self.host = host; self.object = object
        self.generation = generation; self.sink = sink
        // One main-actor step: snapshot and tail registration cannot interleave a
        // delivery, so every later event is in the tail and none is in both.
        let attachment = supervisor.transcriptAttachment(for: agent, reboundTo: AgentSupervisor.threadId(for: agent))
        let rows = history == .assistantOutput ? Self.assistantRows(attachment.snapshot, salt: salt) : []
        let (phase, capabilities) = Self.read(supervisor, agent)
        log = Projection.Log(snapshot: .init(host: host, object: object, generation: generation, history: history,
                                             phase: phase, capabilities: capabilities, rows: rows))
        let tail = attachment.tail
        tailTask = Task { @MainActor [weak self] in
            for await event in tail {
                guard let self else { return }
                self.receive(event)
            }
        }
        capabilityObserver = supervisor.addTurnCapabilitiesObserver { [weak self] id in
            guard let self, id == self.agent else { return }
            self.refreshState()
        }
    }

    func stop() {
        tailTask?.cancel(); tailTask = nil
        if let capabilityObserver { supervisor.removeTurnCapabilitiesObserver(capabilityObserver) }
        capabilityObserver = nil
    }

    /// Delivers everything pending, oldest first. A failed delivery keeps the
    /// frames; when the outbox overflows the next delivery is a full snapshot.
    func flush() async {
        if let flushing { await flushing.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            while needsSnapshot || !outbox.isEmpty {
                let snapshot = needsSnapshot ? log.head : nil
                let frames = snapshot == nil ? Array(outbox.prefix(Projection.maxBatchFrames)) : []
                do {
                    try await sink.publish(.init(snapshot: snapshot, frames: frames))
                    deliveredBatches += 1; lastError = nil
                    if snapshot != nil {
                        needsSnapshot = false
                        outbox.removeAll { $0.sequence <= snapshot!.through }
                    } else {
                        outbox.removeFirst(frames.count)
                    }
                } catch SharedAgentProjectionRefusal.resnapshotRequired where snapshot == nil {
                    // Frames the receiver cannot place are replaced by state.
                    lastError = SharedAgentProjectionRefusal.resnapshotRequired
                    needsSnapshot = true
                } catch SharedAgentProjectionRefusal.superseded {
                    lastError = SharedAgentProjectionRefusal.superseded
                    superseded = true; stop(); outbox.removeAll(); needsSnapshot = false
                    return
                } catch {
                    lastError = error
                    return
                }
            }
        }
        flushing = task
        await task.value
        flushing = nil
    }

    // MARK: - Allowlist

    private func receive(_ event: AgentRuntimeEvent) {
        let thread = AgentSupervisor.threadId(for: agent)
        switch event {
        case let .turnStarted(tid, turn) where tid == thread:
            emit(.turnStarted(turn: digest(turn)))
        case let .turnCompleted(tid, turn, outcome, _) where tid == thread:
            assistantRow[turn] = nil
            // The error text is [BODY]; only the outcome crosses.
            emit(.turnCompleted(turn: digest(turn), outcome: Self.outcome(outcome)))
        case let .contentDelta(tid, turn, .assistant, delta) where tid == thread && !Projection.sanitize(delta).isEmpty:
            let row = assistantRow[turn] ?? {
                let index = segment[turn, default: 0]
                segment[turn] = index + 1
                let id = digest("assistant:\(turn):\(index)")
                assistantRow[turn] = id
                return id
            }()
            for chunk in Self.chunks(Projection.sanitize(delta)) {
                emit(.assistantText(row: row, turn: digest(turn), delta: chunk))
            }
        case let .itemStarted(tid, item, kind, _) where tid == thread:
            // A new assistant message or a tool call ends the current text row.
            for key in assistantRow.keys { assistantRow[key] = nil }
            // The title is [BODY] (commands, paths, queries) and never crosses.
            if let tool = Self.tool(kind) {
                emit(.tool(row: digest("item:\(item)"), turn: nil, kind: tool, status: .running))
            }
        case let .itemCompleted(tid, item, kind, status) where tid == thread:
            if let tool = Self.tool(kind) {
                emit(.tool(row: digest("item:\(item)"), turn: nil, kind: tool, status: Self.status(status)))
            }
        default:
            // Reasoning and command-output deltas, requests and their questions,
            // usage, context, compaction, child spawns, runtime error text and
            // session-state detail are host-private.
            break
        }
        refreshState()
    }

    private func refreshState() {
        let (phase, capabilities) = Self.read(supervisor, agent)
        if phase != log.head.phase { emit(.phase(phase)) }
        if capabilities != log.head.capabilities { emit(.capabilities(capabilities)) }
    }

    private func emit(_ payload: Projection.Payload) {
        let frame = Projection.Frame(host: host, object: object, generation: generation,
                                     sequence: log.head.through + 1, payload: payload)
        do {
            try log.publish(.init(snapshot: nil, frames: [frame]))
        } catch {
            lastError = error; return
        }
        outbox.append(frame)
        if outbox.count > Projection.retainedFrames {
            // The recipient can no longer be brought forward frame by frame.
            outbox.removeAll(); needsSnapshot = true
        }
        onPending?()
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data("\(salt)\u{0}\(value)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Pure mapping

    static func read(_ supervisor: AgentSupervisor, _ agent: AgentID) -> (Projection.Phase, Projection.Capabilities) {
        guard let record = supervisor.records[agent], let turn = supervisor.turnSnapshot(for: agent) else {
            return (.stopped, .none)
        }
        let phase: Projection.Phase
        switch turn.state {
        case .ready, .restored, .queued: phase = .ready
        case .starting: phase = .starting
        case .working, .compacting: phase = .working
        case .needsAction: phase = .needsAction
        case .failed: phase = .failed
        }
        let facts = turn.capabilities
        // `canStop` is deliberately not published: it includes teardown. A bound
        // `AgentSteeringRunning` is exactly what makes `canSteer` true and is also
        // what carries `interrupt()`, which ends the turn and keeps the session.
        return (phase, .init(locallyManaged: record.capabilities.locallyManaged, canSend: facts.canSend,
                             canQueue: facts.canQueue, canSteer: facts.canSteer, canInterrupt: facts.canSteer))
    }

    static func tool(_ kind: ItemKind) -> Projection.ToolKind? {
        switch kind {
        case .commandExecution: return .command
        case .fileChange: return .fileChange
        case .mcpToolCall: return .mcpTool
        case .webSearch: return .webSearch
        case .plan: return .plan
        case .subagent: return .subagent
        case .assistantMessage, .reasoning, .error, .compaction: return nil
        default: return .other
        }
    }

    static func status(_ status: ItemStatus) -> Projection.ToolStatus {
        switch status {
        case .inProgress: return .running
        case .completed: return .completed
        case .failed: return .failed
        case .declined: return .declined
        }
    }

    static func outcome(_ outcome: TurnOutcome) -> Projection.Outcome {
        switch outcome {
        case .completed: return .completed
        case .failed: return .failed
        case .interrupted: return .interrupted
        case .cancelled: return .cancelled
        }
    }

    static func chunks(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        for character in text {
            if current.utf8.count + String(character).utf8.count > Projection.maxDeltaBytes {
                result.append(current); current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Included history is assistant output only, from the semantic snapshot.
    /// Prompts, notices, tool titles and error cards are never history rows.
    static func assistantRows(_ model: ManagedAgentTranscriptModel?, salt: String) -> [Projection.Row] {
        guard let model else { return [] }
        // `.message` cards also carry reasoning entries and system notices; only
        // the assistant role's own cards are output.
        return model.cards.filter { card in
            card.kind == .message && card.title == "assistant" && card.id.hasPrefix("assistant-")
                && !Projection.sanitize(card.body).isEmpty
        }.map { card in
            let id = SHA256.hash(data: Data("\(salt)\u{0}history:\(card.id)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
            var row = Projection.Row(id: id, turn: nil, kind: .assistant)
            var budget = Projection.maxRowTextBytes
            for character in Projection.sanitize(card.body) {
                let size = String(character).utf8.count
                guard size <= budget else { row.truncated = true; break }
                row.text.append(character); budget -= size
            }
            return row
        }
    }
}

/// A monotonic per-object generation counter on the host. A relaunched host
/// therefore always supersedes its previous session in the log and replicas.
enum SharedAgentProjectionGenerations {
    static func next(directory: URL, object: SharedArea.ID<SharedArea.Object>) throws -> UInt64 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("agent-projection-\(object.rawValue.uuidString).generation")
        let prior = (try? String(contentsOf: file, encoding: .utf8)).flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let next = prior + 1
        try Data(String(next).utf8).write(to: file, options: .atomic)
        return next
    }
}
