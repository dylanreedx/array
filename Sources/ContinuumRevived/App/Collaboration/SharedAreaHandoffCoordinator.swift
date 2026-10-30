import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

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
    /// Relay liveness of the host executing a shared agent, for the dialog's
    /// send-now warning. Supplied by the owning host session.
    var hostLiveness: (@MainActor (SharedArea.ID<SharedArea.Object>) -> Collaboration.HostLiveness?)?

    init(model: SharedAgentHandoffController, supervisor: AgentSupervisor,
         bindings: @escaping @MainActor () -> [SharedAreaLocalSourceBinding]) throws {
        self.model = model; self.supervisor = supervisor; self.bindings = bindings
        let lifetime = Lifetime()
        self.lifetime = lifetime
        let journal = try SharedAgentHostJournal(directory: model.areaDirectory.appendingPathComponent("host-dispatch", isDirectory: true))
        self.journal = journal
        dispatcher = SharedAgentHostDispatcher(identity: model.identity, transport: model.transport, journal: journal,
            execute: { [weak supervisor] binding, command in
                guard lifetime.active, lifetime.dispatchGeneration == lifetime.generation, !Task.isCancelled,
                      let supervisor, let agentID = binding.agentID,
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
                await pollOnce()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    func pollOnce() async {
        let ticket = lifetime.generation
        guard lifetime.admits(ticket), !isPolling else { return }
        isPolling = true
        defer { isPolling = false }
        let snapshot: Collaboration.State
        do { snapshot = try await model.transport.state() }
        catch { return } // Existing gates remain fail-closed through disconnect.
        guard lifetime.admits(ticket) else { return }
        let owned = bindings().filter { binding in
            guard let supervisor, let agentID = binding.agentID, let record = supervisor.records[agentID] else { return false }
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
                        let local = try await transport.control(object: binding.object.rawValue)
                        return lifetime.admits(ticket) && local.epoch == current.scope.epoch && local.source == source
                            && local.source.owner == identity.person && local.controller == identity.person
                    }
                    if command.area == current.document.id && command.object == binding.object {
                        let attempt = try journal.prepare(command)
                        guard attempt.phase == .attempting || (command.mode == .queue && attempt.phase == .accepted) else { return false }
                        let admitted = try await transport.admit(id: command.id,
                            request: .init(claimID: attempt.claimID, hostGeneration: command.hostGeneration))
                        return lifetime.admits(ticket) && (admitted.phase == .dispatching || (command.mode == .queue && admitted.phase == .accepted))
                            && admitted.command == command && admitted.claimID == attempt.claimID
                    }
                    // Another view of this same AgentID may not hand it to a
                    // competing person. Unhanded owner views do not block it.
                    let other = try await transport.control(object: binding.object.rawValue)
                    return lifetime.admits(ticket) && other.epoch == current.scope.epoch && other.source == source
                        && (other.controller == source.owner || other.controller == command.requester.person)
                } catch { return false }
            }, rememberQueued: { item, command in
                try journal.rememberQueued(item: item, command: command)
            }, queuedCommand: { item in
                try journal.queuedCommand(item: item)
            })
            supervisor?.installSharedAgentControlGate(for: agentID, scope: scope, gate: gate)
        }
        guard lifetime.admits(ticket) else { return }
        lifetime.dispatchGeneration = ticket
        defer { if lifetime.dispatchGeneration == ticket { lifetime.dispatchGeneration = nil } }
        await dispatcher.pollOnce(bindings: owned)
        guard lifetime.admits(ticket) else { return }
        supervisor?.releaseHeldPrompts()
        if let dialog, !model.isBusy {
            await model.refresh(object: dialog.object)
            guard lifetime.admits(ticket) else { return }
        }
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
