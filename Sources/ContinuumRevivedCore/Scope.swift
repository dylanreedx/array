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

    public static let observer: Scope = [.orchestrationRead]
    public static let `operator`: Scope = [.orchestrationRead, .orchestrationOperate, .terminalOperate]
    public static let admin: Scope = [.operator, .accessRead, .accessWrite]

    public func isSubset(of ceiling: Scope) -> Bool {
        ceiling.intersection(self) == self
    }
}
