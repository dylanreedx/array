import Foundation
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// Where a host's transcript publishes go. Production is the area controller.
@MainActor
protocol SharedAgentTranscriptSink: AnyObject {
    func publish(stream: String, checkpoint: Collaboration.AgentTranscript.Checkpoint?,
                 frames: [Collaboration.AgentTranscript.Frame]) async throws
}

enum SharedAgentTranscriptRefusal: Error, Equatable {
    /// The relay cannot place the frames (gap, restart, retention): checkpoint.
    case checkpointRequired
    /// A newer session publishes this stream; this one is dead.
    case superseded
    /// The relay has no transcript lane (older than this build).
    case unavailable
}

/// Host side of a published agent's whole transcript: the supervisor's own
/// semantic document, sent as a checkpoint plus entry/block patches. The
/// teammate's view rebuilds that document and draws it with the host tile's
/// renderer. Read-only over the supervisor, like `SharedAgentProjector`.
///
/// No outbox: the published window is the only state. A patch is recomputed
/// from it on each tick, so a refused or lost publish costs one checkpoint,
/// never a divergent replica.
@MainActor
final class SharedAgentTranscriptPublisher {
    typealias Lane = Collaboration.AgentTranscript
    typealias Wire = SharedAgentTranscriptWire

    static let interval: Duration = .milliseconds(250)

    let agent: AgentID
    let stream: String
    let generation: UInt64
    private let document: @MainActor () -> AgentDocument?
    /// The shared agent's helper roster (main stream only; nil sends none).
    private let helpers: (@MainActor () -> [Wire.Helper])?
    /// The roster as the guest now holds it.
    private(set) var publishedHelpers: [Wire.Helper]?
    /// After a roster reaches the relay: the host session starts and stops
    /// each helper's own stream from it.
    var onHelpersPublished: (([Wire.Helper]) -> Void)?
    private let sink: SharedAgentTranscriptSink
    private let budget: SharedAgentTranscriptBudget
    /// Host entries (before the budget) as the guest now holds them.
    private(set) var published: [AgentEntry] = []
    private(set) var through: UInt64 = 0
    private var lastVersion: UInt64?
    private var needsCheckpoint = true
    private var bytesSinceCheckpoint = 0
    private var loop: Task<Void, Never>?
    private var publishing = false
    private(set) var superseded = false
    private(set) var laneUnavailable = false
    private(set) var lastError: (any Error)?
    private(set) var checkpoints = 0
    private(set) var frames = 0

    init(agent: AgentID, stream: String = Lane.mainStream, generation: UInt64,
         budget: SharedAgentTranscriptBudget = SharedAgentTranscriptTruncatingBudget(),
         sink: SharedAgentTranscriptSink, helpers: (@MainActor () -> [Wire.Helper])? = nil,
         document: @escaping @MainActor () -> AgentDocument?) {
        self.agent = agent; self.stream = stream; self.generation = generation
        self.budget = budget; self.sink = sink; self.helpers = helpers; self.document = document
    }

    /// The main stream carries the agent's helper roster; a helper's own
    /// stream (`childStream`) carries only its transcript.
    convenience init(supervisor: AgentSupervisor, agent: AgentID, stream: String = Lane.mainStream, generation: UInt64,
                     sink: SharedAgentTranscriptSink) {
        let roster: (@MainActor () -> [Wire.Helper])? = stream == Lane.mainStream ? { @MainActor [weak supervisor] in
            supervisor.map { SharedAgentHelpers.roster($0, lead: agent) } ?? []
        } : nil
        self.init(agent: agent, stream: stream, generation: generation, sink: sink, helpers: roster) { [weak supervisor] in
            supervisor?.transcriptDocument(for: agent)
        }
    }

    /// Ticks until stopped. A tick whose document version did not move costs a compare.
    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.superseded, !self.laneUnavailable else { return }
                await self.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    /// One publish of whatever changed. Witnesses call this directly.
    func tick() async {
        guard !publishing, !superseded, !laneUnavailable, let current = document() else { return }
        let roster = helpers?()
        if !needsCheckpoint, current.version == lastVersion, roster == publishedHelpers { return }
        publishing = true
        defer { publishing = false }
        do {
            if needsCheckpoint || bytesSinceCheckpoint > Lane.checkpointAfterBytes {
                try await sendCheckpoint(current, roster: roster)
            } else if var ops = current.version == lastVersion ? [] : patch(to: current.entries) {
                ops = ops.map(fitted)
                if let roster, roster != publishedHelpers { ops.append(.helpers(roster)) }
                if !ops.isEmpty {
                    let body = try Wire.encode(Wire.Patch(ops: ops))
                    if body.count > Lane.maxFrameBytes {
                        try await sendCheckpoint(current, roster: roster)
                    } else {
                        let frame = Lane.Frame(generation: generation, sequence: through + 1, body: body)
                        try await sink.publish(stream: stream, checkpoint: nil, frames: [frame])
                        through += 1; frames += 1; bytesSinceCheckpoint += body.count
                        published = window(of: current.entries)
                        if let roster, roster != publishedHelpers { publishedHelpers = roster; onHelpersPublished?(roster) }
                    }
                }
                lastVersion = current.version
            } else {
                try await sendCheckpoint(current, roster: roster)
            }
            lastError = nil
        } catch SharedAgentTranscriptRefusal.superseded {
            lastError = SharedAgentTranscriptRefusal.superseded; superseded = true; stop()
        } catch SharedAgentTranscriptRefusal.unavailable {
            lastError = SharedAgentTranscriptRefusal.unavailable; laneUnavailable = true; stop()
        } catch {
            // Refused, or lost after the relay took it: either way only a
            // checkpoint can say for certain what the guest holds.
            lastError = error; needsCheckpoint = true
        }
    }

    private func sendCheckpoint(_ current: AgentDocument, roster: [Wire.Helper]?) async throws {
        // The roster rides inside the same limit (32 helpers, a few KiB).
        let rosterBytes = try roster.map { try Wire.encode($0).count + 16 } ?? 0
        let window = Wire.window(current.entries, maxBytes: Lane.maxCheckpointBytes - rosterBytes, budget: budget)
        let checkpoint = Wire.Checkpoint(entries: window.entries, omittedEntries: window.omittedEntries, helpers: roster)
        let body = try Wire.encode(checkpoint)
        let next = through + 1
        try await sink.publish(stream: stream, checkpoint: .init(generation: generation, through: next, body: body), frames: [])
        through = next; checkpoints += 1; bytesSinceCheckpoint = 0; needsCheckpoint = false
        published = Array(current.entries.suffix(checkpoint.entries.count))
        lastVersion = current.version
        if let roster { let changed = roster != publishedHelpers; publishedHelpers = roster; if changed { onHelpersPublished?(roster) } }
    }

    /// The current entries from the guest's first one on. Entries before the
    /// window stay on this Mac. Nil if the window's first entry is gone.
    private func window(of entries: [AgentEntry]) -> [AgentEntry] {
        guard let first = published.first?.id, let start = entries.firstIndex(where: { $0.id == first }) else { return entries }
        return Array(entries[start...])
    }

    private func patch(to entries: [AgentEntry]) -> [Wire.Op]? {
        if let first = published.first?.id, !entries.contains(where: { $0.id == first }) { return nil }
        return Wire.patch(from: published, to: window(of: entries))
    }

    private func fitted(_ op: Wire.Op) -> Wire.Op {
        guard case let .block(entry, block) = op else { return op }
        return .block(entry: entry, budget.fit(block, limit: Wire.maxBlockBytes))
    }
}

/// The area controller as a sink, with the relay's refusals made the publisher's.
@MainActor
final class SharedAreaControllerTranscriptSink: SharedAgentTranscriptSink {
    private weak var controller: SharedAreaController?
    private let object: SharedArea.ID<SharedArea.Object>
    private let host: SharedArea.ID<SharedArea.Host>
    init(controller: SharedAreaController?, object: SharedArea.ID<SharedArea.Object>, host: SharedArea.ID<SharedArea.Host>) {
        self.controller = controller; self.object = object; self.host = host
    }
    func publish(stream: String, checkpoint: Collaboration.AgentTranscript.Checkpoint?,
                 frames: [Collaboration.AgentTranscript.Frame]) async throws {
        guard let controller else { throw CollaborationClientError.server(status: 503, code: "notConnected") }
        do {
            try await controller.publishAgentTranscript(object: object, host: host, stream: stream, checkpoint: checkpoint, frames: frames)
        }
        catch CollaborationClientError.server(409, "resyncRequired") { throw SharedAgentTranscriptRefusal.checkpointRequired }
        catch CollaborationClientError.server(409, "revisionConflict") { throw SharedAgentTranscriptRefusal.superseded }
        catch CollaborationClientError.server(404, _) { throw SharedAgentTranscriptRefusal.unavailable }
    }
}
