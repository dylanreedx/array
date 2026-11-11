import CryptoKit
import Foundation

// MARK: - Project standards (`.plans/116`, part 16; `docs/internals/project-standards-on-demand.md`)

/// One numbered rule, verbatim from its standard (`Why` and `Enforced by` included).
public struct ProjectStandardRule: Codable, Equatable, Sendable {
    /// `<standard id>#<number>`, e.g. `project/benches-and-storage#3`.
    public var id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// One standard file that parsed cleanly.
public struct ProjectStandard: Codable, Equatable, Sendable {
    /// Its path under `docs/standards/` without `.md`.
    public var id: String
    /// Checkout-relative path of the file.
    public var path: String
    public var title: String
    public var appliesWhen: String
    /// `sha256:` and the first 16 hex digits of the file's bytes.
    public var version: String
    public var rules: [ProjectStandardRule]

    public init(id: String, path: String, title: String, appliesWhen: String, version: String, rules: [ProjectStandardRule]) {
        self.id = id
        self.path = path
        self.title = title
        self.appliesWhen = appliesWhen
        self.version = version
        self.rules = rules
    }
}

/// A standard that could not be used, and why. Never dropped silently.
public struct ProjectStandardsIssue: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case missingTrigger = "missing_trigger"
        case emptyTrigger = "empty_trigger"
        case multilineTrigger = "multiline_trigger"
        case duplicateTrigger = "duplicate_trigger"
        case noRules = "no_rules"
        case unnumberedRule = "unnumbered_rule"
        case duplicateRuleId = "duplicate_rule_id"
        case outsideCheckout = "outside_checkout"
        case unreadable
    }

    /// Checkout-relative path of the file or directory.
    public var path: String
    public var code: Code
    public var message: String
    /// 1-based line, when the problem has one.
    public var line: Int?

    public init(path: String, code: Code, message: String, line: Int? = nil) {
        self.path = path
        self.code = code
        self.message = message
        self.line = line
    }
}

public struct ProjectStandardsIndex: Equatable, Sendable {
    public var standards: [ProjectStandard]
    public var issues: [ProjectStandardsIssue]

    public init(standards: [ProjectStandard], issues: [ProjectStandardsIssue]) {
        self.standards = standards
        self.issues = issues
    }
}

public enum ProjectStandards {
    /// Where standards are looked for, relative to the agent's own checkout.
    public static let directory = "docs/standards"
    /// Set to `1` in the MCP server's and Pi's environment when the checkout
    /// has standards; only then is `array_standards` offered.
    public static let environmentKey = "ARRAY_WORKSPACE_PROJECT_STANDARDS"
    /// An index beside the standards, never a standard itself.
    static let readmeName = "README.md"

    public enum Parsed: Equatable, Sendable {
        /// No `Applies when:`, `Status:` or `Layer:` header: a README or index.
        case notAStandard
        case standard(ProjectStandard)
        case failed([ProjectStandardsIssue])
    }

    /// Parse one file. `id` is its path under `docs/standards/` without `.md`;
    /// `path` is checkout-relative.
    public static func parse(id: String, path: String, data: Data) -> Parsed {
        guard let text = String(data: data, encoding: .utf8) else {
            return .failed([ProjectStandardsIssue(path: path, code: .unreadable, message: "Not UTF-8 text.")])
        }
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        func issue(_ code: ProjectStandardsIssue.Code, _ message: String, line: Int? = nil) -> Parsed {
            .failed([ProjectStandardsIssue(path: path, code: code, message: message, line: line)])
        }
        let fieldPrefixes = ["Applies when:", "Status:", "Layer:"]
        func isField(_ line: String) -> Bool { fieldPrefixes.contains { line.hasPrefix($0) } }

        // Header: from the start to the first `## ` heading.
        let headerEnd = lines.firstIndex { $0.hasPrefix("## ") } ?? lines.count
        let titleIndex = lines[..<headerEnd].firstIndex { $0.hasPrefix("# ") }
        let title = titleIndex.map { lines[$0].dropFirst(2).trimmingCharacters(in: .whitespaces) } ?? id
        let triggerLines = (0..<headerEnd).filter { lines[$0].hasPrefix("Applies when:") }
        guard (0..<headerEnd).contains(where: { isField(lines[$0]) }) else { return .notAStandard }
        guard let triggerIndex = triggerLines.first else {
            return issue(.missingTrigger, "The header has no Applies when: line.")
        }
        guard triggerLines.count == 1 else {
            return issue(.duplicateTrigger, "The header has more than one Applies when: line.", line: triggerLines[1] + 1)
        }
        let appliesWhen = lines[triggerIndex].dropFirst("Applies when:".count).trimmingCharacters(in: .whitespaces)
        guard !appliesWhen.isEmpty else { return issue(.emptyTrigger, "Applies when: is blank.", line: triggerIndex + 1) }
        if triggerIndex + 1 < headerEnd {
            let next = lines[triggerIndex + 1]
            if !next.trimmingCharacters(in: .whitespaces).isEmpty, !isField(next) {
                return issue(.multilineTrigger, "Applies when: continues onto the next line; keep it on one line.", line: triggerIndex + 2)
            }
        }

        // Rules: numbered entries under `## Rules`, up to the next `## `.
        guard let rulesHeading = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Rules" }) else {
            return issue(.noRules, "No ## Rules section.")
        }
        let rulesEnd = lines[(rulesHeading + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
        var rules: [ProjectStandardRule] = []
        var current: (number: String, lines: [String])?
        func flush() {
            guard let open = current else { return }
            var body = open.lines
            while let last = body.last, last.trimmingCharacters(in: .whitespaces).isEmpty { body.removeLast() }
            rules.append(ProjectStandardRule(id: id + "#" + open.number, text: body.joined(separator: "\n")))
        }
        for index in (rulesHeading + 1)..<rulesEnd {
            let line = lines[index]
            if let number = ruleNumber(line) {
                flush()
                if rules.contains(where: { $0.id == id + "#" + number }) {
                    return issue(.duplicateRuleId, "Rule \(number) is numbered twice.", line: index + 1)
                }
                current = (number, [line])
            } else if current != nil {
                current?.lines.append(line)
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                return issue(.unnumberedRule, "Text before the first numbered rule has no rule id.", line: index + 1)
            }
        }
        flush()
        guard !rules.isEmpty else { return issue(.noRules, "## Rules has no numbered rules.", line: rulesHeading + 1) }
        return .standard(ProjectStandard(id: id, path: path, title: title, appliesWhen: appliesWhen,
                                         version: version(of: data), rules: rules))
    }

    /// `12.` or `3.4.` followed by a space opens a rule; returns `12` or `3.4`.
    static func ruleNumber(_ line: String) -> String? {
        var digits = ""
        var rest = Substring(line)
        while let first = rest.first, first.isASCII, first.isNumber || first == "." {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard digits.hasSuffix("."), rest.first == " ", digits.first?.isNumber == true else { return nil }
        let number = String(digits.dropLast())
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return number
    }

    /// Every standard in `checkoutRoot/docs/standards`, one level deep. nil
    /// when the directory does not exist. Each file is resolved with the
    /// workspace API's path rule (`AgentLocalFileLinkResolver`); anything that
    /// resolves outside the checkout is an issue and is never read.
    public static func scan(checkoutRoot: URL, fileManager: FileManager = .default) -> ProjectStandardsIndex? {
        let root = URL(fileURLWithPath: checkoutRoot.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        let directoryURL = root.appendingPathComponent(directory, isDirectory: true)
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        var standards: [ProjectStandard] = []
        var issues: [ProjectStandardsIssue] = []
        func contained(_ relative: String) -> Bool {
            AgentLocalFileLinkResolver.isContained(
                root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath(), in: root)
        }
        guard contained(directory) else {
            return ProjectStandardsIndex(standards: [], issues: [
                ProjectStandardsIssue(path: directory, code: .outsideCheckout, message: "Resolves outside this checkout; not read.")])
        }
        func names(_ relative: String) -> [String] {
            ((try? fileManager.contentsOfDirectory(atPath: root.appendingPathComponent(relative).path)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted()
        }
        var candidates: [String] = [] // relative to docs/standards
        for name in names(directory) {
            let relative = directory + "/" + name
            if name.hasSuffix(".md") { if name != readmeName { candidates.append(name) }; continue }
            var sub: ObjCBool = false
            guard fileManager.fileExists(atPath: root.appendingPathComponent(relative).path, isDirectory: &sub), sub.boolValue else { continue }
            guard contained(relative) else {
                issues.append(ProjectStandardsIssue(path: relative, code: .outsideCheckout, message: "Resolves outside this checkout; not read."))
                continue
            }
            candidates += names(relative).filter { $0.hasSuffix(".md") && $0 != readmeName }.map { name + "/" + $0 }
        }
        for candidate in candidates {
            let relative = directory + "/" + candidate
            let id = String(candidate.dropLast(3))
            switch AgentLocalFileLinkResolver.resolve(destination: relative, checkoutRoot: root, fileManager: fileManager) {
            case .failure(.outsideCheckout):
                issues.append(ProjectStandardsIssue(path: relative, code: .outsideCheckout, message: "Resolves outside this checkout; not read."))
            case .failure:
                continue
            case .success(let link):
                guard let data = fileManager.contents(atPath: link.path) else {
                    issues.append(ProjectStandardsIssue(path: relative, code: .unreadable, message: "Could not be read."))
                    continue
                }
                switch parse(id: id, path: relative, data: data) {
                case .notAStandard: continue
                case .standard(let standard): standards.append(standard)
                case .failed(let found): issues += found
                }
            }
        }
        return ProjectStandardsIndex(standards: standards.sorted { $0.id < $1.id },
                                     issues: issues.sorted { ($0.path, $0.line ?? 0) < ($1.path, $1.line ?? 0) })
    }

    /// Whether an agent launched in this checkout is offered `array_standards`.
    /// The one definition of presence: a name listing that reads no file.
    /// True when `docs/standards` is a symlink (reads then refuse it, naming
    /// it), or holds a `*.md` other than `README.md` at its top level or one
    /// folder down.
    public static func isPresent(checkoutRoot: URL, fileManager: FileManager = .default) -> Bool {
        let folder = checkoutRoot.appendingPathComponent(directory, isDirectory: true)
        guard let type = (try? fileManager.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType else { return false }
        if type == .typeSymbolicLink { return true }
        guard type == .typeDirectory else { return false }
        func isCandidate(_ name: String) -> Bool { name.hasSuffix(".md") && name != readmeName }
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
            if isCandidate(name) { return true }
            let nested = (try? fileManager.contentsOfDirectory(atPath: folder.appendingPathComponent(name).path)) ?? []
            if nested.contains(where: isCandidate) { return true }
        }
        return false
    }

    /// What `workspace.context` says when presence changed after launch.
    public static let toolListNote =
        "Tools are fixed when this agent starts; docs/standards changed since, so array_standards updates at its next start."

    public static func version(of data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
