import Foundation

/// Technical-speech support for dictation. Platform-neutral on purpose: the
/// recogniser is fed `DictationVocabulary.assemble(...)` as contextual strings,
/// and its output passes through `DictationNormalizer`, both of which a check can
/// drive without a microphone or the `Speech` framework.
public enum DictationVocabulary {
    /// Hard bound on what the recogniser is given. Contextual strings are
    /// loaded into the language model per session, so this stays small.
    public static let termLimit = 300
    public static let maxTermLength = 48

    /// Tools, models and jargon Dylan actually says. Order is irrelevant; live
    /// context outranks these when the cap bites.
    public static let baseTerms: [String] = [
        "Claude Code", "Codex", "Opus", "Sonnet", "Haiku", "Fable", "Anthropic", "OpenAI",
        "SwiftPM", "Xcode", "SwiftUI", "AppKit", "Swift", "GitHub", "Vercel", "Astro", "Sparkle",
        "tmux", "Ghostty", "GhosttyKit", "AVAudioEngine", "SpeechAnalyzer", "CloudKit", "CoreAnimation",
        "worktree", "git rebase", "cherry-pick", "origin/main", "array/integration", "main",
        "pull request", "PR", "CLI", "MCP", "API", "JSON", "TypeScript", "JavaScript", "npm", "pnpm",
        "refactor", "regex", "async", "await", "enum", "struct", "protocol", "closure", "subagent",
        "canvas", "tile", "zone", "composer", "transcript", "matrix", "witness", "dev server",
        "localhost", "stdout", "stderr", "sudo", "grep", "Dockerfile", "YAML", "OAuth", "SDK",
        "plist", "Info.plist", "Package.swift", "CLAUDE.md", "README.md", ".swift", ".ts", ".json",
    ]

    /// `dynamic` is ordered most-relevant first (agent and branch names, then
    /// file stems). Deduplicates case-insensitively, drops junk and over-long
    /// terms, appends the base list and caps the result.
    public static func assemble(dynamic: [String], limit: Int = termLimit) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in dynamic + baseTerms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 2, term.count <= maxTermLength else { continue }
            guard seen.insert(term.lowercased()).inserted else { continue }
            out.append(term)
            if out.count >= limit { break }
        }
        return out
    }

    /// File stems that look like identifiers (`DictationSession.swift` →
    /// `DictationSession`), bounded and deduplicated. Plain lowercase words are
    /// dropped: the recogniser already knows them, and they would crowd out names.
    public static func identifierStems(fromFileNames names: [String], limit: Int = 120) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in names {
            let stem = (name as NSString).deletingPathExtension
            guard stem.count >= 4, stem.contains(where: \.isUppercase) || stem.contains("-") || stem.contains("_") else { continue }
            guard seen.insert(stem.lowercased()).inserted else { continue }
            out.append(stem)
            if out.count >= limit { break }
        }
        return out
    }
}

/// Conservative post-recognition fixes. Every rule is a whole-phrase,
/// case-insensitive match that is unambiguous in technical speech; anything
/// that could change ordinary prose is left alone.
public struct DictationNormalizer: Sendable {
    private let rules: [(regex: NSRegularExpression, template: String)]

    /// Spoken forms the recogniser reliably splits wrongly.
    private static let fixedAliases: [(spoken: String, written: String)] = [
        ("x code", "Xcode"), ("swift p m", "SwiftPM"), ("swift pm", "SwiftPM"),
        ("git hub", "GitHub"), ("get hub", "GitHub"), ("swift ui", "SwiftUI"),
    ]

    private static let extensions = [
        "swift", "ts", "tsx", "js", "jsx", "json", "md", "py", "rs", "go", "yml", "yaml",
        "plist", "sh", "html", "css", "txt", "toml",
    ]

    public init(terms: [String]) {
        var rules: [(NSRegularExpression, String)] = []
        func add(_ pattern: String, _ template: String) {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                rules.append((regex, template))
            }
        }
        // "foo dot swift" / "foo dot.swift" -> "foo.swift", only after a word
        // and only for a known extension.
        let exts = Self.extensions.joined(separator: "|")
        add("(?<=\\w)\\s*\\bdot[ .](\(exts))\\b", ".$1")
        for (spoken, written) in Self.fixedAliases {
            add(Self.phrasePattern(spoken), NSRegularExpression.escapedTemplate(for: written))
        }
        // A camel/Pascal identifier of two or more words, spoken as words:
        // "dictation session" -> "DictationSession". Single words are left alone.
        for term in terms where !term.contains(" ") {
            let words = Self.splitIdentifier(term)
            guard words.count >= 2 else { continue }
            add(Self.phrasePattern(words.joined(separator: " ")), NSRegularExpression.escapedTemplate(for: term))
        }
        self.rules = rules
    }

    public func normalize(_ text: String) -> String {
        var result = text
        for (regex, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    private static func phrasePattern(_ phrase: String) -> String {
        let body = phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
        return "(?<![\\w])\(body)(?![\\w])"
    }

    /// `AVAudioEngine` -> [AV, Audio, Engine]; `ContinuumRevivedCore` ->
    /// [Continuum, Revived, Core]. Only letters split; digits and punctuation
    /// make the identifier ineligible (empty result).
    static func splitIdentifier(_ term: String) -> [String] {
        let chars = Array(term)
        guard chars.allSatisfy({ $0.isLetter }), chars.contains(where: \.isUppercase),
              chars.contains(where: \.isLowercase) else { return [] }
        var words: [String] = []
        var current = ""
        for (i, c) in chars.enumerated() {
            if c.isUppercase, !current.isEmpty {
                let prevUpper = chars[i - 1].isUppercase
                let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if !prevUpper || nextLower {
                    words.append(current)
                    current = ""
                }
            }
            current.append(c)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

/// Cheap, bounded scan of the files near an agent, cached per root so a press
/// never waits on the disk. The first call returns whatever is cached (nothing)
/// and refreshes in the background; later presses see the result.
public final class DictationFileTermCache: @unchecked Sendable {
    public static let shared = DictationFileTermCache()
    private let lock = NSLock()
    private var entries: [String: (terms: [String], at: Date)] = [:]
    private var scanning = Set<String>()
    private static let maxEntriesVisited = 6000
    private static let lifetime: TimeInterval = 300
    private static let skipped: Set<String> = [".git", ".build", "node_modules", ".worktrees", "qa-runs", "DerivedData", "Pods", ".array"]

    public init() {}

    public func terms(forRoot root: URL) -> [String] {
        let key = root.standardizedFileURL.path
        lock.lock()
        let entry = entries[key]
        let stale = entry.map { Date().timeIntervalSince($0.at) > Self.lifetime } ?? true
        let shouldScan = stale && !scanning.contains(key)
        if shouldScan { scanning.insert(key) }
        lock.unlock()
        if shouldScan {
            DispatchQueue.global(qos: .utility).async { [self] in
                let terms = Self.scan(root: root)
                lock.lock()
                entries[key] = (terms, Date())
                scanning.remove(key)
                lock.unlock()
            }
        }
        return entry?.terms ?? []
    }

    static func scan(root: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var names: [String] = []
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > maxEntriesVisited { break }
            if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            names.append(url.lastPathComponent)
        }
        return DictationVocabulary.identifierStems(fromFileNames: names)
    }
}
