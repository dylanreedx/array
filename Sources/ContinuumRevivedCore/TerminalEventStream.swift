public enum TerminalSurfaceEvent: Equatable, Sendable {
    case childExited(exitCode: Int32)
}

public struct TerminalProcessExitObservation: Equatable, Sendable {
    public private(set) var pendingChildExitCode: Int32?

    public init(pendingChildExitCode: Int32? = nil) {
        self.pendingChildExitCode = pendingChildExitCode
    }

    public mutating func record(_ event: TerminalSurfaceEvent) {
        switch event {
        case .childExited(let exitCode):
            pendingChildExitCode = exitCode
        }
    }

    public mutating func consumeProcessExitCode() -> Int32? {
        let exitCode = pendingChildExitCode
        pendingChildExitCode = nil
        return exitCode
    }
}
