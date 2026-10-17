import Foundation

struct AgentSummary: Identifiable, Codable {
    let id: UUID
    let name: String
    let zone: String
    let status: AgentStatus
}
