import Foundation

public struct LinearTicketQueueConfig: Codable, Equatable, Sendable {
    public var teamKey: String
    public var teamId: String?
    public var query: String?

    public init(teamKey: String, teamId: String? = nil, query: String? = nil) {
        self.teamKey = teamKey
        self.teamId = teamId
        self.query = query
    }
}

public struct LinearTicketQueueRow: Equatable, Sendable {
    public var identifier: String
    public var title: String
    public var state: String
    public var stateType: String?
    public var priority: LinearTicketPriority
    public var labels: [String]

    public init(identifier: String, title: String, state: String, stateType: String?, priority: LinearTicketPriority, labels: [String]) {
        self.identifier = identifier
        self.title = title
        self.state = state
        self.stateType = stateType
        self.priority = priority
        self.labels = labels
    }
}

public enum LinearTicketPriority: Int, Equatable, Comparable, Sendable {
    case none = 0
    case urgent = 1
    case high = 2
    case medium = 3
    case low = 4

    public static func < (lhs: LinearTicketPriority, rhs: LinearTicketPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .none: return "No priority"
        case .urgent: return "Urgent"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

public enum LinearTicketQueueMapper {
    public static func rows(from data: Data) throws -> [LinearTicketQueueRow] {
        let envelope = try JSONDecoder().decode(LinearIssuesEnvelope.self, from: data)
        return envelope.issues.nodes.map { issue in
            LinearTicketQueueRow(
                identifier: issue.identifier,
                title: issue.title,
                state: issue.state.name,
                stateType: issue.state.type,
                priority: LinearTicketPriority(rawValue: issue.priority) ?? .none,
                labels: issue.labels?.nodes.map(\.name).sorted() ?? []
            )
        }.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.identifier.localizedStandardCompare(rhs.identifier) == .orderedAscending
        }
    }
}

private struct LinearIssuesEnvelope: Decodable {
    var issues: LinearIssuesConnection
}

private struct LinearIssuesConnection: Decodable {
    var nodes: [LinearIssue]
}

private struct LinearIssue: Decodable {
    var identifier: String
    var title: String
    var priority: Int
    var state: LinearIssueState
    var labels: LinearLabelConnection?
}

private struct LinearIssueState: Decodable {
    var name: String
    var type: String?
}

private struct LinearLabelConnection: Decodable {
    var nodes: [LinearLabel]
}

private struct LinearLabel: Decodable {
    var name: String
}
