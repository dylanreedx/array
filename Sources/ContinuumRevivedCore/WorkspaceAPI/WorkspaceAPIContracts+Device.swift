import Foundation

/// Local simulator control. Identity and grants come from the host, never this
/// payload. Explicit checkout and a host-issued session/frame bind every action.
public struct DeviceRequest: Codable, Equatable, Sendable {
    public let checkoutHandle: CheckoutHandle
    public var tileId: UUID?
    public var zoneId: UUID?
    public var deviceId: String?
    public var templateId: String?
    public var sessionId: UUID?
    public var observationId: UUID?
    public var kind: String?
    public var x: Double?
    public var y: Double?
    public var endX: Double?
    public var endY: Double?
    public var milliseconds: Int?
    public var text: String?
    public var key: String?
    public var orientation: Int?
    public var allowBoot: Bool?
    public var idempotencyKey: String?
}

/// Host-owned creation identity; no grants, live session, helper token or endpoint
/// are persisted. Digests allow a retried create to find its original tile even
/// after restart, without persisting the model's raw retry key.
public struct IOSPreviewAutomationOwnership: Codable, Equatable, Sendable {
    public let agentId: UUID
    public let checkout: CheckoutHandle
    public let creationKeyDigest: String
    public let creationPayloadDigest: String
    public let managedSimulator: Bool?
    public init(agentId: UUID, checkout: CheckoutHandle, creationKeyDigest: String, creationPayloadDigest: String, managedSimulator: Bool? = nil) {
        self.agentId = agentId; self.checkout = checkout
        self.creationKeyDigest = creationKeyDigest; self.creationPayloadDigest = creationPayloadDigest; self.managedSimulator = managedSimulator
    }
}

public extension WorkspaceAPIOp {
    static let deviceOperations: Set<WorkspaceAPIOp> = [.deviceList, .deviceOpen, .deviceObserve, .deviceAct, .deviceClose, .deviceBuildRun]
}
