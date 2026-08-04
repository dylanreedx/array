import Foundation

public enum ManagedSessionStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case starting
    case running
    case stopped
    /// System-cancel (P3.1): the host ended this session without being asked —
    /// a restart or a quit landed on work in flight. Deliberately NOT `.stopped`:
    /// a later reader must be able to tell "the app killed this" from "I killed
    /// this", so the two stay distinct words on disk.
    case cancelled
    case error

    /// True when the recorded status can only describe the PAST. Only a
    /// non-terminal status claims liveness, and a file on disk is never allowed
    /// to make that claim across a launch — the launch sweep
    /// (`ManagedSessionReconciliation`) terminalizes every one of these before a
    /// surface can read it.
    public var isTerminal: Bool {
        switch self {
        case .starting, .running: return false
        case .stopped, .cancelled, .error: return true
        }
    }
}

/// Why a session ended. A closed vocabulary, not a free-form string: the reason
/// is host-side evidence a surface may present, and free text living next to a
/// transcript is exactly how prompt-derived content leaks across the sync
/// boundary. These four words carry no user content by construction (I5).
public enum ManagedSessionEndReason: String, Codable, Equatable, Sendable, CaseIterable {
    case continuumRestarted
    case continuumQuit
    case userStopped
    case runtimeError

    /// The one presenter for this fact. Host-side only — this text never crosses
    /// phone sync; only the case itself is ever persisted.
    public var displayText: String {
        switch self {
        case .continuumRestarted:
            return "Cancelled because Continuum restarted before this work finished."
        case .continuumQuit:
            return "Cancelled because Continuum quit before this work finished."
        case .userStopped:
            return "Stopped because you ended it."
        case .runtimeError:
            return "Ended because the agent runtime failed."
        }
    }
}

public struct ManagedAgentSessionRecord: Codable, Equatable, Sendable {
    /// 2 (P3.1): a v1 file has no `endedReason` and may carry a non-terminal
    /// `status` that no writer would ever transition. The sweep rebuilds every
    /// such record through `init`, which stamps this version — that stamp IS the
    /// migration marker, and it is why `schemaVersion` stays a `let`. Reading a
    /// v1 file still works unchanged: `endedReason` is optional, so the
    /// synthesized decoder uses `decodeIfPresent` for it.
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let tileId: UUID
    public var agentKind: AgentKind
    public var status: ManagedSessionStatus
    /// Set only alongside a terminal `status`, and only by whoever ended the
    /// session. Nil on a v1 file and on a record still claiming liveness.
    public var endedReason: ManagedSessionEndReason?
    public var lastSeenAt: Date
    public var resumeCursor: Data?
    public var runtimePayload: Data?

    public init(
        schemaVersion: Int = ManagedAgentSessionRecord.currentSchemaVersion,
        tileId: UUID,
        agentKind: AgentKind,
        status: ManagedSessionStatus = .starting,
        endedReason: ManagedSessionEndReason? = nil,
        lastSeenAt: Date,
        resumeCursor: Data? = nil,
        runtimePayload: Data? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.tileId = tileId
        self.agentKind = agentKind
        self.status = status
        self.endedReason = endedReason
        self.lastSeenAt = lastSeenAt
        self.resumeCursor = resumeCursor
        self.runtimePayload = runtimePayload
    }

    public struct RuntimePayloadFields: Codable, Equatable, Sendable {
        public var tmuxWindowTarget: String
        public var cwd: String?

        public init(tmuxWindowTarget: String, cwd: String?) {
            self.tmuxWindowTarget = tmuxWindowTarget
            self.cwd = cwd
        }
    }

    public func tmuxWindowTarget() -> String? {
        guard let runtimePayload,
              let fields = try? JSONCodec.makeDecoder().decode(RuntimePayloadFields.self, from: runtimePayload)
        else { return nil }
        return fields.tmuxWindowTarget
    }

    public static func makeRuntimePayload(windowTarget: String, cwd: String?) throws -> Data {
        try JSONCodec.makeEncoder().encode(RuntimePayloadFields(tmuxWindowTarget: windowTarget, cwd: cwd))
    }
}
