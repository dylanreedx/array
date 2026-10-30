import Foundation
import ContinuumRevivedCollaborationProtocol

extension CollaborationAPI {
    public func hostHeartbeat(area: UUID, host: SharedArea.ID<SharedArea.Host>, beat: Collaboration.HostHeartbeat) async throws -> Collaboration.HostLiveness {
        try await request("POST", "areas/\(area)/hosts/\(host.rawValue)/heartbeat", body: beat)
    }
    public func endHost(area: UUID, host: SharedArea.ID<SharedArea.Host>, generation: UUID) async throws {
        let _: Collaboration.ErrorBody = try await request("DELETE", "areas/\(area)/hosts/\(host.rawValue)/runs/\(generation)", body: Optional<Int>.none)
    }
}
