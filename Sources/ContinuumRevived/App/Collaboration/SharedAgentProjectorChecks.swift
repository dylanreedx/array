import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// COL-15 witness over the production supervisor: real `transcriptAttachment`,
/// real delivery path, real bound-runner capability reads, the production
/// projector and host owner. The transport is the portable service log behind
/// an in-memory sink that can fail, drop or refuse like the HTTP route does.
@MainActor
enum SharedAgentProjectorChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    typealias P = Collaboration.AgentProjection

    private static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(description: label) }
        print("PASS agent projection host: \(label)")
    }

    /// The service log, reached through the projector's sink seam.
    final class LogSink: SharedAgentProjectionSink {
        var log: P.Log?
        var batches: [Data] = []
        var failNext = 0
        /// Acknowledge but lose the next frame, as a broken proxy would.
        var dropNextFrame = false
        func publish(_ batch: P.Batch) async throws {
            if failNext > 0 { failNext -= 1; throw Failure(description: "transient transport failure") }
            batches.append(try JSONEncoder().encode(batch))
            var frames = batch.frames
            if dropNextFrame, !frames.isEmpty { frames.removeFirst(); dropNextFrame = false }
            if log == nil {
                guard let snapshot = batch.snapshot else { throw SharedAgentProjectionRefusal.resnapshotRequired }
                log = P.Log(snapshot: snapshot)
            }
            do { try log!.publish(.init(snapshot: batch.snapshot, frames: frames)) }
            catch P.Log.Failure.staleGeneration { throw SharedAgentProjectionRefusal.superseded }
            catch P.Log.Failure.apply { throw SharedAgentProjectionRefusal.resnapshotRequired }
        }
    }

    static func run() async throws {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(description: "isolated support required")
        }
        let root = URL(fileURLWithPath: support).appendingPathComponent("agent-projection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        let project = UUID()
        func record(_ harness: AgentHarness, _ name: String) throws -> AgentID {
            let id = AgentID(rawValue: UUID())
            try store.upsert(AgentRecord(id: id, displayName: name, harness: harness, model: "scripted/projection", thinking: "none",
                                         cwd: root.path, projectId: project, createdAt: Date(), lastActivityAt: Date()))
            return id
        }
        let claude = try record(.claudeCode, "Claude source"), codex = try record(.codex, "Codex source"), pi = try record(.pi, "Pi source")
        var executors = 0
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in executors += 1; return ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        _ = supervisor.restore()
        func deliver(_ event: AgentRuntimeEvent, _ id: AgentID) { supervisor.qaDeliver(event, to: id) }
        let thread = AgentSupervisor.threadId(for: claude)
        /// Until the tail has drained: the head stops moving for several turns.
        func drain(_ projector: SharedAgentProjector, atLeast through: UInt64) async throws {
            var last = UInt64.max, stable = 0
            for _ in 0..<400 {
                await Task.yield()
                let now = projector.log.head.through
                if now >= through, now == last { stable += 1; if stable >= 3 { return } } else { stable = 0 }
                last = now
                try await Task.sleep(for: .milliseconds(2))
            }
            throw Failure(description: "projector never settled at sequence \(through) (at \(projector.log.head.through))")
        }
        func settle(_ projector: SharedAgentProjector, _ sink: LogSink, through: UInt64) async throws {
            try await drain(projector, atLeast: through)
            await projector.flush()
            guard sink.log?.head == projector.log.head else { throw Failure(description: "delivered log diverged from the host head") }
        }

        // 1. Private history before publication, then a snapshot/tail race.
        deliver(.turnStarted(threadId: thread, turnId: "before"), claude)
        deliver(.contentDelta(threadId: thread, turnId: "before", streamKind: .assistant, delta: "HISTORY-MARKER answer"), claude)
        deliver(.turnCompleted(threadId: thread, turnId: "before", outcome: .completed, errorMessage: nil), claude)
        let host = SharedArea.ID<SharedArea.Host>(), object = SharedArea.ID<SharedArea.Object>()
        let first = try SharedAgentProjectionGenerations.next(directory: root, object: object)
        let sink = LogSink()
        let projector = try SharedAgentProjector(supervisor: supervisor, agent: claude, host: host, object: object,
                                                 generation: first, sink: sink)
        // Same main-actor turn as the attach: these can only be in the tail.
        deliver(.turnStarted(threadId: thread, turnId: "live"), claude)
        deliver(.contentDelta(threadId: thread, turnId: "live", streamKind: .assistant, delta: "LIVE-ONE "), claude)
        await Task.yield()
        let privateEvents: [AgentRuntimeEvent] = [
            .contentDelta(threadId: thread, turnId: "live", streamKind: .reasoning, delta: "PRIVATE-REASONING"),
            .itemStarted(threadId: thread, itemId: "tool-1", kind: .commandExecution, title: "PRIVATE-TITLE cat ~/.ssh/id_ed25519"),
            .contentDelta(threadId: thread, turnId: "live", streamKind: .commandOutput, delta: "PRIVATE-OUTPUT secret=1"),
            .itemCompleted(threadId: thread, itemId: "tool-1", kind: .commandExecution, status: .completed),
            .requestOpened(threadId: thread, requestId: "PRIVATE-REQUEST-ID", kind: .commandExecutionApproval),
            .requestResolved(threadId: thread, requestId: "PRIVATE-REQUEST-ID", decision: "accept"),
            .tokenUsageUpdated(threadId: thread, snapshot: .init(inputTokens: 424242, outputTokens: 17, totalCostUsd: nil)),
            .runtimeError(threadId: thread, message: "PRIVATE-ERROR /Users/someone/project"),
        ]
        for event in privateEvents { deliver(event, claude) }
        deliver(.contentDelta(threadId: thread, turnId: "live", streamKind: .assistant, delta: "LIVE-TWO\u{1B}[0m"), claude)
        deliver(.turnCompleted(threadId: thread, turnId: "live", outcome: .failed, errorMessage: "PRIVATE-TURN-ERROR"), claude)
        try await settle(projector, sink, through: 6)
        var replica = P.Replica()
        _ = replica.receive(sink.log!.read(after: nil))
        let rows = replica.state?.rows ?? []
        try expect(rows.filter { $0.kind == .assistant }.map(\.text) == ["LIVE-ONE ", "LIVE-TWO[0m"]
            && rows.contains { $0.kind == .tool(.command) && $0.status == .completed },
            "events delivered in the attach turn and after it each arrive once; the tool call ends the text row")
        try expect(replica.state == projector.log.head && replica.state?.phase == .failed,
            "a late joiner's snapshot equals the host's projected head, including the failed outcome")
        let bytes = sink.batches.reduce(Data(), +), text = String(decoding: bytes, as: UTF8.self)
        let leaked = ["HISTORY-MARKER", "PRIVATE-", "424242", "id_ed25519", "someone", "tool-1", "live\"", "\u{1B}"].filter { text.contains($0) }
        try expect(leaked.isEmpty && !bytes.isEmpty,
            "delivered bytes hold no pre-publication history, reasoning, tool title/output, request, usage, error text, provider id or escape (leaked: \(leaked))")

        // 2. History is the owner's explicit choice, assistant output only.
        let historySink = LogSink()
        let withHistory = try SharedAgentProjector(supervisor: supervisor, agent: claude, host: host, object: .init(),
            generation: 1, history: .assistantOutput, sink: historySink)
        await withHistory.flush()
        let historyText = String(decoding: historySink.batches.reduce(Data(), +), as: UTF8.self)
        try expect(historyText.contains("HISTORY-MARKER answer") && !historyText.contains("PRIVATE-"),
            "included history carries assistant output only (delivered: \(historyText.prefix(1200)))")
        withHistory.stop()

        // 3. A background turn Array did not send still projects, with no executor.
        deliver(.turnStarted(threadId: thread, turnId: "background"), claude)
        try await settle(projector, sink, through: projector.log.head.through + 1)
        let working = sink.log?.head.phase
        deliver(.contentDelta(threadId: thread, turnId: "background", streamKind: .assistant, delta: "Background job finished."), claude)
        deliver(.turnCompleted(threadId: thread, turnId: "background", outcome: .completed, errorMessage: nil), claude)
        try await settle(projector, sink, through: projector.log.head.through + 2)
        try expect(working == .working && sink.log?.head.phase == .ready && sink.log?.head.rows.last?.text == "Background job finished."
            && executors == 0 && !supervisor.isRunning(claude),
            "an unsolicited background turn updates the shared status and text without constructing an executor")

        // 4. Transport loss: a failed delivery keeps frames; a lost frame forces a resnapshot.
        var viewer = P.Replica()
        _ = viewer.receive(sink.log!.read(after: nil))
        sink.failNext = 1
        deliver(.turnStarted(threadId: thread, turnId: "lossy"), claude)
        try await drain(projector, atLeast: 1)
        await projector.flush()
        let retained = sink.log!.head.through < projector.log.head.through
        await projector.flush()
        try expect(retained && sink.log?.head == projector.log.head, "a failed delivery retains its frames and the next delivery catches up")
        sink.dropNextFrame = true
        deliver(.contentDelta(threadId: thread, turnId: "lossy", streamKind: .assistant, delta: "dropped "), claude)
        deliver(.contentDelta(threadId: thread, turnId: "lossy", streamKind: .assistant, delta: "then kept"), claude)
        try await settle(projector, sink, through: projector.log.head.through + 2)
        _ = viewer.receive(sink.log!.read(after: viewer.cursor))
        try expect(sink.log?.head == projector.log.head && viewer.state == projector.log.head
            && viewer.state?.rows.last?.text == "dropped then kept",
            "a frame lost after acknowledgement is refused as a gap, the host resends its snapshot and the viewer converges")
        sink.failNext = Int.max
        for index in 0..<(P.retainedFrames + 20) {
            deliver(.contentDelta(threadId: thread, turnId: "lossy", streamKind: .assistant, delta: "\(index % 10)"), claude)
        }
        try await drain(projector, atLeast: 1)
        sink.failNext = 0
        await projector.flush()
        let overflowRead = sink.log!.read(after: viewer.cursor)
        if case .frames = overflowRead { throw Failure(description: "overflowed viewer paged instead of resnapshotting") }
        _ = viewer.receive(overflowRead)
        try expect(viewer.state == projector.log.head, "an outbox overflow during an outage delivers one snapshot; the old cursor resnapshots")

        // 5. Relaunch: a new persisted generation supersedes; the old session is dead.
        let second = try SharedAgentProjectionGenerations.next(directory: root, object: object)
        let relaunched = try SharedAgentProjector(supervisor: supervisor, agent: claude, host: host, object: object,
                                                  generation: second, sink: sink)
        await relaunched.flush()
        deliver(.turnStarted(threadId: thread, turnId: "after-relaunch"), claude)
        try await drain(relaunched, atLeast: 1)
        await projector.flush()
        await relaunched.flush()
        _ = viewer.receive(sink.log!.read(after: viewer.cursor))
        try expect(second > first && projector.superseded && sink.log?.head.generation == second
            && viewer.state?.generation == second && viewer.state == relaunched.log.head,
            "the relaunched generation \(second) supersedes \(first); the old projector's late frames are refused and it stops")
        relaunched.stop()

        // 6. Capabilities come from the BOUND runner, for all three production harnesses.
        // The supervisor's own factory builds them from each record, exactly as a
        // send would; construction spawns nothing, so no CLI starts here.
        func productionRunner(_ id: AgentID, _ type: String) throws -> AgentRunning {
            guard let record = supervisor.records[id] else { throw Failure(description: "missing \(type) record") }
            let runner = AgentSupervisor.productionRunner(for: AgentRunnerLaunch(record: record, spawnDepth: 0))
            guard String(describing: Swift.type(of: runner)) == type else {
                throw Failure(description: "the production factory built \(Swift.type(of: runner)) for \(type)")
            }
            return runner
        }
        let production: [(AgentID, AgentRunning, String)] = [
            (claude, try productionRunner(claude, "ClaudeAgentRunner"), "Claude"),
            (codex, try productionRunner(codex, "CodexAgentRunner"), "Codex"),
            (pi, try productionRunner(pi, "PiRpcAgentRunner"), "Pi RPC"),
        ]
        for (id, runner, name) in production {
            let idle = SharedAgentProjector.read(supervisor, id).1
            supervisor.qaBindRunnerForCapabilities(runner, for: id)
            let busy = SharedAgentProjector.read(supervisor, id).1
            let controls = P.RemoteControls(host: busy, role: .editor)
            supervisor.qaBindRunnerForCapabilities(nil, for: id)
            try expect(!idle.canSteer && !idle.canInterrupt && busy.locallyManaged && busy.canSteer && busy.canInterrupt
                && busy.canQueue && !busy.canSend && !controls.send && controls.queue && !controls.steer && !controls.interrupt
                && !controls.approveProviderRequest,
                "\(name): a bound production runner advertises steer/interrupt to its host; remotely only queue is offered and approvals are not")
        }
        let sharedSink = LogSink()
        let sharedProjector = try SharedAgentProjector(supervisor: supervisor, agent: codex, host: host, object: .init(), generation: 1, sink: sharedSink)
        supervisor.qaBindRunnerForCapabilities(production[1].1, for: codex)
        try await settle(sharedProjector, sharedSink, through: 1)
        try expect(sharedSink.log?.head.capabilities.canInterrupt == true && sharedSink.log?.head.through ?? 0 >= 1,
            "a runner binding change reaches recipients as a sequenced capability frame through the supervisor's observer")
        supervisor.qaBindRunnerForCapabilities(nil, for: codex)
        sharedProjector.stop()

        // 7. QA-only responders and watched sessions never look controllable.
        let responder = ProviderRequestResponseChecks.RespondingRunner()
        supervisor.qaBindRunnerForCapabilities(responder, for: pi)
        let qaTurn = supervisor.turnSnapshot(for: pi)?.capabilities
        let qa = SharedAgentProjector.read(supervisor, pi).1
        supervisor.qaBindRunnerForCapabilities(nil, for: pi)
        let qaWire = String(decoding: try JSONEncoder().encode(qa), as: UTF8.self)
        try expect(qaTurn?.canRespondToRequests == true && !qa.canSteer && !qa.canInterrupt
            && !P.RemoteControls(host: qa, role: .editor).approveProviderRequest && !qaWire.lowercased().contains("respond"),
            "a QA responder that the supervisor would let answer requests publishes no approval or steer control")
        var watched = try XCTUnwrapRecord(supervisor, pi)
        watched.capabilities = .observedReadOnly
        try store.upsert(watched)
        let observer = AgentSupervisor(store: store, makeRunner: { _ in executors += 1; return ScriptedAgentRunner(script: []) },
                                       warn: { _ in }, nameTitlerCommand: { _ in nil },
                                       transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("observer-transcripts", isDirectory: true)))
        _ = observer.restore()
        let observed = SharedAgentProjector.read(observer, pi).1
        try expect(observer.records[pi]?.capabilities.locallyManaged == false && observer.turnSnapshot(for: pi) != nil
            && !observed.locallyManaged && !observed.canSend && !observed.canQueue && !observed.canInterrupt
            && !P.RemoteControls(host: observed, role: .editor).queue,
            "a watched (not locally managed) session publishes no controls, even to the control holder")

        // 8. The recipient side: remounting views is replica-only, zero executors.
        let recipient = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("recipient")),
                                        makeRunner: { _ in executors += 1; return ScriptedAgentRunner(script: []) })
        _ = recipient.restore()
        for _ in 0..<3 {
            var mounted = P.Replica()
            _ = mounted.receive(sink.log!.read(after: nil))
            guard mounted.state == sink.log?.head else { throw Failure(description: "remount diverged") }
        }
        try expect(executors == 0 && recipient.records.isEmpty && supervisor.records.count == 3,
            "three recipient remounts read projections only: zero executors, zero recipient records, source records unchanged")

        // 9. The production owner: host session bindings drive projectors.
        let hostOwner = SharedAreaAgentProjectionHost(supervisor: supervisor, directory: root) { _ in LogSink() }
        let bindingObject = SharedArea.ID<SharedArea.Object>()
        hostOwner.sync([.init(object: bindingObject, binding: .init(), host: host, projectID: project, agentID: codex),
                        .init(object: .init(), binding: .init(), host: host, projectID: UUID(), agentID: claude)])
        let created = hostOwner.projectors.count
        hostOwner.sync([])
        try expect(created == 1 && hostOwner.projectors.isEmpty,
            "the host owner projects only bindings whose record belongs to the bound project, and unpublishing stops them")
        hostOwner.stop()
        projector.stop()
    }

    private static func XCTUnwrapRecord(_ supervisor: AgentSupervisor, _ id: AgentID) throws -> AgentRecord {
        guard let record = supervisor.records[id] else { throw Failure(description: "missing record") }
        return record
    }
}
