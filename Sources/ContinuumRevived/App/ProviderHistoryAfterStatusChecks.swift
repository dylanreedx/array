import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Exercises the supervisor and tile half of a provider read completing after a
/// real Array /status notice. The AppDelegate read callback is not invoked.
@MainActor
enum ProviderHistoryAfterStatusChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("provider-history-after-status", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcripts = AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts"))
        let id = AgentID(rawValue: UUID())
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        try agents.upsert(AgentRecord(id: id, displayName: "Provider after status", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
        _ = supervisor.restore()
        defer { supervisor.stopAll() }
        guard let readToken = supervisor.beginProviderHistoryRead(for: id) else {
            throw Failure(description: "fixture could not pin the pending provider read")
        }
        defer { supervisor.endProviderHistoryRead(readToken, for: id) }
        func tile() -> ManagedAgentTileNSView {
            let view = ManagedAgentTileNSView(tile: Tile(id: UUID(), kind: .managedAgent, title: "Provider history",
                frame: TileFrame(x: 0, y: 0, width: 560, height: 620), zPosition: .first, runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed-agent")))
            view.frame = NSRect(x: 0, y: 0, width: 560, height: 620)
            view.attach(agentID: id, supervisor: supervisor)
            return view
        }
        let first = tile()
        defer { first.detach() }
        var notices: [AgentLocalNotice] = []
        let noticeToken = supervisor.addLocalNoticeObserver(for: id) { notices.append($0) }
        defer { supervisor.removeLocalNoticeObserver(noticeToken, for: id) }
        let command = AgentCommandInvocation(descriptorID: "array:status", name: "status", surface: .array)
        guard case .accepted = await supervisor.accept(.providerCommand(command), for: id),
              let notice = notices.first(where: { $0.screenshot == nil }), !notice.body.isEmpty else {
            throw Failure(description: "the real /status command did not create its notice")
        }
        await supervisor.qaSaveTranscript(for: id)
        let provider = "PROVIDER_AFTER_STATUS_HISTORY"
        let restored = RehydratedTranscript(steps: [.userPrompt(provider)], restoredMessageCount: 1, omittedEarlier: false)
        // These are the same supervisor and tile calls made by the provider
        // read completion, with all stores isolated for the witness.
        supervisor.seedRehydratedTranscript(restored, for: id)
        first.renderRehydratedPreviousSession(restored)
        supervisor.endProviderHistoryRead(readToken, for: id)
        func containsOnce(_ value: String, in text: String) -> Bool {
            text.components(separatedBy: value).count - 1 == 1
        }
        let firstText = first.qaTranscriptText
        guard containsOnce(provider, in: firstText), containsOnce(notice.body, in: firstText) else {
            throw Failure(description: "initial tile lost or duplicated provider history or the /status notice")
        }
        first.detach()
        let reopened = tile()
        defer { reopened.detach() }
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            let text = reopened.qaTranscriptText
            if containsOnce(provider, in: text), containsOnce(notice.body, in: text) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let secondText = reopened.qaTranscriptText
        guard containsOnce(provider, in: secondText), containsOnce(notice.body, in: secondText) else {
            throw Failure(description: "reattached tile lost or duplicated provider history or the /status notice")
        }
        let firstOrder = firstText.range(of: provider)!.lowerBound < firstText.range(of: notice.body)!.lowerBound ? "provider,status" : "status,provider"
        let reopenedOrder = secondText.range(of: provider)!.lowerBound < secondText.range(of: notice.body)!.lowerBound ? "provider,status" : "status,provider"
        print("METRIC provider-after-status initial-order=\(firstOrder) reattached-order=\(reopenedOrder)")
        await supervisor.qaSaveTranscript(for: id)
        guard let disk = try await transcripts.load(agentID: id, sessionID: session),
              !disk.entries.map({ AgentTranscriptCopyController.plainText(for: $0.blocks) }).joined(separator: "\n").contains(provider) else {
            throw Failure(description: "provider-only history crossed into the canonical archive")
        }
    }
}
