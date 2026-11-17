import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// The three findings of the 0.7.53 retention review, each asserted through the
/// production path (supervisor event delivery, the tile attachment and the
/// workspace API dispatch), never through a re-derivation of it.
///
/// 1. A helper's result is bound to the turn that produced it, even while a
///    released transcript is still reloading and holds that turn's events.
/// 2. Tool details survive idle release, and a runtime observation that lands
///    during a reload is kept, not dropped.
/// 3. `agent.find` and `agent.inspect` still know an idle agent's referenced
///    files and that its evidence was cut.
@MainActor
enum TranscriptRetentionReviewChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            guard !opened else { return }
            opened = true
            let queued = waiters
            waiters.removeAll()
            queued.forEach { $0.resume() }
        }
    }

    private static func settle(_ done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        return done()
    }

    private static func record(_ id: AgentID, name: String, cwd: String) -> AgentRecord {
        AgentRecord(id: id, displayName: name, harness: .pi, model: AgentCatalogQAFixture.pi[0], thinking: "none",
                    cwd: cwd, createdAt: Date(), lastActivityAt: Date())
    }

    // MARK: Finding 1

    static func runResultBinding(root: URL) async throws {
        let fixture = root.appendingPathComponent("review-result-binding", isDirectory: true)
        let parentCwd = fixture.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parentCwd, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let parent = AgentID(rawValue: UUID()), child = AgentID(rawValue: UUID())
        try agents.upsert(record(parent, name: "Lead", cwd: parentCwd.path))
        var childRecord = record(child, name: "Helper", cwd: fixture.path)
        childRecord.parentAgentID = parent
        childRecord.spawnResultHandle = "review-handle"
        try agents.upsert(childRecord)
        let supervisor = AgentSupervisor(
            store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) }, warn: { _ in },
            nameTitlerCommand: { _ in nil },
            transcriptStore: AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts", isDirectory: true)))
        _ = supervisor.restore()
        let previousDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .zero
        defer {
            AgentSupervisor.transcriptReleaseDelay = previousDelay
            supervisor.qaBeforeResumedTranscriptConstruction = nil
            supervisor.stopAll()
        }
        let thread = AgentSupervisor.threadId(for: child)
        func turn(_ number: Int, answer: String) {
            let id = "bind-\(number)"
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: id), to: child)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: id, streamKind: .assistant, delta: answer), to: child)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: id, outcome: .completed, errorMessage: nil), to: child)
        }
        func result() -> SpawnResultFile? { SpawnResultFile.read(parentCwd: parentCwd.path, handle: "review-handle") }

        turn(1, answer: "FIRST_ANSWER")
        guard await settle({ result()?.finalText?.contains("FIRST_ANSWER") == true }) else {
            throw Failure(description: "the first turn's result never reached the parent: \(String(describing: result()?.finalText))")
        }
        guard await settle({ supervisor.isTranscriptReleased(child) }) else {
            throw Failure(description: "the helper's transcript did not release after its first turn")
        }
        // From here a reloaded transcript stays resident long enough to inspect.
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        // The courier file for turn 1 is consumed; anything that appears next is
        // written by turn 2.
        try FileManager.default.removeItem(at: SpawnResultFile.url(parentCwd: parentCwd.path, handle: "review-handle"))

        let gate = Gate()
        supervisor.qaBeforeResumedTranscriptConstruction = { _, _ in await gate.wait() }
        turn(2, answer: "SECOND_ANSWER")
        try? await Task.sleep(for: .milliseconds(200))
        var failures: [String] = []
        if let early = result() {
            failures.append("the second turn settled while its events were still held behind the reload, with \(early.finalText ?? "no text") (the previous reply is not this turn's result)")
        }
        await gate.open()
        guard await settle({ !supervisor.isTranscriptReleased(child) }) else {
            throw Failure(description: "the reload never finished after the gate opened")
        }
        let settled = await settle({ result() != nil })
        let final = result()?.finalText ?? ""
        if !settled || !final.contains("SECOND_ANSWER") || final.contains("FIRST_ANSWER") {
            failures.append("after the reload the result carried \(settled ? final : "nothing"), not the second turn's SECOND_ANSWER")
        }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "; ")) }
    }

    // MARK: Finding 2

    private static func presentedOutput(_ supervisor: AgentSupervisor, _ id: AgentID, item: String) -> String? {
        guard let document = supervisor.transcriptDocument(for: id) else { return nil }
        for entry in document.entries {
            guard case let .providerItem(_, providerID?) = entry.provenance, providerID == item else { continue }
            var blocks = entry.blocks
            var index = 0
            while index < blocks.count {
                let block = blocks[index]
                index += 1
                blocks.insert(contentsOf: block.children, at: index)
                guard case .toolCall = block.payload,
                      let presented = supervisor.sharedTranscriptPresentedBlock(for: id, block: block, entry: entry),
                      case let .toolCall(call) = presented.payload else { continue }
                return call.presentedOutputText
            }
        }
        return nil
    }

    static func runToolDetails(root: URL) async throws {
        let fixture = root.appendingPathComponent("review-tool-details", isDirectory: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let id = AgentID(rawValue: UUID())
        try agents.upsert(record(id, name: "Tooling", cwd: fixture.path))
        let supervisor = AgentSupervisor(
            store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) }, warn: { _ in },
            nameTitlerCommand: { _ in nil },
            transcriptStore: AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts", isDirectory: true)))
        _ = supervisor.restore()
        let previousDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .zero
        defer {
            AgentSupervisor.transcriptReleaseDelay = previousDelay
            supervisor.qaBeforeResumedTranscriptConstruction = nil
            supervisor.stopAll()
        }
        let thread = AgentSupervisor.threadId(for: id)
        func toolTurn(_ number: Int, output: String) {
            let turnID = "tool-\(number)", item = "call-\(number)"
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: turnID), to: id)
            supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: item, kind: .commandExecution, title: "rg -n marker Sources"), to: id)
            supervisor.qaObserveSharedTranscript(.toolDetail(itemId: item, detail: AgentToolDetailObservation(
                phase: .started, toolName: "Bash", fields: [(key: "command", value: "rg -n marker Sources")],
                observedAt: Date())), for: id)
            supervisor.qaObserveSharedTranscript(.toolDetail(itemId: item, detail: AgentToolDetailObservation(
                phase: .ended, outputPreview: output, exitCode: 0, observedAt: Date())), for: id)
            supervisor.qaDeliver(.itemCompleted(threadId: thread, itemId: item, kind: .commandExecution, status: .completed), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: turnID, streamKind: .assistant, delta: "Done \(number)."), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: turnID, outcome: .completed, errorMessage: nil), to: id)
        }
        func reopen(_ label: String) async {
            let attachment = supervisor.transcriptAttachment(for: id, reboundTo: label)
            let view = Task { for await _ in attachment.tail {} }
            if let reload = attachment.reload { await reload.value }
            await supervisor.qaSharedTranscriptToolDetail(for: id)?.qaWaitForRefresh()
            view.cancel()
        }

        var failures: [String] = []
        toolTurn(1, output: "FIRST_TOOL_OUTPUT")
        await supervisor.qaSharedTranscriptToolDetail(for: id)?.qaWaitForRefresh()
        if presentedOutput(supervisor, id, item: "call-1") != "FIRST_TOOL_OUTPUT" {
            throw Failure(description: "the tool output was not presented before release: \(String(describing: presentedOutput(supervisor, id, item: "call-1")))")
        }
        guard await settle({ supervisor.isTranscriptReleased(id) }) else {
            throw Failure(description: "the tooling agent did not release")
        }
        await reopen("review-reopen")
        if presentedOutput(supervisor, id, item: "call-1") != "FIRST_TOOL_OUTPUT" {
            failures.append("release destroyed the tool output: \(String(describing: presentedOutput(supervisor, id, item: "call-1")))")
        }
        guard await settle({ supervisor.isTranscriptReleased(id) }) else {
            throw Failure(description: "the tooling agent did not release a second time")
        }
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        let gate = Gate()
        supervisor.qaBeforeResumedTranscriptConstruction = { _, _ in await gate.wait() }
        toolTurn(2, output: "SECOND_TOOL_OUTPUT")
        try? await Task.sleep(for: .milliseconds(100))
        await gate.open()
        guard await settle({ !supervisor.isTranscriptReleased(id) }) else {
            throw Failure(description: "the reload never finished after the gate opened")
        }
        await supervisor.qaSharedTranscriptToolDetail(for: id)?.qaWaitForRefresh()
        for (item, output) in [("call-1", "FIRST_TOOL_OUTPUT"), ("call-2", "SECOND_TOOL_OUTPUT")] {
            let shown = presentedOutput(supervisor, id, item: item)
            if shown != output {
                failures.append("after a reload that held \(item), its presented output was \(String(describing: shown)), not \(output)")
            }
        }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "; ")) }
    }

    // MARK: Finding 3

    static func runDiscovery() async throws {
        let f = try WorkspaceAPIChecks.makeFixture()
        defer { f.tearDown() }
        let supervisor = f.delegate.qaAgentSupervisor
        guard supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true) else {
            throw Failure(description: "enabling workspace tools changed nothing")
        }
        let previousDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .zero
        defer { AgentSupervisor.transcriptReleaseDelay = previousDelay }
        // A name and role that never say "foo": only the transcript names the file.
        let helper = supervisor.spawn(
            role: nil, prompt: nil, cwd: f.pbRoot, harness: .pi, model: "openai-codex/gpt-5.6-sol",
            thinking: "high", projectId: f.projectPb, projectRoot: f.pbRoot, displayName: "Quiet Helper")
        let thread = AgentSupervisor.threadId(for: helper)
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "d1"), to: helper)
        supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "edit-1", kind: .fileChange, title: "Sources/Foo.swift"), to: helper)
        supervisor.qaDeliver(.itemCompleted(threadId: thread, itemId: "edit-1", kind: .fileChange, status: .completed), to: helper)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "d1", streamKind: .assistant, delta: "Edited it."), to: helper)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "d1", outcome: .completed, errorMessage: nil), to: helper)
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "d2"), to: helper)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "d2", streamKind: .assistant, delta: "Verified."), to: helper)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "d2", outcome: .completed, errorMessage: nil), to: helper)
        f.api.approvalHandler = { _ in .allowOnce }

        var requestCounter = 0
        func dispatch(_ op: String, _ payload: [String: Any]) -> [String: AnyHashableJSON]? {
            requestCounter += 1
            guard case let .result(object) = f.api.dispatch(
                agentId: f.agentId, requestId: "review-\(requestCounter)", op: op, payload: payload) else { return nil }
            return object
        }
        func finds() -> Bool {
            let found = (dispatch("agent.find", ["query": "foo.swift"])?["candidates"]?.array ?? []).compactMap(\.object)
            return found.contains { $0["agent"]?.object?["agentId"]?.string?.lowercased() == helper.rawValue.uuidString.lowercased() }
        }
        func inspected() -> (files: [String], truncated: Bool?)? {
            guard let object = dispatch("agent.inspect", ["agentId": helper.rawValue.uuidString]) else { return nil }
            return ((object["referencedFiles"]?.array ?? []).compactMap(\.string), object["recentEventsTruncated"]?.bool)
        }
        var failures: [String] = []
        if !finds() { throw Failure(description: "agent.find did not find the helper by its referenced file before release") }
        guard let before = inspected(), before.files == ["Sources/Foo.swift"], before.truncated == false else {
            throw Failure(description: "inspect before release gave \(String(describing: inspected()))")
        }
        guard await settle({ supervisor.isTranscriptReleased(helper) }) else {
            throw Failure(description: "the quiet helper's transcript did not release")
        }
        if !finds() { failures.append("agent.find lost the referenced file Sources/Foo.swift once the agent was released") }
        if let after = inspected() {
            if after.files != ["Sources/Foo.swift"] { failures.append("agent.inspect referenced files after release: \(after.files)") }
            if after.truncated != true { failures.append("agent.inspect did not mark its released evidence as truncated: \(String(describing: after.truncated))") }
        } else { failures.append("agent.inspect failed after release") }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "; ")) }
    }

    static func run(root: URL) async throws {
        var failures: [String] = []
        do { try await runResultBinding(root: root) } catch { failures.append("result binding: \(error)") }
        do { try await runToolDetails(root: root) } catch { failures.append("tool details: \(error)") }
        do { try await runDiscovery() } catch { failures.append("discovery: \(error)") }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "\nFAIL: ")) }
    }
}
