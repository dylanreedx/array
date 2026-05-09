import Foundation

public struct ToolDetector: Sendable {
    private let fileExists: @Sendable (String) -> Bool

    public init(fileExists: @escaping @Sendable (String) -> Bool) {
        self.fileExists = fileExists
    }

    public func locate(_ name: String, in path: [String]) -> String? {
        for dir in path where !dir.isEmpty {
            let trimmed = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
            let candidate = "\(trimmed)/\(name)"
            if fileExists(candidate) {
                return candidate
            }
        }
        return nil
    }

    public static let live = ToolDetector { path in
        FileManager.default.isExecutableFile(atPath: path)
    }

    public static func splitPath(_ value: String) -> [String] {
        value.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    }
}
