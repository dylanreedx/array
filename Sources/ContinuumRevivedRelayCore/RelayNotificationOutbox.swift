import Foundation
import ContinuumRevivedRelayProtocol

public enum RelayOutboxPolicy {
    public static let maximumPendingPerInstance = 256
    public static let maximumAttempts = 5
    public static let maximumAge: TimeInterval = 3600
    public static let leaseDuration: TimeInterval = 120
    public static let batchLimit = 32

    public static func retryDelay(attempt: Int, statusCode: Int?, retryAfter: TimeInterval? = nil) -> TimeInterval? {
        guard statusCode == nil || statusCode == 0 || statusCode == 429 || (500...599).contains(statusCode!) else { return nil }
        let base: Double = statusCode.map { (500...599).contains($0) ? 900 : ($0 == 429 ? 60 : 5) } ?? 5
        let delay = min(base * pow(4, Double(max(0, min(4, attempt - 1)))), max(900, base * 2))
        // Never shorten the provider's delay. A delay beyond the alert's lifetime
        // expires the intent instead of retrying early.
        return max(delay, retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0)
    }
}

struct RelayOutboxIntent: Codable, Sendable {
    let apnsID: UUID
    let path: RelayNotificationPath
    let decisionID: String
    let payload: Data
    let priority: String
    let collapseID: String?
    let subject: String

    init?(projection: RelaySystemSurfaceProjection) throws {
        guard let notification = projection.notification else { return nil }
        apnsID = UUID() // persisted once, reused verbatim across all attempts
        path = notification.path; decisionID = projection.notificationIdentity
        payload = try notification.encoded()
        priority = notification.interruption == "passive" ? "5" : "10"
        collapseID = notification.coalesces ? (notification.collapseID ?? "array-terminal-\(projection.instanceID.uuidString)") : nil
        subject = projection.outboxSubject
    }
}

public struct RelayOutboxClaim: Sendable {
    public let instanceID: UUID
    public let registrationID: UUID
    public let decisionID: String
    public let eventSequence: Int64
    public let attempt: Int
    public let expiresAt: Date
    public let leaseID: UUID
    let intent: RelayOutboxIntent

    var apnsID: String {
        intent.apnsID.uuidString
    }
}

public struct RelayOutboxRecipient: Sendable {
    public let registration: RelayStoredPushRegistration
    let generation: Data
}

public enum RelayOutboxEnqueueResult: Sendable { case queued, pending, deduplicated, capacityRejected, suppressed }

public struct RelayOutboxTrace: Codable, Sendable {
    public enum Transition: String, Codable, Sendable, CaseIterable {
        case queued = "OUT-01", leased = "OUT-02", retryScheduled = "OUT-03", accepted = "OUT-04"
        case permanentFailure = "OUT-05", expired = "OUT-06", exhausted = "OUT-07", revoked = "OUT-08"
        case capacityRejected = "OUT-09", deduplicated = "OUT-10", staleLease = "OUT-11", preparationFailure = "OUT-12"
        case superseded = "OUT-13"
    }
    public let path: Transition
    public let decisionPath: RelayNotificationPath
    public let instanceID: UUID
    public let registrationID: UUID
    public let decisionID: String
    public let eventSequence: Int64
    public let attempt: Int
    public let statusCode: Int?

    public static func log(_ value: Self) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        FileHandle.standardOutput.write(Data("relay.outbox ".utf8) + data + Data("\n".utf8))
    }
}
