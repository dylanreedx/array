import Foundation

public enum QAVerdict: String, Codable, Sendable, Equatable {
    case passed
    case failed
    case unknown

    public var glyph: String {
        switch self {
        case .passed: return "✓"
        case .failed: return "✕"
        case .unknown: return "?"
        }
    }

    public static func normalize(_ value: String?) -> QAVerdict {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "passed", "pass", "success", "succeeded", "green": return .passed
        case "failed", "fail", "failure", "error", "red": return .failed
        default: return .unknown
        }
    }
}

public struct QARunManifestSnapshot: Equatable, Sendable {
    public var verdict: QAVerdict
    public var check: String?
    public var manifestPath: String
    public var runDirectoryPath: String
    public var modifiedAt: Date

    public init(verdict: QAVerdict, check: String?, manifestPath: String, runDirectoryPath: String, modifiedAt: Date) {
        self.verdict = verdict
        self.check = check
        self.manifestPath = manifestPath
        self.runDirectoryPath = runDirectoryPath
        self.modifiedAt = modifiedAt
    }

    public var tooltip: String {
        let label = check.map { "\($0): " } ?? ""
        return "\(label)\(verdict.rawValue) · \(ISO8601DateFormatter().string(from: modifiedAt))"
    }
}

public enum QARunManifestReader {
    public static func latest(projectRoot: URL, fileManager: FileManager = .default) -> QARunManifestSnapshot? {
        let qaRuns = projectRoot.appendingPathComponent("qa-runs", isDirectory: true)
        guard let enumerator = fileManager.enumerator(at: qaRuns, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        var snapshots: [QARunManifestSnapshot] = []
        for case let url as URL in enumerator where url.lastPathComponent == "manifest.json" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            let object: [String: Any]
            if let data = try? Data(contentsOf: url),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                object = parsed
            } else {
                object = [:]
            }
            let verdict = QAVerdict.normalize((object["verdict"] as? String) ?? (object["status"] as? String))
            let check = object["check"] as? String
            snapshots.append(QARunManifestSnapshot(
                verdict: verdict,
                check: check,
                manifestPath: url.path,
                runDirectoryPath: url.deletingLastPathComponent().path,
                modifiedAt: values.contentModificationDate ?? Date.distantPast
            ))
        }
        return snapshots.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.manifestPath < rhs.manifestPath
        }.first
    }
}
