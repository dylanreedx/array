public enum TerminalStatus: Equatable, Sendable {
    case configuring
    case running
    case exited(exitCode: Int32?)
    case error(message: String)
}

public struct TerminalRuntimeState: Equatable, Sendable {
    public private(set) var status: TerminalStatus

    public init(status: TerminalStatus = .configuring) {
        self.status = status
    }

    public mutating func markRunning() {
        status = .running
    }

    public mutating func markExited(exitCode: Int32?) {
        status = .exited(exitCode: exitCode)
    }

    public mutating func markError(_ message: String) {
        status = .error(message: message)
    }
}
