import Foundation

/// The one-off files agents wrote, newest first, for the ⌘K "Open file" step's
/// "Made by agents" section.
///
/// Fed from the tool-detail observation the supervisor already receives for every
/// Write / apply_patch call (`AgentToolDetailObservation.fileChanges`), so it adds
/// no transcript parsing and no filesystem walk. Only the kinds BEHAVIOUR.md §8
/// calls one-off are kept: renders, reports, exports, and a markdown deliverable
/// under an output folder. A source edit is already in the diff and the file tree;
/// listing it here would bury the reports Dylan came for.
public final class AgentMadeFileLog: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let path: String
        public let agentID: UUID
        public let madeAt: Date
    }

    public static let capacity = 200
    static let oneOffExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "mp4", "mov",
        "html", "htm", "pdf", "xlsx", "csv", "tsv", "zip", "docx", "pptx",
    ]
    /// Folders whose markdown is a deliverable rather than source.
    static let deliverableFolders = ["qa-runs", "outputs", "output", "reports", "exports"]
    static let ignoredComponents: Set<String> = ["node_modules", ".build", ".git", "tmp", "DerivedData", ".swiftpm"]

    private let lock = NSLock()
    private var entries: [Entry]
    private let fileURL: URL?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = stored
        } else {
            entries = []
        }
    }

    /// The files a shell command writes by redirection (`> f`, `>> f`, `&> f`) or `tee`,
    /// which is how an agent makes a file with Bash instead of a Write tool. Only
    /// literal paths: a variable, a substitution or `/dev/*` is not a file to offer.
    /// A command that fails leaves no file, and `recent` drops what is not on disk.
    public static func shellWrittenPaths(command: String) -> [String] {
        // Split into words and operators, honouring quotes.
        var tokens: [(text: String, isOperator: Bool)] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        let chars = Array(command)
        var i = 0
        func flush() { if hasCurrent { tokens.append((current, false)); current = ""; hasCurrent = false } }
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil } else if c == "\\", q == "\"", i + 1 < chars.count { i += 1; current.append(chars[i]) } else { current.append(c) }
                i += 1; continue
            }
            switch c {
            case "'", "\"": quote = c; hasCurrent = true
            case "\\": if i + 1 < chars.count { i += 1; current.append(chars[i]); hasCurrent = true }
            case " ", "\t", "\n": flush()
            case ">":
                // "2>" and "2>&1" are descriptors, not files: drop a lone digit before the operator.
                if hasCurrent, current.count == 1, current.first?.isNumber == true { current = ""; hasCurrent = false }
                else if hasCurrent, current == "&" { current = ""; hasCurrent = false }
                else { flush() }
                var op = ">"
                if i + 1 < chars.count, chars[i + 1] == ">" { op = ">>"; i += 1 }
                if i + 1 < chars.count, chars[i + 1] == "&" { op = ">&"; i += 1 }
                tokens.append((op, true))
            case "|", ";", "&":
                if c == "&", i + 1 < chars.count, chars[i + 1] == ">" { hasCurrent = true; current = "&"; break }
                flush(); tokens.append((String(c), true))
            default: current.append(c); hasCurrent = true
            }
            i += 1
        }
        flush()
        var found: [String] = []
        func accept(_ path: String) {
            guard !path.isEmpty, !path.hasPrefix("/dev/"), !path.hasPrefix("&"),
                  !path.contains("$"), !path.contains("`"), !path.contains("*") else { return }
            if !found.contains(path) { found.append(path) }
        }
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.isOperator, token.text == ">" || token.text == ">>", index + 1 < tokens.count, !tokens[index + 1].isOperator {
                accept(tokens[index + 1].text)
            } else if !token.isOperator, token.text == "tee" {
                var next = index + 1
                while next < tokens.count, !tokens[next].isOperator {
                    if !tokens[next].text.hasPrefix("-") { accept(tokens[next].text) }
                    next += 1
                }
            }
            index += 1
        }
        return found
    }

    /// Whether a written file is one a person would go looking for.
    public static func isOneOff(action: AgentToolDetailObservation.FileAction, path: String, checkoutRoot: String) -> Bool {
        guard action == .add || action == .write else { return false }
        let url = resolved(path, checkoutRoot: checkoutRoot)
        let components = url.pathComponents
        if components.contains(where: { ignoredComponents.contains($0) }) { return false }
        if components.starts(with: ["/", "private", "tmp"]) || components.starts(with: ["/", "tmp"]) { return false }
        let ext = url.pathExtension.lowercased()
        if oneOffExtensions.contains(ext) { return true }
        guard ext == "md" || ext == "markdown" else { return false }
        let root = URL(fileURLWithPath: checkoutRoot, isDirectory: true).standardizedFileURL.pathComponents
        if components.starts(with: root) {
            let relative = components.dropFirst(root.count)
            return relative.contains { deliverableFolders.contains($0) }
        }
        // Outside the checkout: the agent's scratch or output roots.
        return true
    }

    public static func resolved(_ path: String, checkoutRoot: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return URL(fileURLWithPath: checkoutRoot, isDirectory: true).appendingPathComponent(expanded).standardizedFileURL
    }

    public func record(_ changes: [AgentToolDetailObservation.FileChange], agent: UUID, checkoutRoot: String, at date: Date = Date()) {
        let kept = changes.filter { Self.isOneOff(action: $0.action, path: $0.path, checkoutRoot: checkoutRoot) }
        guard !kept.isEmpty else { return }
        lock.lock()
        for change in kept {
            let path = Self.resolved(change.path, checkoutRoot: checkoutRoot).path
            entries.removeAll { $0.path == path }
            entries.insert(Entry(path: path, agentID: agent, madeAt: date), at: 0)
        }
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        let snapshot = entries
        lock.unlock()
        persist(snapshot)
    }

    /// Newest first, only files that still exist, optionally one agent's.
    public func recent(limit: Int = 12, agent: UUID? = nil) -> [Entry] {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        var result: [Entry] = []
        for entry in snapshot where agent == nil || entry.agentID == agent {
            guard FileManager.default.fileExists(atPath: entry.path) else { continue }
            result.append(entry)
            if result.count == limit { break }
        }
        return result
    }

    private func persist(_ snapshot: [Entry]) {
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
