import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Account/area source work survives view closure. Host dispatch and accounting
/// share no lifetime with cursor rendering or recipient canvas hydration.
@MainActor
final class SharedAreaHostSession {
    let controller: SharedAreaController
    let handoff: SharedAreaHandoffCoordinator
    /// Nil only for a fixture transport that cannot speak for a host.
    let heartbeat: SharedAreaHostHeartbeat?
    private let supervisor: AgentSupervisor
    private var collector: SharedAreaUsageCollector?
    private var host: SharedArea.ID<SharedArea.Host>?
    private var changeObserver: UUID?
    private var pump: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var generation = UUID()
    private var lastReported: UInt64?
    private(set) var lastUsage: Collaboration.UsageSnapshot?
    private(set) var lastError: (any Error)?

    convenience init(account: CollaborationAccountController, area: UUID, supervisor: AgentSupervisor) throws {
        let controller = try account.makeSharedAreaController(area: area)
        try self.init(controller: controller, handoffModel: account.makeAgentHandoffController(area: area), supervisor: supervisor)
    }
    init(controller: SharedAreaController, handoffModel: SharedAgentHandoffController, supervisor: AgentSupervisor) throws {
        self.supervisor = supervisor
        self.controller = controller
        heartbeat = (handoffModel.transport as? any SharedAreaHostHeartbeatTransport).map { SharedAreaHostHeartbeat(transport: $0) }
        handoff = try SharedAreaHandoffCoordinator(model: handoffModel,
            supervisor: supervisor, bindings: { [weak controller] in
                guard let controller else { return [] }
                guard let document = controller.document else { return controller.sourceBindings }
                return controller.sourceBindings.filter { binding in
                    document.items.contains { $0.id == binding.object && $0.source?.host == binding.host && $0.source?.owner == controller.identity.person }
                }
            })
    }
    func start() {
        guard pump == nil else { return }
        generation = UUID(); let ticket = generation
        let precedingClose = closing
        changeObserver = controller.addChangeObserver { [weak self] in self?.ensureCollector() }
        handoff.startHosting()
        pump = Task { [weak self] in
            guard let self else { return }
            await precedingClose?.value
            guard ticket == generation, !Task.isCancelled else { return }
            await controller.open()
            while ticket == generation, !Task.isCancelled {
                await updateUsage()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func stop() {
        generation = UUID()
        pump?.cancel(); pump = nil; collector?.stop(); handoff.stopHosting(); heartbeat?.end()
        collector = nil; host = nil; lastReported = nil; lastUsage = nil
        if let changeObserver { controller.removeChangeObserver(changeObserver) }; changeObserver = nil
        let precedingClose = closing
        closing = Task { [controller] in await precedingClose?.value; await controller.close() }
    }
    func updateUsage() async {
        let ticket = generation
        ensureCollector()
        guard controller.status == .connected, let document = controller.document else { return }
        let bindings = controller.sourceBindings.filter { binding in
            document.items.contains { $0.id == binding.object && $0.source?.host == binding.host && $0.source?.owner == controller.identity.person }
        }
        guard let host = bindings.first?.host else { return }
        do {
            guard let collector else { return }
            let snapshot = try await collector.snapshot()
            guard ticket == generation, self.collector === collector, self.host == host,
                  snapshot.host == host, controller.status == .connected else { return }
            lastUsage = snapshot
            guard snapshot.sequence != lastReported else { return }
            try await controller.reportUsage(snapshot)
            guard ticket == generation, self.collector === collector, self.host == host else { return }
            lastReported = snapshot.sequence; lastError = nil
        } catch { if ticket == generation { lastError = error } }
    }
    private func ensureCollector() {
        guard let document = controller.document else { return }
        let bindings = controller.sourceBindings.filter { binding in
            document.items.contains { $0.id == binding.object && $0.source?.host == binding.host && $0.source?.owner == controller.identity.person }
        }
        heartbeat?.track(host: bindings.first?.host)
        guard let host = bindings.first?.host else {
            collector?.stop(); collector = nil; self.host = nil; lastReported = nil; lastUsage = nil; return
        }
        guard collector == nil || self.host != host else { return }
        do {
            let identity = controller.identity
            collector?.stop(); collector = nil; self.host = nil; lastReported = nil; lastUsage = nil
            collector = try SharedAreaUsageCollector(supervisor: supervisor, bindings: { [weak controller] in
                guard let controller, let document = controller.document else { return [] }
                return controller.sourceBindings.filter { binding in
                    binding.host == host && document.items.contains { $0.id == binding.object && $0.source?.owner == identity.person }
                }
            }, directory: controller.storageDirectory, host: host)
            self.host = host
        } catch { lastError = error }
    }
}
