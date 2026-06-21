import Foundation

public enum BrowserNetworkLiteEventKind: String, Codable, Equatable, Sendable, CaseIterable {
    case navigationStarted
    case committed
    case finished
    case failed
    case downloadStarted
    case childOpened
}

public struct BrowserNetworkLiteEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var tileId: UUID
    /// String-backed so persisted/artifact payloads stay honest about the exact
    /// app-observable event kind without implying full DevTools Network parity.
    public var kind: String
    public var url: String
    public var timestamp: Date
    /// nil unless WebKit exposes a real HTTPURLResponse status code.
    public var statusCode: Int?
    public var errorDescription: String?

    public init(
        id: UUID = UUID(),
        tileId: UUID,
        kind: String,
        url: String,
        timestamp: Date = Date(),
        statusCode: Int? = nil,
        errorDescription: String? = nil
    ) {
        self.id = id
        self.tileId = tileId
        self.kind = kind
        self.url = url
        self.timestamp = timestamp
        self.statusCode = statusCode
        self.errorDescription = errorDescription
    }

    public init(
        id: UUID = UUID(),
        tileId: UUID,
        kind: BrowserNetworkLiteEventKind,
        url: String,
        timestamp: Date = Date(),
        statusCode: Int? = nil,
        errorDescription: String? = nil
    ) {
        self.init(
            id: id,
            tileId: tileId,
            kind: kind.rawValue,
            url: url,
            timestamp: timestamp,
            statusCode: statusCode,
            errorDescription: errorDescription
        )
    }
}

public struct BrowserNetworkLiteEventBuffer: Equatable, Sendable {
    public static let defaultCapacity = 500

    public let capacity: Int
    public private(set) var entries: [BrowserNetworkLiteEvent]

    public init(capacity: Int = BrowserNetworkLiteEventBuffer.defaultCapacity, entries: [BrowserNetworkLiteEvent] = []) {
        self.capacity = max(1, capacity)
        self.entries = Array(entries.suffix(max(1, capacity)))
    }

    public mutating func append(_ entry: BrowserNetworkLiteEvent) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    public mutating func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}
