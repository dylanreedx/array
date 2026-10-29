import Foundation

/// Stable IDs in docs/internals/notification-paths.md. This enum classifies the
/// hosted sender only; Mac local alerts and diagnostic Core pushes have their
/// own mapped paths. New cases require a map entry and a behavioral witness.
public enum RelayNotificationPath: String, Codable, Sendable, CaseIterable {
    case approval = "H-01"
    case input = "H-02"
    case failure = "H-03"
    case completion = "H-04"
    case progress = "H-05"
    case cancelled = "H-06"
    case invalidIdentity = "H-07"
    case unsupportedState = "H-08"
    case unprojectable = "PUB-05"
    case invalidTask = "T-01"
    case taskUnknown = "T-02"
    case taskActive = "T-03"
    case taskAttention = "T-04"
    case taskFailure = "T-05"
    case taskCompletion = "T-06"
    case taskCancelled = "T-07"
}

public struct RelayNotificationDecision: Sendable, Equatable {
    public let path: RelayNotificationPath
    public let projection: RelaySystemSurfaceProjection?
}

/// No payload, names, tokens, URLs, authorization headers or error text. A
/// provider accepting a request is intentionally distinct from phone display.
public struct RelayNotificationTrace: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case unprojectable, noRecipients, suppressed, deduplicated, acceptedByApple
        case rejectedByApple, tokenInvalidated, transportFailure, preparationFailure, capacityRejected, taskOwnerSuppressed
    }
    public let path: RelayNotificationPath
    public let instanceID: UUID
    public let eventSequence: Int64
    public let decisionID: String?
    public let registrationKind: String?
    public let registrationID: UUID?
    public let deviceID: UUID?
    public let outcome: Outcome
    public let statusCode: Int?

    public static func log(_ trace: Self) {
        guard let data = try? JSONEncoder().encode(trace),
              let line = String(data: data, encoding: .utf8) else { return }
        print("relay.notification \(line)")
    }
}
