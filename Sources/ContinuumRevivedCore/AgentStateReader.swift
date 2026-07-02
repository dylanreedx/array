import Foundation

public struct AgentSnapshot: Codable, Equatable, Sendable {
    public struct Evidence: Codable, Equatable, Sendable {
        public var source: String
        public var lastEventType: String?
        public var mtimeAgeSeconds: Double

        public init(source: String, lastEventType: String?, mtimeAgeSeconds: Double) {
            self.source = source
            self.lastEventType = lastEventType
            self.mtimeAgeSeconds = mtimeAgeSeconds
        }
    }

    public var kind: AgentKind
    public var status: AgentStatus
    public var title: String?
    public var mode: String?
    public var asOf: Date
    public var detail: String?
    public var evidence: Evidence

    public init(
        kind: AgentKind,
        status: AgentStatus,
        title: String?,
        mode: String?,
        asOf: Date,
        detail: String?,
        evidence: Evidence
    ) {
        self.kind = kind
        self.status = status
        self.title = title.map { String($0.prefix(80)) }
        self.mode = mode
        self.asOf = asOf
        self.detail = detail
        self.evidence = evidence
    }
}

public protocol AgentStateReader: Sendable {
    var kind: AgentKind { get }

    /// Returns true when this reader owns the raw pane_current_command value.
    /// Readers may opt into shim commands such as "node", but must under-claim
    /// when locate/read cannot prove the agent-specific store belongs to the pane.
    func detect(processName: String) -> Bool

    /// Returns the authoritative store URL for this agent, or nil when no store
    /// can be linked. Implementations may probe paths but should not read content.
    func locate(pid: pid_t?, cwd: String, runId: String?) -> URL?

    /// Reads metadata only from the located store. `asOf` is supplied by the
    /// observer and must be echoed into the returned snapshot unchanged.
    func read(storeURL: URL, asOf: Date) -> AgentSnapshot
}
