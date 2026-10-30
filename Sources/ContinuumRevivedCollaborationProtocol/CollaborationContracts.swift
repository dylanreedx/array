import Foundation

/// Collaboration accounts are independent of provider CLI login and companion pairing.
public enum Collaboration {
    public enum Role: String, Codable, Sendable { case owner, editor, viewer }
    public struct Identity: Codable, Sendable, Equatable {
        public let person: SharedArea.ID<SharedArea.Person>
        public let device: UUID
        public init(person: SharedArea.ID<SharedArea.Person>, device: UUID) { self.person = person; self.device = device }
    }
    public struct Enrollment: Codable, Sendable {
        public let person: SharedArea.ID<SharedArea.Person>
        public let code: String
        public let expiresAt: Date
        public init(person: SharedArea.ID<SharedArea.Person>, code: String, expiresAt: Date) {
            self.person = person; self.code = code; self.expiresAt = expiresAt
        }
    }
    public struct RedeemEnrollment: Codable, Sendable {
        public let code: String
        public let deviceLabel: String
        public init(code: String, deviceLabel: String) { self.code = code; self.deviceLabel = deviceLabel }
    }
    public struct Credential: Codable, Sendable {
        public let identity: Identity
        public let token: String
        public init(identity: Identity, token: String) { self.identity = identity; self.token = token }
    }
    public struct InviteRequest: Codable, Sendable {
        public let person: SharedArea.ID<SharedArea.Person>
        public let role: Role
        public let lifetime: TimeInterval
        public init(person: SharedArea.ID<SharedArea.Person>, role: Role = .editor, lifetime: TimeInterval = 3600) {
            self.person = person; self.role = role; self.lifetime = lifetime
        }
    }
    public struct Invitation: Codable, Sendable {
        public let code: String
        public let expiresAt: Date
        public init(code: String, expiresAt: Date) { self.code = code; self.expiresAt = expiresAt }
    }
    public struct AcceptInvitation: Codable, Sendable {
        public let code: String
        public init(code: String) { self.code = code }
    }
    public struct Scope: Codable, Equatable, Sendable {
        public let area: SharedArea.ID<SharedArea.Area>
        public let epoch: Int64
        public let role: Role
        public init(area: SharedArea.ID<SharedArea.Area>, epoch: Int64, role: Role) { self.area = area; self.epoch = epoch; self.role = role }
    }
    public struct State: Codable, Equatable, Sendable {
        public let scope: Scope
        public let document: SharedArea.Document
        public init(scope: Scope, document: SharedArea.Document) { self.scope = scope; self.document = document }
    }
    public struct Mutation: Codable, Sendable {
        public let epoch: Int64
        public let command: SharedArea.Command
        public init(epoch: Int64, command: SharedArea.Command) { self.epoch = epoch; self.command = command }
    }
    public struct Receipt: Codable, Sendable {
        public let revision: UInt64
        public let duplicate: Bool
        public init(revision: UInt64, duplicate: Bool) { self.revision = revision; self.duplicate = duplicate }
    }
    public struct Host: Codable, Sendable {
        public let id: SharedArea.ID<SharedArea.Host>
        public init(id: SharedArea.ID<SharedArea.Host>) { self.id = id }
    }
    public struct DeviceEnrollmentRequest: Codable, Sendable {
        public let lifetime: TimeInterval
        public init(lifetime: TimeInterval = 600) { self.lifetime = lifetime }
    }
    public struct ErrorBody: Codable, Sendable {
        public let code: String
        public init(code: String) { self.code = code }
    }
}
