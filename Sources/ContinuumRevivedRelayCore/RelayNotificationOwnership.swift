import Foundation

/// Source-only task ownership routes; same-change inventory lives in
/// docs/internals/notification-paths.md. These records contain no account IDs,
/// payloads, tokens, paths, SQL or error descriptions.
public enum RelayNotificationOwnershipPath: String, Codable, Sendable, CaseIterable {
    case committed = "OWN-01"
    case legacySuppressed = "OWN-02"
    case stale = "OWN-03"
    case revisionConflict = "OWN-04"
    case publisherMismatch = "OWN-05"
    case invalidBatch = "OWN-06"
    case deliveryFailure = "OWN-07"

    public func log() {
        FileHandle.standardError.write(Data("{\"path\":\"\(rawValue)\",\"event\":\"notification_ownership\"}\n".utf8))
    }
}
