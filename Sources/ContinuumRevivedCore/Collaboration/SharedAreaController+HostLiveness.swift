import Foundation
import ContinuumRevivedCollaborationProtocol

/// Read-only liveness lookups for views that gate execution controls. The
/// relay's projection is the only source; nothing here infers liveness from a
/// pointer, a document revision or a cached control state.
extension SharedAreaController {
    /// Nil means the host has never checked in to this area since the relay
    /// started recording it, or the controller is not connected.
    public func hostLiveness(for host: SharedArea.ID<SharedArea.Host>) -> Collaboration.HostLiveness? {
        hostLiveness.first { $0.host == host }
    }
    /// The liveness of the host that executes a published agent observation.
    public func hostLiveness(forObject object: SharedArea.ID<SharedArea.Object>) -> Collaboration.HostLiveness? {
        guard let host = document?.items.first(where: { $0.id == object })?.source?.host else { return nil }
        return hostLiveness(for: host)
    }
    /// True only while the executing host is proving it is alive. Stale,
    /// offline and never-seen hosts are all false.
    public func isHostOnline(forObject object: SharedArea.ID<SharedArea.Object>) -> Bool {
        hostLiveness(forObject: object)?.state == .online
    }
}
