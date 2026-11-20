import AppKit
import ContinuumRevivedCore
import Foundation

// General latency — the outbox rescan every finished turn paid on the main thread.
//
// `drainQueue` (the drain `clearRunner` starts after each turn) asked the outbox for
// every entry, which re-listed and JSON-decoded the whole directory. Production
// fixture: 500 retained entries, 8 recipients, 200 drains driven through the real
// supervisor. `CONTINUUM_QA_LEGACY_OUTBOX_RESCAN=1` brings the rescan back.
extension AppDelegate {
    @MainActor
    static func runOutboxDrainCostSelfCheck() async throws -> String {
        struct Failure: Error, CustomStringConvertible { let description: String }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("outbox-drain-cost-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let store = AgentStore(applicationSupportDirectory: root)
        let queue = AgentComposerDraftStore(applicationSupportDirectory: root)
        let ids = (0..<8).map { _ in AgentID(rawValue: UUID()) }
        for (i, id) in ids.enumerated() {
            try store.upsert(AgentRecord(id: id, displayName: "Drain \(i)", harness: .pi,
                model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: root.path,
                projectId: UUID(), createdAt: Date(), lastActivityAt: Date()))
        }
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
            warn: { _ in }, nameTitlerCommand: { _ in nil }, submissionRecoveryStore: queue)
        let date = Date()
        for i in 0..<500 {
            let context = AgentMessageQueueContext(caller: ids[0], recipient: ids[i % 8],
                operationId: "op\(i)", idempotencyKey: "key\(i)", payloadHash: "fixture")
            var entry = AgentMessageOutbox.Entry(context: context, message: .init(
                text: "message \(i)", queuedAt: date.addingTimeInterval(Double(i)), agentMessageContext: context))
            entry.phase = .settled
            try supervisor.agentMessageOutbox.save(entry)
        }
        let decodedBefore = AgentMessageOutbox.entriesDecodedForQA
        let start = ContinuousClock.now
        for round in 0..<25 {
            for id in ids { supervisor.qaDrainQueueForChecks(id) }
            for id in ids { await supervisor.qaQueueWritesSettled(for: id) }
            _ = round
        }
        let elapsed = ContinuousClock.now - start
        let decodes = AgentMessageOutbox.entriesDecodedForQA - decodedBefore
        guard decodes <= 500 else {
            throw Failure(description: "outbox drain cost: \(decodes) entry decodes for 200 drains (expected <= 500), \(elapsed)")
        }
        return "outbox drain cost: \(decodes) entry decodes for 200 drains, \(elapsed)"
    }
}
