import ContinuumRevivedCore
import Foundation

private final class DraftWarningBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Deliberately asserts the regressed ordering. The parent check launches this
/// in a subprocess and requires the production assertion to fail, preserving an
/// actual deterministic red witness rather than a comment claiming one occurred.
func runAgentComposerDraftStoreOrderingNegativeWitness() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentComposerDraftStoreNegativeWitness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let agent = AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000009449")!)
    let store = AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 60)
    let older = AgentComposerDraft(text: "older", selection: 0..<5, updatedAt: Date(timeIntervalSince1970: 10))
    let newer = AgentComposerDraft(text: "newer", selection: 0..<5, updatedAt: Date(timeIntervalSince1970: 20))
    await store.save(newer, for: agent)
    await store.save(older, for: agent)
    let restored = await store.load(for: agent)
    expect(restored == older, "negative witness: out-of-order save regressed the newest draft")
}

// Ticket 91/P4.4: sensitive unfinished prompts are local, per-agent, debounced,
// and cleared only at the accepted-send boundary.
func runAgentComposerDraftStoreChecks() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentComposerDraftStoreChecks-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let agentA = AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000009441")!)
    let agentB = AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000009442")!)
    let base = Date(timeIntervalSince1970: 1_800_094_400)
    let draftA = AgentComposerDraft(text: "alpha 👩🏽‍💻 draft", selection: 6..<13, updatedAt: base)
    let draftB = AgentComposerDraft(text: "beta\nsecond line", selection: 2..<9, updatedAt: base.addingTimeInterval(1))
    let warnings = DraftWarningBox()
    let store = AgentComposerDraftStore(
        applicationSupportDirectory: root,
        debounceInterval: 60,
        warn: { warnings.append($0) }
    )

    await store.save(draftA, for: agentA)
    await store.save(draftB, for: agentB)
    let layout = await store.layout

    // Bounded/debounced: save updates memory but does not AtomicWriter/fsync once
    // per keystroke. Negative witness observed red by replacing `save`'s scheduled
    // flush with an immediate `flush(agentID:)` call.
    expect(!FileManager.default.fileExists(atPath: layout.draftFile(for: agentA).path),
           "draft save must be debounced rather than writing per keystroke")
    let pendingA = await store.load(for: agentA)
    expect(pendingA == draftA,
           "an outstanding debounce must still expose the newest in-memory draft")

    let newestA = AgentComposerDraft(
        text: "newest alpha", selection: 2..<7, updatedAt: base.addingTimeInterval(10)
    )
    let olderA = AgentComposerDraft(
        text: "late older alpha", selection: 0..<4, updatedAt: base.addingTimeInterval(5)
    )
    await store.save(newestA, for: agentA)
    await store.save(olderA, for: agentA)
    let pendingNewestA = await store.load(for: agentA)
    expect(pendingNewestA == newestA,
           "an older independently enqueued save must not regress the newest agent draft")

    await store.flushAll()
    expect(FileManager.default.fileExists(atPath: layout.draftFile(for: agentA).path),
           "flush must persist the first agent draft")
    expect(FileManager.default.fileExists(atPath: layout.draftFile(for: agentB).path),
           "flush must persist the second agent draft")

    // A new actor simulates tile detach/re-attach and app relaunch.
    let relaunched = AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 60)
    let restoredA = await relaunched.load(for: agentA)
    let restoredB = await relaunched.load(for: agentB)
    expect(restoredA == newestA,
           "agent A must restore its exact newest text, UTF-16 selection, and timestamp")
    expect(restoredB == draftB,
           "agent B must restore its distinct exact draft")
    expect(restoredA != restoredB,
           "two agents must never alias one shared draft")

    // Rejection preserves both memory and disk. Negative witness observed red by
    // removing the accepted guard in resolveSendIntent: this assertion failed.
    await relaunched.resolveSendIntent(for: agentA, accepted: false)
    let afterRejection = await relaunched.load(for: agentA)
    expect(afterRejection == newestA,
           "a rejected send intent must keep the draft")
    await relaunched.resolveSendIntent(for: agentA, accepted: true)
    let afterAcceptance = await relaunched.load(for: agentA)
    let unaffectedB = await relaunched.load(for: agentB)
    expect(afterAcceptance == nil,
           "an accepted send intent must clear that agent's draft")
    let staleQueuedSave = AgentComposerDraft(
        text: "stale task", selection: 0..<4, updatedAt: Date(timeIntervalSince1970: 1)
    )
    await relaunched.save(staleQueuedSave, for: agentA)
    let afterStaleSave = await relaunched.load(for: agentA)
    expect(afterStaleSave == nil,
           "a pre-acceptance save task arriving late must not resurrect the cleared draft")
    expect(unaffectedB == draftB,
           "clearing agent A must not clear agent B")

    let draftDirectoryAttributes = try FileManager.default.attributesOfItem(atPath: layout.draftsDirectory.path)
    let draftFileAttributes = try FileManager.default.attributesOfItem(atPath: layout.draftFile(for: agentB).path)
    expect((draftDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
           "sensitive draft directory permissions must be 0700")
    expect((draftFileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
           "sensitive draft file permissions must be 0600")
    expect(!FileManager.default.fileExists(atPath: layout.backupsDirectory.path),
           "draft persistence must never create pre-prune backups containing prompt text")
    expect(layout.draftsDirectory.deletingLastPathComponent() == root,
           "drafts must remain in local Application Support")
    expect(!layout.draftsDirectory.path.contains("/agents/"),
           "prompt drafts must not be fields/files in the AgentRecord store")

    // Corrupt only the draft file. Loading fails safely and the independent
    // AgentRecord-like sentinel proves this path cannot delete agent records.
    let sentinel = root.appendingPathComponent("agents/sentinel.json")
    try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("agent-record-sentinel".utf8).write(to: sentinel)
    try Data("{ definitely-not-json".utf8).write(to: layout.draftFile(for: agentB))
    let corruptStore = AgentComposerDraftStore(
        applicationSupportDirectory: root,
        warn: { warnings.append($0) }
    )
    let corruptDraft = await corruptStore.load(for: agentB)
    expect(corruptDraft == nil,
           "a corrupt draft must fail safely to no restored draft")
    expect(FileManager.default.fileExists(atPath: sentinel.path),
           "a corrupt draft must never delete agent records")
    let warningSnapshot = warnings.snapshot()
    expect(warningSnapshot.contains { $0.contains("unreadable draft") },
           "corrupt draft failure should identify the local draft path without logging its body")
    expect(!warningSnapshot.joined(separator: " ").contains(draftB.text),
           "draft diagnostics must never include prompt bodies")

    let witness = Process()
    witness.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    witness.arguments = ["--agent-composer-draft-store-ordering-negative-witness"]
    let witnessError = Pipe()
    witness.standardError = witnessError
    try witness.run()
    witness.waitUntilExit()
    let witnessOutput = String(
        data: witnessError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
    ) ?? ""
    expect(witness.terminationStatus != 0,
           "the out-of-order regression negative witness must be observed red")
    let expectedWitness = "FAIL: negative witness: out-of-order save regressed the newest draft"
    expect(witnessOutput.contains(expectedWitness),
           "the negative witness must fail at the named production ordering assertion")
    print("AgentComposerDraftStore negative witness observed red (exit \(witness.terminationStatus)): \(expectedWitness)")

    print("AgentComposerDraftStore checks passed: two exact per-agent restores, out-of-order rejection with subprocess red witness, debounced AtomicWriter persistence, rejected/accepted send boundaries, no prompt backups, private permissions, and safe corruption isolation")
}
