import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// One projector per published local agent, owned by the host session and
/// therefore independent of any window, tile or recipient view. Mounting,
/// closing or remounting a view never reaches this type.
@MainActor
final class SharedAreaAgentProjectionHost {
    private let supervisor: AgentSupervisor
    private let directory: URL
    private let makeSink: (SharedArea.ID<SharedArea.Object>) -> SharedAgentProjectionSink
    private let owner: SharedArea.ID<SharedArea.Person>?
    private(set) var projectors: [SharedArea.ID<SharedArea.Object>: SharedAgentProjector] = [:]
    private var scheduled: Task<Void, Never>?
    private(set) var lastError: (any Error)?

    init(supervisor: AgentSupervisor, directory: URL, owner: SharedArea.ID<SharedArea.Person>? = nil,
         makeSink: @escaping (SharedArea.ID<SharedArea.Object>) -> SharedAgentProjectionSink) {
        self.supervisor = supervisor; self.directory = directory; self.owner = owner; self.makeSink = makeSink
    }

    convenience init(supervisor: AgentSupervisor, controller: SharedAreaController) {
        self.init(supervisor: supervisor, directory: controller.storageDirectory, owner: controller.identity.person) { [weak controller] object in
            SharedAreaControllerProjectionSink(controller: controller, object: object)
        }
    }

    /// `bindings` are the owner's current published, locally bound agents.
    func sync(_ bindings: [SharedAreaLocalSourceBinding]) {
        var wanted: [SharedArea.ID<SharedArea.Object>: (AgentID, SharedArea.ID<SharedArea.Host>)] = [:]
        for binding in bindings {
            guard let id = binding.agentID, let record = supervisor.records[id], record.projectId == binding.projectID else { continue }
            wanted[binding.object] = (id, binding.host)
        }
        for (object, projector) in projectors where wanted[object].map({ $0.0 != projector.agent || $0.1 != projector.host }) ?? true
            || projector.superseded {
            projector.stop(); projectors[object] = nil
        }
        for (object, target) in wanted where projectors[object] == nil {
            do {
                let generation = try SharedAgentProjectionGenerations.next(directory: directory, object: object)
                let projector = try SharedAgentProjector(supervisor: supervisor, agent: target.0, host: target.1, object: object,
                                                         generation: generation, owner: owner, sink: makeSink(object))
                projector.onPending = { [weak self] in self?.scheduleFlush() }
                projectors[object] = projector
                scheduleFlush()
            } catch { lastError = error }
        }
    }

    func flush() async {
        for projector in projectors.values { await projector.flush() }
    }

    func stop() {
        scheduled?.cancel(); scheduled = nil
        for projector in projectors.values { projector.stop() }
        projectors = [:]
    }

    /// Coalesces a burst of streamed frames into one delivery per main-actor turn.
    private func scheduleFlush() {
        guard scheduled == nil else { return }
        scheduled = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            await self.flush()
            self.scheduled = nil
        }
    }
}

/// Delivers through the area controller's authenticated transport and turns
/// the service's two meaningful refusals into the projector's.
@MainActor
final class SharedAreaControllerProjectionSink: SharedAgentProjectionSink {
    private weak var controller: SharedAreaController?
    private let object: SharedArea.ID<SharedArea.Object>
    init(controller: SharedAreaController?, object: SharedArea.ID<SharedArea.Object>) {
        self.controller = controller; self.object = object
    }
    func publish(_ batch: Collaboration.AgentProjection.Batch) async throws {
        guard let controller else { throw CollaborationClientError.server(status: 503, code: "notConnected") }
        do { try await controller.publishAgentProjection(object: object, batch: batch) }
        catch CollaborationClientError.server(409, "resyncRequired") { throw SharedAgentProjectionRefusal.resnapshotRequired }
        catch CollaborationClientError.server(409, "revisionConflict") { throw SharedAgentProjectionRefusal.superseded }
    }
}
