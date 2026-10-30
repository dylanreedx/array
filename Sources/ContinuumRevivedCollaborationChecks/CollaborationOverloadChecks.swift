import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService

private struct OverloadCheckFailure: Error { let message: String }
private func overloadExpect(_ value: Bool, _ label: String) throws {
    guard value else { throw OverloadCheckFailure(message: label) }
    print("PASS overload HTTP: \(label)")
}
@MainActor
private func overloadEventually(_ label: String, _ check: () async throws -> Bool) async throws {
    for _ in 0..<250 {
        if try await check() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw OverloadCheckFailure(message: "timeout \(label)")
}

/// Records the requested delay without waiting for wall-clock backoff. Each
/// retry remains paused until the witness explicitly releases it. Cancellation
/// wakes the pause as a real Task.sleep would, so close cannot strand a session.
private actor OverloadRetryGate {
    private var pauses: [(UUID, CheckedContinuation<Void, Never>)] = []
    private var cancelled: Set<UUID> = []
    private(set) var delays: [Int] = []
    func wait(_ milliseconds: Int) async throws {
        try Task.checkCancellation()
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                delays.append(milliseconds)
                if cancelled.remove(id) != nil || Task.isCancelled { continuation.resume() }
                else { pauses.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
        try Task.checkCancellation()
    }
    private func cancel(_ id: UUID) {
        if let index = pauses.firstIndex(where: { $0.0 == id }) { pauses.remove(at: index).1.resume() }
        else { cancelled.insert(id) }
    }
    func release() { if !pauses.isEmpty { pauses.removeFirst().1.resume() } }
    func releaseAll() { let old = pauses; pauses = []; for item in old { item.1.resume() } }
}

/// Actual NIO subscription saturation, production client/session/controller and
/// channel-scoped cache. No changed service behavior or fake HTTP response is
/// injected: current membership remains valid while held reads exhaust capacity.
@MainActor
func runCollaborationOverloadChecks(api: CollaborationAPI, store: CollaborationStore,
    credentials: CollaborationCredentialStore, endpoint: CollaborationServiceEndpoint,
    credential: Collaboration.Credential, root: URL) async throws {
    let initial = try await api.createArea(), area = initial.document.id
    let object = SharedArea.Item(id: .init(), kind: .discussion)
    _ = try await api.apply(area: area.rawValue, mutation: .init(epoch: 1, command: .init(area: area,
        expectedRevision: 0, edits: [.admit(object, .init(id: .init(), object: object.id,
            rect: .init(x: 0, y: 0, width: 300, height: 200)))])))
    let state = try await api.state(area: area.rawValue)
    let page = try await api.updates(area: area.rawValue, request: .init(after: 1, waitMilliseconds: 0))
    let local = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: AppChannel.devBundleIdentifier,
        endpoint: endpoint, person: credential.identity.person, area: area)
    let draft = SharedAreaLocalDraft(object: object.id, text: "Keep this private draft through subscription overload.")
    let camera = SharedAreaLocalView(x: 88, y: -120, zoom: 1.5, focusedObject: object.id)
    _ = try local.save(.init(scope: local.scope, document: state.document, observedMembershipEpoch: 1,
        view: camera, drafts: [draft]))
    let controller = try SharedAreaController(localStore: local, credentialStore: credentials,
        credentialScope: .init(endpoint: endpoint, identity: credential.identity), bundleIdentifier: AppChannel.devBundleIdentifier)
    let retry = OverloadRetryGate()
    let session = try CollaborationSession(api: api, area: area.rawValue, initial: state, sleep: { try await retry.wait($0) })
    var held: [Task<Collaboration.Updates, any Error>] = []
    var observer: Task<Void, Never>?
    @MainActor func cleanup() async {
        await retry.releaseAll()
        await session.stop()
        _ = await observer?.value
        await controller.close()
        for task in held { task.cancel() }
        for task in held { _ = try? await task.value }
        held = []
    }
    do {
        // The service's bounded per-device/area budget is four: native scene,
        // source host, capture review and one replacing/cancelling view.
        for count in 1...4 {
            held.append(Task { try await api.updates(area: area.rawValue,
                request: .init(after: 1, presenceVersion: page.presenceVersion)) })
            try await overloadEventually("held subscription \(count)") { await store.activeUpdateRequests() == count }
        }
        do {
            _ = try await api.updates(area: area.rawValue, request: .init(after: 1, presenceVersion: page.presenceVersion))
            throw OverloadCheckFailure(message: "subscription capacity did not return 429")
        } catch CollaborationClientError.server(status: 429, code: _) {}
        let fresh = try await api.state(area: area.rawValue)
        try overloadExpect(fresh.document == state.document && overloadSameScope(fresh.scope, state.scope), "actual HTTP overload leaves a fresh current membership and document readable")

        await controller.open()
        try await overloadEventually("controller reconnects after 429") { controller.status == .reconnecting }
        try overloadExpect(controller.document == state.document && controller.scope == nil && !controller.canSubmit
            && controller.view == camera && controller.drafts.contains(draft) && (try local.load()?.accessDenied == false),
            "429 retains the cached canvas, camera and private draft without persisting access denial or enabling writes")
        await controller.close()

        let stream = await session.start()
        observer = Task { for await _ in stream {} }
        let expectedDelays = [250, 500, 1_000, 2_000, 4_000, 8_000, 10_000, 10_000]
        for expectedCount in 1...expectedDelays.count {
            try await overloadEventually("429 backoff \(expectedCount)") { await retry.delays.count == expectedCount }
            guard case let .reconnecting(replica) = await session.status else { throw OverloadCheckFailure(message: "429 became terminal access denial") }
            try overloadExpect(replica?.document == state.document && replica.map { overloadSameScope($0.scope, state.scope) } == true,
                "retry \(expectedCount) retains the original validated replica and cursor")
            if expectedCount < expectedDelays.count { await retry.release() }
        }
        try overloadExpect(await retry.delays == expectedDelays, "successive 429 responses increase reconnect backoff and stop at the 10000ms cap")
        for task in held { task.cancel() }
        for task in held { _ = try? await task.value }
        held = []
        try await overloadEventually("capacity released") { await store.activeUpdateRequests() == 0 }
        await retry.release()
        try await overloadEventually("same session recovered") {
            if case let .connected(replica) = await session.status { return replica.document == state.document }
            return false
        }
        try overloadExpect(await retry.delays == expectedDelays, "releasing capacity recovers the same session without another retry delay")
        await session.stop(); _ = await observer?.value; observer = nil
        try await overloadEventually("session held read closed") { await store.activeUpdateRequests() == 0 }

        await controller.open()
        try await overloadEventually("controller admission restored") { controller.status == .connected && controller.canSubmit }
        let command = SharedArea.Command(area: area, expectedRevision: 1,
            edits: [.post(.init(id: .init(), object: object.id, author: credential.identity.person,
                text: "Deliberate edit after subscription capacity recovered."))])
        guard case .accepted = await controller.submit(command) else { throw OverloadCheckFailure(message: "recovered controller could not submit a deliberate edit") }
        try overloadExpect(controller.document?.revision == 2 && controller.drafts.contains(draft) && controller.view == camera
            && (try local.load()?.accessDenied == false), "after capacity returns, online admission and a new accepted edit recover without losing private state")
        await cleanup()
    } catch { await cleanup(); throw error }
}

private func overloadSameScope(_ left: Collaboration.Scope, _ right: Collaboration.Scope) -> Bool {
    left.area == right.area && left.epoch == right.epoch && left.role == right.role
}
