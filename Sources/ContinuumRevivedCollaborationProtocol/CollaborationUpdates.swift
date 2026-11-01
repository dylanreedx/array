import Foundation

extension Collaboration {
    public struct UpdateRequest: Codable, Sendable {
        public let subscriptionID: UUID
        public let after: UInt64
        public let through: UInt64?
        public let presenceVersion: UUID?
        public let waitMilliseconds: Int
        public init(subscriptionID: UUID = UUID(), after: UInt64, through: UInt64? = nil, presenceVersion: UUID? = nil, waitMilliseconds: Int = 25_000) {
            self.subscriptionID = subscriptionID; self.after = after; self.through = through; self.presenceVersion = presenceVersion; self.waitMilliseconds = waitMilliseconds
        }
    }
    public struct Event: Codable, Sendable {
        public let revision: UInt64
        public let actor: Identity
        public let command: SharedArea.Command
        public init(revision: UInt64, actor: Identity, command: SharedArea.Command) {
            self.revision = revision; self.actor = actor; self.command = command
        }
    }
    public struct Point: Codable, Sendable, Equatable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
        public var valid: Bool { x.isFinite && y.isFinite }
    }
    public struct PresenceInput: Codable, Sendable {
        public let session: UUID
        public let sequence: UInt64
        public let cursor: Point?
        public let viewport: SharedArea.Rect?
        /// When the sender sampled this position, in seconds on its own
        /// monotonic clock. Opaque to the relay; receivers use only the spacing
        /// between one sender's samples, to play them back at the pace they
        /// were made. Absent from older senders.
        public let sentAt: Double?
        public init(session: UUID, sequence: UInt64, cursor: Point?, viewport: SharedArea.Rect? = nil, sentAt: Double? = nil) {
            self.session = session; self.sequence = sequence; self.cursor = cursor; self.viewport = viewport; self.sentAt = sentAt
        }
    }
    /// One position on the cursor lane, relayed as it arrives (no 20 Hz
    /// coalescing). `session`/`sequence` order it against update pages.
    public struct CursorFrame: Codable, Sendable, Equatable {
        public let identity: Identity
        public let session: UUID
        public let sequence: UInt64
        public let cursor: Point?
        public let viewport: SharedArea.Rect?
        public let sentAt: Double?
        public init(identity: Identity, session: UUID, sequence: UInt64, cursor: Point?, viewport: SharedArea.Rect?, sentAt: Double?) {
            self.identity = identity; self.session = session; self.sequence = sequence
            self.cursor = cursor; self.viewport = viewport; self.sentAt = sentAt
        }
    }
    /// What the relay sends down the cursor lane: a teammate's frame, or a
    /// refusal of one of this device's own frames (its presence session is
    /// unknown, e.g. after a relay restart) so the sender begins a new one.
    public struct CursorLaneMessage: Codable, Sendable, Equatable {
        public let frame: CursorFrame?
        public let rejectedSession: UUID?
        public init(frame: CursorFrame? = nil, rejectedSession: UUID? = nil) { self.frame = frame; self.rejectedSession = rejectedSession }
    }
    public struct PresenceSession: Codable, Sendable {
        public let id: UUID
        public init(id: UUID) { self.id = id }
    }
    public struct Presence: Codable, Sendable {
        public let identity: Identity
        public let cursor: Point?
        public let viewport: SharedArea.Rect?
        public let expiresAt: Date
        public let label: String?
        public let usage: UsageSnapshot?
        /// The presence session and sequence this cursor came from, so a page
        /// never replaces a newer position already delivered on the cursor
        /// lane. Absent from a relay that predates the lane.
        public let session: UUID?
        public let sequence: UInt64?
        public init(identity: Identity, cursor: Point?, viewport: SharedArea.Rect?, expiresAt: Date, label: String? = nil, usage: UsageSnapshot? = nil,
                    session: UUID? = nil, sequence: UInt64? = nil) {
            self.identity = identity; self.cursor = cursor; self.viewport = viewport; self.expiresAt = expiresAt
            self.label = label; self.usage = usage; self.session = session; self.sequence = sequence
        }
    }
    /// A member of an area as the relay records them: the name they chose when
    /// they joined. It outlives their presence, so a teammate whose Mac is
    /// offline is still named.
    public struct Member: Codable, Sendable, Equatable {
        public let person: SharedArea.ID<SharedArea.Person>
        public let label: String
        public init(person: SharedArea.ID<SharedArea.Person>, label: String) { self.person = person; self.label = label }
    }
    public struct Updates: Codable, Sendable {
        public let scope: Scope
        public let after: UInt64
        public let through: UInt64
        public let events: [Event]
        public let nextCursor: UInt64
        public var hasMore: Bool { nextCursor < through }
        public let presenceVersion: UUID
        public let presence: [Presence]
        public let serverTime: Date
        /// Execution-host liveness, versioned with presence but expiring on its own
        /// policy. Absent from a relay that predates host liveness.
        public let hosts: [HostLiveness]?
        /// Latest revision of each admitted artifact. Bytes never ride here;
        /// a changed head tells a view to refetch that artifact's state.
        public let artifactHeads: [Artifact.Head]?
        /// Everyone admitted to the area, by their recorded name, including people
        /// who have since left (their posts still need a name). Absent from a relay
        /// that predates it.
        public let members: [Member]?
        public init(scope: Scope, after: UInt64, through: UInt64, events: [Event], nextCursor: UInt64,
                    presenceVersion: UUID, presence: [Presence], serverTime: Date, hosts: [HostLiveness]? = nil,
                    artifactHeads: [Artifact.Head]? = nil, members: [Member]? = nil) {
            self.scope = scope; self.after = after; self.through = through; self.events = events; self.nextCursor = nextCursor
            self.presenceVersion = presenceVersion; self.presence = presence; self.serverTime = serverTime; self.hosts = hosts
            self.artifactHeads = artifactHeads; self.members = members
        }
    }
}
