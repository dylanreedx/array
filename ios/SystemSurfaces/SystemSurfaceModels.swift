import ActivityKit
import ContinuumRevivedAgentUI
import Foundation

enum ArraySystemSurfaceConstants {
    static let appGroupIdentifier = "group.dev.dylanreedx.continuum"
    static let snapshotFilename = "array-widget-snapshot.json"
    static let activityPushTokenFilename = "array-live-activity-token.txt"
    static let activityPushToStartTokenFilename = "array-live-activity-start-token.txt"
    static let apnsTokenDefaultsKey = "array.apns.device-token"
    static let deepLinkUserInfoKey = "deepLink"
}

struct ArrayWidgetAgent: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var workspaceName: String?
    var status: AgentStatus
    var startedAt: Date
}

struct ArrayWidgetSnapshot: Codable, Equatable, Sendable {
    var generatedAt: Date
    var instanceID: UUID?
    var runningCount: Int
    var attentionCount: Int
    var phase: DualPlaneGyroPresentationPhase
    var highlightedAgent: ArrayWidgetAgent?

    static let empty = ArrayWidgetSnapshot(
        generatedAt: .distantPast,
        instanceID: nil,
        runningCount: 0,
        attentionCount: 0,
        phase: .idle,
        highlightedAgent: nil
    )

    var isStale: Bool { Date().timeIntervalSince(generatedAt) > 5 * 60 }
    var deepLink: URL { URL(string: highlightedAgent.map { "array://agent/\($0.id.uuidString)" } ?? "array://agents")! }
}

struct ArrayAgentActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        var runningCount: Int
        var attentionCount: Int
        var phase: DualPlaneGyroPresentationPhase
        var agentID: UUID?
        var agentName: String?
        var workspaceName: String?
        var startedAt: Date?
        var statusText: String
    }

    var instanceID: UUID
    var macName: String
}

enum ArrayWidgetSnapshotStore {
    static func read() -> ArrayWidgetSnapshot {
        guard let url = snapshotURL(),
              let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(ArrayWidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    static func write(_ snapshot: ArrayWidgetSnapshot) throws {
        guard let url = snapshotURL() else { return }
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: [.atomic])
    }

    static func storeActivityPushToken(_ token: String) {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ArraySystemSurfaceConstants.appGroupIdentifier
        ) else { return }
        try? Data(token.utf8).write(
            to: directory.appendingPathComponent(ArraySystemSurfaceConstants.activityPushTokenFilename),
            options: [.atomic]
        )
    }

    static func activityPushToken() -> Data? {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ArraySystemSurfaceConstants.appGroupIdentifier
        ), let value = try? String(
            contentsOf: directory.appendingPathComponent(ArraySystemSurfaceConstants.activityPushTokenFilename),
            encoding: .utf8
        ) else { return nil }
        return Data(hexadecimalString: value)
    }

    static func storeActivityPushToStartToken(_ token: String) {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ArraySystemSurfaceConstants.appGroupIdentifier
        ) else { return }
        try? Data(token.utf8).write(
            to: directory.appendingPathComponent(ArraySystemSurfaceConstants.activityPushToStartTokenFilename),
            options: [.atomic]
        )
    }

    static func activityPushToStartToken() -> Data? {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ArraySystemSurfaceConstants.appGroupIdentifier
        ), let value = try? String(
            contentsOf: directory.appendingPathComponent(ArraySystemSurfaceConstants.activityPushToStartTokenFilename),
            encoding: .utf8
        ) else { return nil }
        return Data(hexadecimalString: value)
    }

    static func apnsPushToken() -> Data? {
        guard let value = UserDefaults(suiteName: ArraySystemSurfaceConstants.appGroupIdentifier)?
            .string(forKey: ArraySystemSurfaceConstants.apnsTokenDefaultsKey) else { return nil }
        return Data(hexadecimalString: value)
    }

    static func clearPushTokens() {
        UserDefaults(suiteName: ArraySystemSurfaceConstants.appGroupIdentifier)?
            .removeObject(forKey: ArraySystemSurfaceConstants.apnsTokenDefaultsKey)
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ArraySystemSurfaceConstants.appGroupIdentifier
        ) else { return }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(ArraySystemSurfaceConstants.activityPushTokenFilename)
        )
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(ArraySystemSurfaceConstants.activityPushToStartTokenFilename)
        )
    }

    private static func snapshotURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ArraySystemSurfaceConstants.appGroupIdentifier
        )?.appendingPathComponent(ArraySystemSurfaceConstants.snapshotFilename)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension Data {
    init?(hexadecimalString: String) {
        let value = hexadecimalString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count.isMultiple(of: 2), !value.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        self = Data(bytes)
    }
}
