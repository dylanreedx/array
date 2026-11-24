import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// How often a host asks the relay for work. The relay cannot wake a host, so
/// the host polls (its command route has no held read); a quiet host stretches
/// the gap to 1.5 s at most, which is the longest a guest's prompt can wait,
/// and any activity snaps it back to 1 s. The area snapshot is re-read on every
/// busy poll and every tenth quiet one.
struct SharedAgentHostPollPacing {
    private(set) var quietPolls = 0
    static let slowest: Duration = .milliseconds(1500)
    var interval: Duration { quietPolls < 15 ? .seconds(1) : Self.slowest }
    var refreshesState: Bool { quietPolls % 10 == 0 }
    mutating func settled(busy: Bool) { quietPolls = busy ? 0 : quietPolls + 1 }
}

/// One area/account host pump. The app retains this independently of a canvas
/// view. Closing a handoff dialog or area view never stops a provider process.
@MainActor
final class SharedAreaHandoffCoordinator {
    private final class Lifetime {
        var active = true
        var generation = UUID()
        var dispatchGeneration: UUID?
        func admits(_ ticket: UUID) -> Bool { active && generation == ticket && !Task.isCancelled }
    }
    let model: SharedAgentHandoffController
    let dispatcher: SharedAgentHostDispatcher
    private let journal: SharedAgentHostJournal
    private weak var supervisor: AgentSupervisor?
    private let bindings: @MainActor () -> [SharedAreaLocalSourceBinding]
    private var hostTask: Task<Void, Never>?
    private var dialog: SharedAreaHandoffWindowController?
    private var installedScopes: Set<String> = []
    private let lifetime: Lifetime
    private var isPolling = false
    private var pacing = SharedAgentHostPollPacing()
    private var cachedState: Collaboration.State?
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Relay liveness of the host executing a shared agent, for the dialog's
    /// send-now warning. Supplied by the owning host session.
    var hostLiveness: (@MainActor (SharedArea.ID<SharedArea.Object>) -> Collaboration.HostLiveness?)?

    init(model: SharedAgentHandoffController, supervisor: AgentSupervisor,
         bindings: @escaping @MainActor () -> [SharedAreaLocalSourceBinding],
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws {
        self.sleep = sleep
        self.model = model; self.supervisor = supervisor; self.bindings = bindings
        let lifetime = Lifetime()
        self.lifetime = lifetime
        let journal = try SharedAgentHostJournal(directory: model.areaDirectory.appendingPathComponent("host-dispatch", isDirectory: true))
        self.journal = journal
        dispatcher = SharedAgentHostDispatcher(identity: model.identity, transport: model.transport, journal: journal,
            ready: { [weak supervisor] binding in
                guard let supervisor, let agentID = binding.agentID else { return true }
                return supervisor.canStartSharedPromptNow(agentID)
            },
            execute: { [weak supervisor] binding, command in
                guard lifetime.active, lifetime.dispatchGeneration == lifetime.generation, !Task.isCancelled,
                      let supervisor, let agentID = binding.agentID, supervisor.adoptArchivedAgent(agentID),
                      let record = supervisor.records[agentID], record.projectId == binding.projectID else { return .refused(.unknownAgent) }
                return await supervisor.acceptSharedAgentPrompt(command, for: agentID,
                    scope: model.areaDirectory.path + "/" + binding.object.rawValue.uuidString)
            })
    }
    deinit { hostTask?.cancel() }
    func startHosting() {
        guard hostTask == nil else { return }
        lifetime.active = true; lifetime.generation = UUID()
        hostTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let busy = await pollOnce(refreshState: pacing.refreshesState || cachedState == nil)
                pacing.settled(busy: busy)
                do { try await sleep(pacing.interval) } catch { return }
            }
        }
    }
    func pollOnce() async { await pollOnce(refreshState: true) }
    /// Returns whether anything was happening: a waiting command, an error, or
    /// a changed document.
    @discardableResult
    private func pollOnce(refreshState: Bool) async -> Bool {
        let ticket = lifetime.generation
        guard lifetime.admits(ticket), !isPolling else { return true }
        isPolling = true
        defer { isPolling = false }
        let snapshot: Collaboration.State
        var changed = false
        if refreshState || cachedState == nil {
            do { snapshot = try await model.transport.state() }
            catch { cachedState = nil; return true } // Existing gates remain fail-closed through disconnect.
            changed = cachedState.map { $0.document.revision != snapshot.document.revision || $0.scope.epoch != snapshot.scope.epoch } ?? false
            cachedState = snapshot
        } else if let cachedState { snapshot = cachedState } else { return true }
        guard lifetime.admits(ticket) else { return true }
        let owned = bindings().filter { binding in
            guard let supervisor, let agentID = binding.agentID, supervisor.adoptArchivedAgent(agentID),
                  let record = supervisor.records[agentID] else { return false }
            guard record.projectId == binding.projectID,
                  let source = snapshot.document.items.first(where: { $0.id == binding.object && $0.kind == .agentObservation })?.source else { return false }
            return source.owner == model.identity.person && source.host == binding.host && source.binding == binding.binding
        }
        let nextScopes = Set(owned.map { model.areaDirectory.path + "/" + $0.object.rawValue.uuidString })
        for scope in installedScopes.subtracting(nextScopes) { supervisor?.removeSharedAgentControlGates(scope: scope) }
        installedScopes = nextScopes
        let transport = model.transport
        let identity = model.identity
        let journal = self.journal
        let lifetime = self.lifetime
        for binding in owned {
            guard let agentID = binding.agentID else { continue }
            let scope = model.areaDirectory.path + "/" + binding.object.rawValue.uuidString
            let gate = SharedAgentControlGate(validate: { command in
                guard lifetime.admits(ticket) else { return false }
                do {
                    let current = try await transport.state()
                    guard lifetime.admits(ticket),
                          let source = current.document.items.first(where: { $0.id == binding.object })?.source,
                          source.host == binding.host, source.binding == binding.binding else { return false }
                    guard let command else {
                        // The owner can always prompt their own agent. Handing
                        // it over says who is driving; it never locks them out.
                        let local = try await transport.control(object: binding.object.rawValue)
                        return lifetime.admits(ticket) && local.epoch == current.scope.epoch && local.source == source
                            && local.source.owner == identity.person
                    }
                    if command.area == current.document.id && command.object == binding.object {
                        let attempt = try journal.prepare(command)
                        guard attempt.phase == .attempting || (command.mode == .queue && attempt.phase == .accepted) else { return false }
                        let admitted = try await transport.admit(id: command.id,
                            request: .init(claimID: attempt.claimID, hostGeneration: command.hostGeneration))
                        return lifetime.admits(ticket) && (admitted.phase == .dispatching || (command.mode == .queue && admitted.phase == .accepted))
                            && admitted.command == command && admitted.claimID == attempt.claimID
                    }
                    // Another area's view of this same AgentID: its own host
                    // binding must still be current. Control does not gate it.
                    let other = try await transport.control(object: binding.object.rawValue)
                    return lifetime.admits(ticket) && other.epoch == current.scope.epoch && other.source == source
                } catch { return false }
            }, rememberQueued: { item, command in
                try journal.rememberQueued(item: item, command: command)
            }, queuedCommand: { item in
                try journal.queuedCommand(item: item)
            })
            supervisor?.installSharedAgentControlGate(for: agentID, scope: scope, gate: gate)
        }
        guard lifetime.admits(ticket) else { return true }
        lifetime.dispatchGeneration = ticket
        defer { if lifetime.dispatchGeneration == ticket { lifetime.dispatchGeneration = nil } }
        await dispatcher.pollOnce(bindings: owned, state: snapshot)
        if dispatcher.lastError != nil { cachedState = nil }
        let busy = changed || dispatcher.lastPendingCount > 0 || dispatcher.lastError != nil
        guard lifetime.admits(ticket) else { return true }
        supervisor?.releaseHeldPrompts()
        if let dialog, !model.isBusy {
            await model.refresh(object: dialog.object)
            guard lifetime.admits(ticket) else { return true }
        }
        return busy
    }
    func stopHosting() {
        lifetime.active = false; lifetime.generation = UUID(); lifetime.dispatchGeneration = nil
        hostTask?.cancel(); hostTask = nil
        for scope in installedScopes { supervisor?.removeSharedAgentControlGates(scope: scope) }
        installedScopes = []
    }
    func hostLivenessChanged() { dialog?.content.refreshHostLiveness() }
    func show(object: SharedArea.ID<SharedArea.Object>) {
        if let dialog, dialog.object == object { dialog.show(); return }
        if let dialog {
            do { try dialog.content.prepareToClose() }
            catch { dialog.show(); return }
            dialog.window.performClose(nil)
        }
        let window = SharedAreaHandoffWindowController(model: model, object: object)
        if let provider = hostLiveness { window.content.hostLiveness = { provider(object) } }
        dialog = window
        window.onClose = { [weak self, weak window] in
            if self?.dialog === window { self?.dialog = nil }
        }
        window.show()
    }
}
