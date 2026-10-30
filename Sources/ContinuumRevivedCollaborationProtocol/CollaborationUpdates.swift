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
        public init(session: UUID, sequence: UInt64, cursor: Point?, viewport: SharedArea.Rect? = nil) {
            self.session = session; self.sequence = sequence; self.cursor = cursor; self.viewport = viewport
        }
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
        public init(identity: Identity, cursor: Point?, viewport: SharedArea.Rect?, expiresAt: Date, label: String? = nil, usage: UsageSnapshot? = nil) {
            self.identity = identity; self.cursor = cursor; self.viewport = viewport; self.expiresAt = expiresAt
            self.label = label; self.usage = usage
        }
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
        public init(scope: Scope, after: UInt64, through: UInt64, events: [Event], nextCursor: UInt64,
                    presenceVersion: UUID, presence: [Presence], serverTime: Date) {
            self.scope = scope; self.after = after; self.through = through; self.events = events; self.nextCursor = nextCursor
            self.presenceVersion = presenceVersion; self.presence = presence; self.serverTime = serverTime
        }
    }
}
