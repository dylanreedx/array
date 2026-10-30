import Foundation
import ContinuumRevivedCollaborationProtocol

extension CollaborationAPI {
    public func reportUsage(area: UUID, report: Collaboration.UsageReport) async throws {
        let _: Collaboration.ErrorBody = try await request("POST", "areas/\(area)/usage", body: report)
    }
}
