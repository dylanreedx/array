import Foundation

public struct Scope: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let orchestrationRead = Scope(rawValue: 1 << 0)
    public static let orchestrationOperate = Scope(rawValue: 1 << 1)
    public static let terminalOperate = Scope(rawValue: 1 << 2)
    public static let accessRead = Scope(rawValue: 1 << 3)
    public static let accessWrite = Scope(rawValue: 1 << 4)
    /// Grants decrypted semantic transcript contents. Deliberately separate
    /// from orchestrationRead so existing observers do not gain conversation data.
    public static let transcriptRead = Scope(rawValue: 1 << 5)
    /// Narrow remote stop authority; does not imply send/steer/queue.
    public static let agentStop = Scope(rawValue: 1 << 6)

    public static let observer: Scope = [.orchestrationRead]
    public static let `operator`: Scope = [.orchestrationRead, .orchestrationOperate, .terminalOperate]
    /// The server-fixed friends-alpha profile used by paired phones. It can
    /// inspect companion-safe state, answer approvals, and stop agents, but it
    /// deliberately cannot operate a terminal or administer an instance.
    public static let companionControl: Scope = [.orchestrationRead, .orchestrationOperate, .transcriptRead, .agentStop]
    public static let admin: Scope = [.operator, .accessRead, .accessWrite, .transcriptRead, .agentStop]

    public func isSubset(of ceiling: Scope) -> Bool {
        ceiling.intersection(self) == self
    }

    public func isSuperset(of requested: Scope) -> Bool {
        requested.isSubset(of: self)
    }
}
