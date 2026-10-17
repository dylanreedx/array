import Foundation

/// Owns every agent: its record, its runner and its event stream.
@MainActor
final class AgentSupervisor {
    private(set) var records: [AgentID: AgentRecord] = [:]

    func send(_ prompt: String, to id: AgentID) -> Bool {
        guard let record = records[id], record.isReady else { return false }
        return runner(for: record).start(prompt: prompt)
    }
}
