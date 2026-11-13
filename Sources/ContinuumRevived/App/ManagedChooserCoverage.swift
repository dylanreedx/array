import Foundation
import ContinuumRevivedCore

/// Partial pre-pass snapshots, refreshed away from request/tool dispatch.
/// Cold replies say loading; cached replies include an observation time.
final class ManagedChooserCoverage: @unchecked Sendable {
    static let shared = ManagedChooserCoverage()
    static let maximumChecksPerPart = 8
    static let maximumUnownedFiles = 32
    private struct Entry: Decodable { var invocation: String; var covers: [String]; var checkFiles: [String]? }
    private struct Manifest: Decodable { var checks: [Entry] }
    private struct Snapshot { var entries: [Entry]; var at: Date }
    private let lock = NSLock()
    private var snapshots: [String: Snapshot] = [:]
    private var loading = Set<String>()
    func prepare(root: String) {
        let load = lock.withLock { loading.insert(root).inserted }
        guard load else { return }
        DispatchQueue.global(qos: .utility).async {
            let url = URL(fileURLWithPath: root).appendingPathComponent("scripts/check-coverage-manifest.json")
            let manifest = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
            self.lock.withLock {
                if let manifest { self.snapshots[root] = Snapshot(entries: manifest.checks, at: Date()) }
                else if self.snapshots[root] == nil { self.snapshots[root] = Snapshot(entries: [], at: Date()) }
                self.loading.remove(root)
            }
        }
    }
    func refreshing(root: String) -> Bool { lock.withLock { loading.contains(root) } }
    func status(root: String) -> String {
        lock.withLock { snapshots[root].map { $0.entries.isEmpty ? "unavailable" : "partial" } ?? "loading" }
    }
    func observedAt(root: String) -> String? {
        lock.withLock { snapshots[root].map { ISO8601DateFormatter().string(from: $0.at) } }
    }
    private func matches(_ path: String, _ pattern: String) -> Bool {
        var expression = "^", index = pattern.startIndex
        while index < pattern.endIndex {
            let char = pattern[index], next = pattern.index(after: index)
            if char == "*" {
                if next < pattern.endIndex && pattern[next] == "*" { expression += ".*"; index = pattern.index(after: next); continue }
                expression += "[^/]*"
            } else if char == "?" { expression += "[^/]" }
            else { expression += NSRegularExpression.escapedPattern(for: String(char)) }
            index = next
        }
        expression += "$"
        return path.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
            || pattern.lowercased().hasPrefix(path == "." ? "" : path.lowercased() + "/")
    }
    func checks(root: String, owns: [String]) -> [String] {
        let entries = lock.withLock { snapshots[root]?.entries ?? [] }
        return entries.filter { entry in entry.covers.contains { glob in owns.contains { matches($0, glob) } } }.map(\.invocation).sorted()
    }
    func unowned(root: String, contracts: [AgentDelegationContract]) -> [String] {
        let files = lock.withLock { Set((snapshots[root]?.entries ?? []).flatMap { $0.checkFiles ?? [] }) }
        let claims = contracts.flatMap { $0.owns + $0.shared }
        return files.filter { file in !claims.contains { claim in claim == "." || file.caseInsensitiveCompare(claim) == .orderedSame || file.lowercased().hasPrefix(claim.lowercased() + "/") } }.sorted()
    }
}
