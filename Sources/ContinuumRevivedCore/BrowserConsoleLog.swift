import Foundation

public enum BrowserConsoleLogLevel: String, Codable, Equatable, Sendable, CaseIterable {
    case log
    case info
    case warn
    case error
    case debug

    public static func normalized(_ rawValue: String) -> BrowserConsoleLogLevel {
        BrowserConsoleLogLevel(rawValue: rawValue.lowercased()) ?? .log
    }
}

public struct BrowserConsoleLogEntry: Codable, Equatable, Sendable {
    public var level: BrowserConsoleLogLevel
    public var message: String
    public var timestamp: Date
    public var url: String?

    public init(level: BrowserConsoleLogLevel, message: String, timestamp: Date, url: String?) {
        self.level = level
        self.message = message
        self.timestamp = timestamp
        self.url = url
    }
}

public struct BrowserConsoleLogBuffer: Equatable, Sendable {
    public static let defaultCapacity = 500

    public let capacity: Int
    public private(set) var entries: [BrowserConsoleLogEntry]

    public init(capacity: Int = BrowserConsoleLogBuffer.defaultCapacity, entries: [BrowserConsoleLogEntry] = []) {
        self.capacity = max(1, capacity)
        self.entries = Array(entries.suffix(max(1, capacity)))
    }

    public mutating func append(_ entry: BrowserConsoleLogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    public mutating func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}
