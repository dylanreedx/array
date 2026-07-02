import Foundation

// Ticket: docs/38-tickets/12-injectable-substrates.md
//
// The central seam: the operations the rest of the system needs tmux to perform,
// not the argv strings themselves. `TmuxSession` (TmuxSession.swift) stays a pure
// argv constructor; implementors of this protocol use it to build argv and then
// run it (via `Process` for the real implementation, in memory for the fake).
public protocol TmuxControl: Sendable {
    // Spawn operations — return the captured pane id on success.
    func newSession(name: String, cwd: String, innerCommand: [String]?) async throws -> String  // returns %pane_id
    func newWindow(inSession: String, cwd: String, innerCommand: [String]?) async throws -> String  // returns %pane_id

    // Teardown
    func killWindow(target: String) async throws        // target = %pane_id
    func killSession(name: String) async throws
    func detachSession(name: String) async throws

    // Query
    func sessionExists(name: String) async throws -> Bool
    func isAlive(paneTarget: String) async throws -> Bool
    func paneCurrentPath(paneTarget: String) async throws -> String
    func paneCurrentCommand(paneTarget: String) async throws -> String
    func listSessions() async throws -> [TmuxSessionInfo]
}

public struct TmuxSessionInfo: Equatable, Sendable {
    public let name: String
    public let windowCount: Int
    public let paneTargets: [String]

    public init(name: String, windowCount: Int, paneTargets: [String]) {
        self.name = name
        self.windowCount = windowCount
        self.paneTargets = paneTargets
    }
}

/// Errors the in-memory fake raises for operations that have no sensible
/// in-memory analogue (e.g. creating a window in a session that was never
/// created). Kept distinct from `TmuxProcessError` (the real implementation's
/// error type) since the two model different failure shapes.
public enum InMemoryTmuxControlError: Error, Equatable {
    case sessionNotFound(String)
    case paneNotFound(String)
}

public enum TmuxControlError: Error, Equatable {
    case paneNotFound(target: String)
}

/// In-memory fake for `TmuxControl`. No subprocess is spawned; every call is
/// recorded in `log` and resolved against `sessions`/`livePanes` synchronously.
///
/// Fidelity invariant (the make-or-break risk called out by the ticket): a pane
/// id that was alive and is then killed must NOT be removed from `livePanes` —
/// it flips to `isAlive: false` so "never seen this target" and "this target
/// was alive and is now dead" stay distinguishable. Mirroring real tmux, killing
/// a session's last window destroys the session entry itself.
public final class InMemoryTmuxControl: TmuxControl, @unchecked Sendable {
    public var livePanes: [String: PaneStub] = [:]      // %pane_id -> stub
    public var sessions: [String: [String]] = [:]        // session name -> [%pane_id]

    public private(set) var log: [TmuxCall] = []

    public enum TmuxCall: Equatable {
        case newSession(name: String, cwd: String)
        case newWindow(session: String, cwd: String)
        case killWindow(target: String)
        case killSession(name: String)
        case detachSession(name: String)
        case sessionExists(name: String)
        case isAlive(target: String)
        case paneCurrentPath(target: String)
        case paneCurrentCommand(target: String)
        case listSessions
    }

    public struct PaneStub: Equatable, Sendable {
        public var cwd: String
        public var currentCommand: String
        public var isAlive: Bool

        public init(cwd: String, currentCommand: String, isAlive: Bool) {
            self.cwd = cwd
            self.currentCommand = currentCommand
            self.isAlive = isAlive
        }
    }

    private var nextPaneIndex = 1
    private func nextPaneId() -> String {
        let id = "%\(nextPaneIndex)"
        nextPaneIndex += 1
        return id
    }

    public init() {}

    public func newSession(name: String, cwd: String, innerCommand: [String]?) async throws -> String {
        log.append(.newSession(name: name, cwd: cwd))
        let paneId = nextPaneId()
        sessions[name] = [paneId]
        livePanes[paneId] = PaneStub(cwd: cwd, currentCommand: innerCommand?.first ?? "zsh", isAlive: true)
        return paneId
    }

    public func newWindow(inSession: String, cwd: String, innerCommand: [String]?) async throws -> String {
        log.append(.newWindow(session: inSession, cwd: cwd))
        guard sessions[inSession] != nil else {
            throw InMemoryTmuxControlError.sessionNotFound(inSession)
        }
        let paneId = nextPaneId()
        sessions[inSession, default: []].append(paneId)
        livePanes[paneId] = PaneStub(cwd: cwd, currentCommand: innerCommand?.first ?? "zsh", isAlive: true)
        return paneId
    }

    public func killWindow(target: String) async throws {
        log.append(.killWindow(target: target))
        guard var stub = livePanes[target] else { return }
        stub.isAlive = false
        livePanes[target] = stub
        for (name, panes) in sessions {
            guard panes.contains(target) else { continue }
            let remaining = panes.filter { $0 != target }
            if remaining.isEmpty {
                // Real tmux destroys a session when its last window is killed.
                sessions.removeValue(forKey: name)
            } else {
                sessions[name] = remaining
            }
            break
        }
    }

    public func killSession(name: String) async throws {
        log.append(.killSession(name: name))
        guard let panes = sessions.removeValue(forKey: name) else { return }
        for paneId in panes {
            guard var stub = livePanes[paneId] else { continue }
            stub.isAlive = false
            livePanes[paneId] = stub
        }
    }

    public func detachSession(name: String) async throws {
        log.append(.detachSession(name: name))
    }

    public func sessionExists(name: String) async throws -> Bool {
        log.append(.sessionExists(name: name))
        return sessions[name] != nil
    }

    public func isAlive(paneTarget: String) async throws -> Bool {
        log.append(.isAlive(target: paneTarget))
        return livePanes[paneTarget]?.isAlive ?? false
    }

    public func paneCurrentPath(paneTarget: String) async throws -> String {
        log.append(.paneCurrentPath(target: paneTarget))
        guard let stub = livePanes[paneTarget] else {
            throw InMemoryTmuxControlError.paneNotFound(paneTarget)
        }
        return stub.cwd
    }

    public func paneCurrentCommand(paneTarget: String) async throws -> String {
        log.append(.paneCurrentCommand(target: paneTarget))
        guard let stub = livePanes[paneTarget], stub.isAlive else {
            throw TmuxControlError.paneNotFound(target: paneTarget)
        }
        return stub.currentCommand
    }

    public func listSessions() async throws -> [TmuxSessionInfo] {
        log.append(.listSessions)
        return sessions.map { name, panes in
            TmuxSessionInfo(name: name, windowCount: panes.count, paneTargets: panes)
        }
    }
}
