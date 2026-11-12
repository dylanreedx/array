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
        /// `docs/standards`, `docs` or a subfolder is a symlink: not read.
        case symlinkedFolder = "symlinked_folder"
        /// A symlink whose target is outside `docs/standards`: not read.
        case outsideStandards = "outside_standards"
        /// More than one hard link: the same bytes live elsewhere too.
        case hardLink = "hard_link"
        case brokenLink = "broken_link"
        /// A `*.md` that is a socket, pipe, device or folder.
        case notRegularFile = "not_regular_file"
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

/// A `*.md` entry that is deliberately not a standard, and why. Listed, so
/// nothing in the folder disappears without a note.
public struct ProjectStandardsSkipped: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// `README.md`: the folder's index.
        case indexFile = "index_file"
        /// No `Applies when:`, `Status:` or `Layer:` header.
        case notAStandard = "not_a_standard"
        /// More than one folder below `docs/standards`.
        case nestedFolder = "nested_folder"
    }
    public var path: String
    public var reason: Reason

    public init(path: String, reason: Reason) {
        self.path = path
        self.reason = reason
    }
}

public struct ProjectStandardsIndex: Equatable, Sendable {
    public var standards: [ProjectStandard]
    public var issues: [ProjectStandardsIssue]
    public var skipped: [ProjectStandardsSkipped]
    /// Fingerprint of the folder's listing (names, types, sizes, times,
    /// inodes, link targets). Changes whenever its contents do.
    public var version: String

    public init(standards: [ProjectStandard], issues: [ProjectStandardsIssue],
                skipped: [ProjectStandardsSkipped] = [], version: String = "") {
        self.standards = standards
        self.issues = issues
        self.skipped = skipped
        self.version = version
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
        var seen: Set<String> = []
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
                guard seen.insert(number).inserted else {
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

    /// One entry of the folder, from `lstat` alone: no file is read.
    struct Entry {
        let relative: String // under docs/standards
        let type: FileAttributeType
        let size: UInt64
        let modified: TimeInterval
        let inode: UInt64
        let links: Int
        let destination: String?
    }

    /// The folder's listing and its fingerprint. Reads names and attributes
    /// only, so a cache can tell whether anything changed without reading.
    struct Listing {
        let root: URL
        let folder: URL
        /// Set when the folder itself cannot be used (a symlink in its path).
        let folderIssue: ProjectStandardsIssue?
        let entries: [Entry]
        let version: String
    }

    static func listing(checkoutRoot: URL, fileManager: FileManager) -> Listing? {
        let root = URL(fileURLWithPath: checkoutRoot.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent(directory, isDirectory: true)
        // `lstat` and `readdir` straight from libc: a cached read pays this for
        // every file, and Foundation's attribute dictionaries cost about 50x more.
        let folderPath = folder.path
        func entry(_ relative: String) -> Entry? {
            let path = folderPath + "/" + relative
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            let type = Self.fileType(info.st_mode)
            return Entry(relative: relative, type: type,
                         size: UInt64(info.st_size),
                         modified: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9,
                         inode: UInt64(info.st_ino),
                         links: Int(info.st_nlink),
                         destination: type == .typeSymbolicLink ? try? fileManager.destinationOfSymbolicLink(atPath: path) : nil)
        }
        guard let folderAttributes = try? fileManager.attributesOfItem(atPath: folder.path),
              let folderType = folderAttributes[.type] as? FileAttributeType else { return nil }
        // The folder must BE root/docs/standards: no symlink at docs or below.
        let resolvedFolder = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if folderType == .typeSymbolicLink || resolvedFolder != folder.path {
            let issue = ProjectStandardsIssue(path: directory, code: .symlinkedFolder,
                                              message: "docs/standards (or docs) is a symlink; standards are read only from the real folder.")
            return Listing(root: root, folder: folder, folderIssue: issue, entries: [],
                           version: version(of: Data("symlinked:\(resolvedFolder)".utf8)))
        }
        guard folderType == .typeDirectory else { return nil }
        func names(_ path: String) -> [String] {
            guard let directory = opendir(path) else { return [] }
            defer { closedir(directory) }
            var found: [String] = []
            while let item = readdir(directory) {
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name != "." && name != ".." { found.append(name) }
            }
            return found.sorted()
        }
        var entries: [Entry] = []
        for name in names(folder.path) {
            guard let top = entry(name) else { continue }
            entries.append(top)
            if top.type == .typeDirectory {
                entries += names(folderPath + "/" + name).compactMap { entry(name + "/" + $0) }
            }
        }
        // The fingerprint is bytes, not text: 10,000 formatted lines cost more than the stats.
        var fingerprint = Data()
        fingerprint.reserveCapacity(entries.count * 64)
        func add<T>(_ value: T) { withUnsafeBytes(of: value) { fingerprint.append(contentsOf: $0) } }
        for entry in entries {
            fingerprint.append(contentsOf: entry.relative.utf8); add(UInt8(0))
            fingerprint.append(contentsOf: entry.type.rawValue.utf8); add(UInt8(0))
            add(entry.size); add(entry.modified.bitPattern); add(entry.inode); add(entry.links)
            fingerprint.append(contentsOf: (entry.destination ?? "").utf8); add(UInt8(10))
        }
        return Listing(root: root, folder: folder, folderIssue: nil, entries: entries, version: version(of: fingerprint))
    }

    private static func fileType(_ mode: mode_t) -> FileAttributeType {
        switch mode & S_IFMT {
        case S_IFREG: return .typeRegular
        case S_IFDIR: return .typeDirectory
        case S_IFLNK: return .typeSymbolicLink
        case S_IFCHR: return .typeCharacterSpecial
        case S_IFBLK: return .typeBlockSpecial
        case S_IFSOCK: return .typeSocket
        default: return .typeUnknown
        }
    }

    /// Every standard in `checkoutRoot/docs/standards`, one folder deep. nil
    /// when the folder does not exist. Reads only regular files whose resolved
    /// path is inside the resolved folder; everything else is an issue or a
    /// skipped entry, named.
    public static func scan(checkoutRoot: URL, fileManager: FileManager = .default) -> ProjectStandardsIndex? {
        guard let listing = listing(checkoutRoot: checkoutRoot, fileManager: fileManager) else { return nil }
        return index(from: listing, fileManager: fileManager)
    }

    static func index(from listing: Listing, fileManager: FileManager) -> ProjectStandardsIndex {
        if let issue = listing.folderIssue {
            return ProjectStandardsIndex(standards: [], issues: [issue], version: listing.version)
        }
        var standards: [ProjectStandard] = []
        var issues: [ProjectStandardsIssue] = []
        var skipped: [ProjectStandardsSkipped] = []
        let folderPath = listing.folder.path
        for entry in listing.entries {
            let path = directory + "/" + entry.relative
            let depth = entry.relative.split(separator: "/").count
            func issue(_ code: ProjectStandardsIssue.Code, _ message: String) {
                issues.append(ProjectStandardsIssue(path: path, code: code, message: message))
            }
            if entry.type == .typeDirectory {
                if depth > 1 { skipped.append(ProjectStandardsSkipped(path: path, reason: .nestedFolder)) }
                continue
            }
            let isMarkdown = entry.relative.hasSuffix(".md")
            if entry.type == .typeSymbolicLink, depth == 1, !isMarkdown {
                // A symlinked subfolder is refused; any other non-.md link is not a candidate.
                var isFolder: ObjCBool = false
                if fileManager.fileExists(atPath: listing.folder.appendingPathComponent(entry.relative).path, isDirectory: &isFolder),
                   isFolder.boolValue {
                    issue(.symlinkedFolder, "A symlinked folder; standards are read only from real folders.")
                }
                continue
            }
            guard isMarkdown else { continue }
            if (entry.relative as NSString).lastPathComponent == readmeName {
                skipped.append(ProjectStandardsSkipped(path: path, reason: .indexFile))
                continue
            }
            var readPath = listing.folder.appendingPathComponent(entry.relative).path
            var type = entry.type
            var links = entry.links
            if type == .typeSymbolicLink {
                let resolved = URL(fileURLWithPath: readPath).standardizedFileURL.resolvingSymlinksInPath()
                guard fileManager.fileExists(atPath: readPath),
                      let target = try? fileManager.attributesOfItem(atPath: resolved.path),
                      let targetType = target[.type] as? FileAttributeType, targetType != .typeSymbolicLink else {
                    issue(.brokenLink, "A symlink to nothing.")
                    continue
                }
                guard AgentLocalFileLinkResolver.isContained(resolved, in: URL(fileURLWithPath: folderPath, isDirectory: true)) else {
                    issue(.outsideStandards, "A symlink to a file outside docs/standards; not read.")
                    continue
                }
                readPath = resolved.path
                type = targetType
                links = (target[.referenceCount] as? NSNumber)?.intValue ?? 1
            }
            guard type == .typeRegular else {
                issue(.notRegularFile, "Not a regular file; not read.")
                continue
            }
            guard links <= 1 else {
                issue(.hardLink, "Hard-linked to another path (\(links) links); not read.")
                continue
            }
            guard let data = fileManager.contents(atPath: readPath) else {
                issue(.unreadable, "Could not be read.")
                continue
            }
            switch parse(id: String(entry.relative.dropLast(3)), path: path, data: data) {
            case .notAStandard: skipped.append(ProjectStandardsSkipped(path: path, reason: .notAStandard))
            case .standard(let standard): standards.append(standard)
            case .failed(let found): issues += found
            }
        }
        return ProjectStandardsIndex(standards: standards.sorted { $0.id < $1.id },
                                     issues: issues.sorted { ($0.path, $0.line ?? 0) < ($1.path, $1.line ?? 0) },
                                     skipped: skipped.sorted { $0.path < $1.path },
                                     version: listing.version)
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

/// Parsed indexes by checkout, kept until the folder's listing fingerprint
/// changes. Thread-safe: `standards.read` scans off the main actor.
public final class ProjectStandardsCache: @unchecked Sendable {
    public static let shared = ProjectStandardsCache()
    private let lock = NSLock()
    private var indexes: [String: ProjectStandardsIndex] = [:]

    public init() {}

    /// The checkout's index: re-read only when the listing changed. nil when
    /// there is no `docs/standards`.
    public func index(checkoutRoot: URL, fileManager: FileManager = .default) -> ProjectStandardsIndex? {
        guard let listing = ProjectStandards.listing(checkoutRoot: checkoutRoot, fileManager: fileManager) else {
            lock.withLock { indexes[checkoutRoot.path] = nil }
            return nil
        }
        if let cached = lock.withLock({ indexes[listing.root.path] }), cached.version == listing.version { return cached }
        let index = ProjectStandards.index(from: listing, fileManager: fileManager)
        lock.withLock { indexes[listing.root.path] = index }
        return index
    }
}
