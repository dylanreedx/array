import Foundation

/// Local debug build/install/launch only. The host resolves the explicit
/// checkout-relative Xcode container and verifies the scheme before building.
public struct DeviceBuildRequest: Codable, Equatable, Sendable {
    public let checkoutHandle: CheckoutHandle
    public var kind: String
    public var sessionId: UUID?
    public var projectFile: String?
    public var scheme: String?
    public var operationId: String?
    public var idempotencyKey: String?
}

/// Tagged operation result; never interpreted as a delegated agent's answer.
/// Log is a bounded private tail, not a host file path or duplicate transcript.
public struct DeviceBuildOperationResult: Codable, Equatable, Sendable {
    public let kind: String
    public let state: String
    public let deviceId: String
    public let projectFile: String
    public let scheme: String
    public let bundleId: String?
    public let mayHaveInstalled: Bool
    public let logTail: String?
    public let logTruncated: Bool
    public let failureReason: String?
    public init(state: String, deviceId: String, projectFile: String, scheme: String,
                bundleId: String?, mayHaveInstalled: Bool, logTail: String?, logTruncated: Bool, failureReason: String? = nil) {
        kind = "device_build"; self.state = state; self.deviceId = deviceId
        self.projectFile = projectFile; self.scheme = scheme; self.bundleId = bundleId
        self.mayHaveInstalled = mayHaveInstalled; self.logTail = logTail; self.logTruncated = logTruncated; self.failureReason = failureReason
    }
}
