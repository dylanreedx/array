import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Pauses each resumed-model construction after disk read. Live writes must
/// stay ordered, and an archived agent must not be recreated by stale work.
@MainActor
enum TranscriptOffMainConstructionChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private actor Gate {
        private(set) var entered = false
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    private final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func read() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class ConstructionObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var ranOnMain = false
        func record(onMain: Bool) { lock.lock(); calls += 1; ranOnMain = ranOnMain || onMain; lock.unlock() }
        func read() -> (Int, Bool) { lock.lock(); defer { lock.unlock() }; return (calls, ranOnMain) }
    }

    static func run(root: URL) async throws {
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay }
        try await check(root: root, preflight: true, archive: false)
        try await check(root: root, preflight: false, archive: false)
        try await check(root: root, preflight: true, archive: true)
        try await check(root: root, preflight: false, archive: true)
    }

    private static func check(root: URL, preflight: Bool, archive: Bool) async throws {
        let label = "\(preflight ? "preflight" : "reload")-\(archive ? "archive" : "writes")"
        let fixture = root.appendingPathComponent("off-main-construction-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts")
        let store = AgentTranscriptStore(root: transcriptRoot)
        let id = AgentID(rawValue: UUID())
        let thread = AgentSupervisor.threadId(for: id)
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        try agents.upsert(AgentRecord(id: id, displayName: "Off-main \(label)", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        var prior = ManagedAgentTranscriptModel(threadId: thread)
        for i in 0..<100 { prior.appendUserPrompt("OFF_MAIN_PRIOR_\(i)") }
        try await store.saveSnapshot(agentID: id, sessionID: session, document: prior.document)
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: store)
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "\(label): missing fixture agent") }
        defer { supervisor.qaBeforeResumedTranscriptConstruction = nil; supervisor.qaOnResumedTranscriptConstruction = nil; supervisor.stopAll() }
        func deliver(_ marker: String) {
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: id)
        }
        if !preflight {
            deliver("OFF_MAIN_SETUP")
            await supervisor.qaSaveTranscript(for: id)
            let deadline = ContinuousClock.now + .seconds(20)
            while !supervisor.isTranscriptReleased(id), ContinuousClock.now < deadline {
                supervisor.qaReleaseTranscriptIfDormant(id)
                await supervisor.qaWaitForTranscriptPersistence(for: id)
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard supervisor.isTranscriptReleased(id) else { throw Failure(description: "\(label): could not release fixture") }
        }
        guard let original = try await store.load(agentID: id, sessionID: session) else {
            throw Failure(description: "\(label): missing prior archive")
        }
        let gate = Gate()
        let observation = ConstructionObservation()
        supervisor.qaBeforeResumedTranscriptConstruction = { agent, isPreflight in
            if agent == id && isPreflight == preflight { await gate.wait() }
        }
        supervisor.qaOnResumedTranscriptConstruction = { agent, isPreflight, onMainThread in
            if agent == id && isPreflight == preflight { observation.record(onMain: onMainThread) }
        }
        defer { Task { await gate.open() } }
        if preflight { deliver("OFF_MAIN_FIRST") }
        else { _ = supervisor.transcriptAttachment(for: id, reboundTo: "off-main-construction") }
        let deadline = ContinuousClock.now + .seconds(20)
        while !(await gate.entered), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        guard await gate.entered else { throw Failure(description: "\(label): constructor never reached gate") }
        let task = preflight ? supervisor.qaCanonicalPreflightTask(for: id) : supervisor.qaTranscriptReloadTask(for: id)
        guard let task else { throw Failure(description: "\(label): construction task is not registered") }
        // These writes execute on the main actor while construction is paused.
        // Their order must be retained through installation and persistence.
        let markers = ["OFF_MAIN_SECOND_END", "OFF_MAIN_THIRD_END"]
        for marker in markers { deliver(marker) }
        if archive {
            let done = Signal()
            supervisor.qaQuarantineFinished = { done.set() }
            defer { supervisor.qaQuarantineFinished = nil }
            guard supervisor.archive(id).recordDeleted else { throw Failure(description: "\(label): archive failed") }
            await gate.open()
            await task.value
            let deadline = ContinuousClock.now + .seconds(20)
            while !done.read(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            let source = transcriptRoot.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
            guard !observation.read().1, done.read(), supervisor.records[id] == nil, supervisor.qaHeldTranscripts.projections == 0,
                  !FileManager.default.fileExists(atPath: source.path) else {
                throw Failure(description: "\(label): stale construction recreated the archived agent or transcript")
            }
            return
        }
        await gate.open()
        await task.value
        let (constructionCalls, constructionOnMain) = observation.read()
        guard constructionCalls == 1, !constructionOnMain else {
            throw Failure(description: "\(label): resumed model was not constructed exactly once off the main thread")
        }
        await supervisor.qaSaveTranscript(for: id)
        guard !supervisor.qaTranscriptPersistenceIsBlocked(id),
              let saved = try await store.load(agentID: id, sessionID: session),
              Array(saved.entries.prefix(original.entries.count)) == original.entries else {
            throw Failure(description: "\(label): saved history lost its prior prefix")
        }
        let text = saved.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        let ordered = preflight ? ["OFF_MAIN_FIRST"] + markers : markers
        var previous: String.Index?
        for marker in ordered {
            guard text.components(separatedBy: marker).count - 1 == 1, let range = text.range(of: marker),
                  previous.map({ $0 < range.lowerBound }) ?? true else {
                throw Failure(description: "\(label): lost, duplicated or reordered \(marker)")
            }
            previous = range.lowerBound
        }
    }
}
