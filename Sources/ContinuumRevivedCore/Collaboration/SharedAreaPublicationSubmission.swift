import Foundation
import ContinuumRevivedCollaborationProtocol

extension SharedAreaPublication.Confirmed {
    /// A private binding only identifies a source. It cannot create a local
    /// runtime or authorize execution, and it must match the confirmed portable
    /// source exactly before it can be retained for recovery.
    func validateBindings(in candidate: SharedArea.Document, person: SharedArea.ID<SharedArea.Person>) throws {
        guard author == person, candidate.id == command.area,
              Set(sourceBindings.map(\.object)).count == sourceBindings.count else {
            throw SharedAreaLocalStoreError.invalidState
        }
        for binding in sourceBindings {
            // The live document may already have removed this object after an
            // accepted command whose reply was lost. Its immutable admitted
            // source still identifies the exact publication being retried.
            let admittedItem = command.edits.compactMap { edit -> SharedArea.Item? in
                if case .admit(let item, _) = edit, item.id == binding.object { return item }
                return nil
            }.first
            // An agent binding names its local agent; an artifact binding
            // (COL-16) and a live tile's (SHARE-KINDS.md) name only their
            // source tile and never an agent.
            guard binding.host == host, binding.tileID != nil,
                  let item = admittedItem,
                  (item.kind == .agentObservation && binding.agentID != nil)
                    || ((item.kind == .artifact || item.kind == .liveTile) && binding.agentID == nil),
                  item.source == .init(owner: person, host: host, binding: binding.binding) else {
                throw SharedAreaLocalStoreError.invalidState
            }
        }
    }

    /// The cache transaction keeps source identities beside its existing
    /// document/cursor. A subsequent acknowledged snapshot advances that same
    /// atomic state without dropping these references or another view's draft.
    func retainBindings(in state: inout SharedAreaLocalState) throws {
        guard state.scope.person == author, state.scope.area == command.area else {
            throw SharedAreaLocalStoreError.scopeMismatch
        }
        for binding in sourceBindings {
            if let existing = state.sourceBindings.first(where: { $0.object == binding.object }) {
                guard existing == binding else { throw SharedAreaLocalStoreError.invalidState }
            } else {
                state.sourceBindings.append(binding)
            }
        }
    }
}
