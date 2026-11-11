import Foundation
import ContinuumRevivedCore

/// The result of the last read, shown beside the setting. Never blocks a launch.
enum HostInstructionOutcome: Equatable, Sendable {
    case loaded(words: Int), missing, unreadable, empty, tooLarge, invalidText

    var summary: String {
        switch self {
        case .loaded(let words): return "Loaded at the last launch: \(words) word\(words == 1 ? "" : "s")."
        case .missing: return "File not found at the last launch, so no rules were added."
        case .unreadable: return "Array could not read the file at the last launch, so no rules were added."
        case .empty: return "The file was empty at the last launch, so no rules were added."
        case .tooLarge: return "The file is over 64 KB, so no rules were added."
        case .invalidText: return "The file is not plain UTF-8 text, so no rules were added."
        }
    }
}

/// The user's own rules file. Read-only; never consults CLI homes or memory.
/// The file is read when a Codex or Pi process is launched, never earlier, so
/// an edit reaches the next launch.
final class PersonalRulesSource: HostLaunchInstructionSource, @unchecked Sendable {
    static let byteLimit = 65_536
    /// Checks never read the user's settings or files through this.
    static let shared = PersonalRulesSource { productionPath(defaults: .standard) }
    static func productionPath(defaults: UserDefaults) -> String? {
        CheckFocusGuard.isQARun() ? nil : PersonalRulesConfig.selectedPath(defaults: defaults)
    }
    private let selectedPath: @Sendable () -> String?
    private let lock = NSLock()
    private var outcome: HostInstructionOutcome?

    /// `selectedPath` returns the file to read, or nil when the feature is off.
    init(selectedPath: @escaping @Sendable () -> String?) {
        self.selectedPath = selectedPath
    }

    var lastOutcome: HostInstructionOutcome? { lock.withLock { outcome } }

    /// One bounded read (at most `byteLimit + 1` bytes) on the calling thread:
    /// the runner's launch thread, never the main thread.
    func resolveBlock() -> HostLaunchInstructionBlock? {
        guard let path = selectedPath() else { return nil }
        let (text, result) = Self.read(path)
        lock.withLock { outcome = result }
        return text.map { HostLaunchInstructionBlock(name: "personal-rules", label: "Personal working rules", text: $0) }
    }

    static func read(_ path: String) -> (String?, HostInstructionOutcome) {
        guard FileManager.default.fileExists(atPath: path) else { return (nil, .missing) }
        guard let file = FileHandle(forReadingAtPath: path),
              let bytes = try? file.read(upToCount: byteLimit + 1) ?? Data() else { return (nil, .unreadable) }
        try? file.close()
        if bytes.count > byteLimit { return (nil, .tooLarge) }
        // A NUL cannot travel in an argv string.
        guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else { return (nil, .invalidText) }
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return words == 0 ? (nil, .empty) : (text, .loaded(words: words))
    }
}

/// Each layer retains its own bytes and identity. Only argv rendering joins them.
struct HostLaunchInstructionBlock: Sendable, Equatable {
    let name: String
    let label: String
    let text: String
}

protocol HostLaunchInstructionSource: Sendable {
    /// Called once per process launch, off the main thread.
    func resolveBlock() -> HostLaunchInstructionBlock?
    /// Whether Claude launches carry this block too. Personal rules do not:
    /// Claude Code already reads the user's own Claude instructions.
    var reachesClaude: Bool { get }
}

extension HostLaunchInstructionSource {
    var reachesClaude: Bool { false }
}

/// Array's reply rules (`ReplyStandard`), for every Array-run agent on every
/// harness. Static text; the switch is read at each launch, so a change
/// reaches the next launched process.
struct ReplyStandardSource: HostLaunchInstructionSource {
    /// Checks never read the user's settings through this.
    static let shared = ReplyStandardSource { productionEnabled(defaults: .standard) }
    static func productionEnabled(defaults: UserDefaults) -> Bool {
        !CheckFocusGuard.isQARun() && ReplyStandard.isEnabled(defaults: defaults)
    }
    let isEnabled: @Sendable () -> Bool
    var reachesClaude: Bool { true }

    func resolveBlock() -> HostLaunchInstructionBlock? {
        isEnabled() ? HostLaunchInstructionBlock(name: "reply-rules", label: ReplyStandard.label, text: ReplyStandard.text) : nil
    }
}

/// The single host-owned launch seam for Codex and Pi. Sources stay separate;
/// one option per harness is rendered at launch, in this fixed order:
/// 1. the user's own Codex `developer_instructions` (Codex only),
/// 2. instruction text Array already passes in the runner's extra arguments,
/// 3. each source's block in registration order: Array's reply rules, then
///    the user's personal rules (the more specific layer comes last).
/// Codex gets one `-c developer_instructions=…` (a repeated key replaces the
/// earlier one); Pi gets one `--append-system-prompt`. Claude gets only the
/// blocks that reach it, joined into its one `--append-system-prompt`.
struct HostLaunchInstructions: Sendable {
    static let shared = production(reply: .shared, personal: .shared)
    /// The production order, shared with the checks that witness it.
    static func production(reply: ReplyStandardSource, personal: PersonalRulesSource) -> HostLaunchInstructions {
        HostLaunchInstructions(sources: [reply, personal])
    }
    let sources: [any HostLaunchInstructionSource]
    /// Reads the user's own Codex setting, read-only. Injected in checks.
    var codexUserInstructions: @Sendable (_ codexHome: String?, _ cwd: URL) -> CodexUserInstructions = {
        CodexUserInstructions.read(codexHome: $0, cwd: $1)
    }
    /// Why the last Codex launch went without host text, if it did.
    let codexNote = LaunchNote()

    final class LaunchNote: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        var value: String? { lock.withLock { text } }
        func set(_ value: String?) { lock.withLock { text = value } }
    }

    func blocks() -> [HostLaunchInstructionBlock] {
        var names = Set<String>()
        return sources.compactMap { $0.resolveBlock() }.filter { names.insert($0.name).inserted }
    }

    func codexArguments(_ config: CodexAgentRunner.Config) -> [String] {
        let blocks = blocks()
        guard !blocks.isEmpty else { return config.extraArgs }
        let userText: String?
        switch codexUserInstructions(config.codexHome, config.cwd) {
        case .unknown(let reason):
            codexNote.set("Not added to Codex: " + reason)
            return config.extraArgs
        case .none: userText = nil
        case .text(let own): userText = own
        }
        let arguments = Self.render(blocks, codex: true, existingArguments: config.extraArgs, userText: userText)
        // With blocks to add, `render` leaves the arguments as they were only
        // when instruction text already in them cannot be decoded.
        codexNote.set(arguments == config.extraArgs
            ? "Not added to Codex: instructions already set for this launch could not be read" : nil)
        return arguments
    }

    func piArguments(_ config: PiAgentRunner.Config) -> [String] {
        Self.render(blocks(), codex: false, existingArguments: config.extraArgs)
    }

    /// Claude's host text for this launch, or nil. The runner joins it with
    /// Array's workspace guidance into one `--append-system-prompt`.
    func claudeText() -> String? {
        var names = Set<String>()
        let blocks = sources.filter(\.reachesClaude).compactMap { $0.resolveBlock() }.filter { names.insert($0.name).inserted }
        let text = Self.joined(blocks)
        return text.isEmpty ? nil : text
    }

    static func joined(_ blocks: [HostLaunchInstructionBlock]) -> String {
        blocks.map { $0.label + ":\n" + $0.text }.joined(separator: "\n\n")
    }

    /// Pure: joins existing instruction text and the blocks into one option.
    static func render(_ blocks: [HostLaunchInstructionBlock], codex: Bool,
                       existingArguments: [String] = [], userText: String? = nil) -> [String] {
        let rendered = joined(blocks)
        guard !rendered.isEmpty else { return existingArguments }
        var remaining: [String] = []
        var existingText: [String] = userText.map { [$0] } ?? []
        var index = 0
        var insertionIndex: Int?
        while index < existingArguments.count {
            let flag = existingArguments[index]
            if index + 1 < existingArguments.count {
                let value = existingArguments[index + 1]
                let text: String?
                if codex && ["-c", "--config"].contains(flag) && value.hasPrefix("developer_instructions=") {
                    // Array-owned overrides are TOML basic strings.
                    guard let decoded = TOMLString.decodeBasic(Substring(value.dropFirst("developer_instructions=".count))) else {
                        // Never replace an existing value we cannot safely compose.
                        return existingArguments
                    }
                    text = decoded
                } else if !codex && flag == "--append-system-prompt" { text = value }
                else { text = nil }
                if let text {
                    insertionIndex = insertionIndex ?? remaining.count
                    existingText.append(text)
                    index += 2
                    continue
                }
            }
            remaining.append(flag)
            index += 1
        }
        let combined = (existingText + [rendered]).joined(separator: "\n\n")
        let injection = codex
            ? ["-c", "developer_instructions=" + TOMLString.basic(combined)]
            : ["--append-system-prompt", combined]
        remaining.insert(contentsOf: injection, at: insertionIndex ?? remaining.count)
        return remaining
    }
}

/// TOML basic strings: every control byte escaped, everything else verbatim.
enum TOMLString {
    static func basic(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// Decodes exactly one `"…"` basic string with nothing after it, or nil.
    static func decodeBasic(_ quoted: Substring) -> String? {
        guard quoted.hasPrefix("\""), let (text, rest) = scanBasic(quoted.dropFirst(), multiline: false),
              rest.isEmpty else { return nil }
        return text
    }

    /// Scans a basic-string body up to its closing delimiter; returns the
    /// decoded text and what follows the delimiter. nil for anything invalid,
    /// including a line-ending backslash (not supported here).
    static func scanBasic(_ body: Substring, multiline: Bool) -> (String, Substring)? {
        var out = String.UnicodeScalarView()
        var scalars = body.unicodeScalars[...]
        let close = multiline ? "\"\"\"" : "\""
        while let scalar = scalars.first {
            if String(String.UnicodeScalarView(scalars.prefix(close.unicodeScalars.count))) == close {
                let rest = Substring(String(String.UnicodeScalarView(scalars.dropFirst(close.unicodeScalars.count))))
                if multiline && rest.hasPrefix("\"") { return nil }
                return (String(out), rest)
            }
            scalars = scalars.dropFirst()
            if scalar == "\\" {
                guard let escape = scalars.first else { return nil }
                scalars = scalars.dropFirst()
                let simple: [Unicode.Scalar: Unicode.Scalar] = ["b": "\u{08}", "t": "\t", "n": "\n", "f": "\u{0C}",
                                                                "r": "\r", "e": "\u{1B}", "\"": "\"", "\\": "\\"]
                if let mapped = simple[escape] { out.append(mapped); continue }
                let width: Int
                switch escape { case "u": width = 4; case "U": width = 8; case "x": width = 2; default: return nil }
                let hex = String(String.UnicodeScalarView(scalars.prefix(width)))
                guard hex.count == width, let value = UInt32(hex, radix: 16),
                      let decoded = Unicode.Scalar(value) else { return nil }
                out.append(decoded)
                scalars = scalars.dropFirst(width)
                continue
            }
            let allowedNewline = multiline && (scalar == "\n" || scalar == "\r")
            if (scalar.value < 0x20 && scalar != "\t" && !allowedNewline) || scalar.value == 0x7F { return nil }
            out.append(scalar)
        }
        return nil
    }
}

/// The user's own `developer_instructions` for Codex, read without writing.
/// `-c developer_instructions=…` replaces that key for the launch, and Codex
/// 0.167 has no per-launch option that adds to it instead, so Array joins the
/// user's value first. If it cannot be read with confidence, Array passes no
/// host text to that launch.
enum CodexUserInstructions: Equatable, Sendable {
    case none
    case text(String)
    case unknown(String)

    static let fileLimit = 1 << 20
    static let key = "developer_instructions"

    static func read(codexHome: String?, cwd: URL,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> CodexUserInstructions {
        let home = codexHome.flatMap { $0.isEmpty ? nil : $0 } ?? environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? homeDirectory.appendingPathComponent(".codex").path
        let userFile = URL(fileURLWithPath: home).appendingPathComponent("config.toml").standardizedFileURL.path
        // Other layers Codex may read. A key there makes the effective value
        // uncertain, so Array leaves that launch alone.
        var layers = ["/etc/codex/config.toml"]
        var directory = cwd.standardizedFileURL.path as NSString
        while true {
            layers.append(directory.appendingPathComponent(".codex/config.toml"))
            guard directory.length > 1 else { break }
            directory = directory.deletingLastPathComponent as NSString
        }
        for layer in layers where layer != userFile && FileManager.default.fileExists(atPath: layer) {
            guard let text = contents(layer) else { return .unknown("a Codex config file could not be read") }
            if text.contains(key) { return .unknown("a project or system Codex config sets developer_instructions") }
        }
        guard FileManager.default.fileExists(atPath: userFile) else { return .none }
        guard let text = contents(userFile) else { return .unknown("your Codex config could not be read") }
        return parse(text)
    }

    private static func contents(_ path: String) -> String? {
        guard let file = FileHandle(forReadingAtPath: path),
              let data = try? file.read(upToCount: fileLimit + 1), data.count <= fileLimit else { return nil }
        try? file.close()
        return String(data: data, encoding: .utf8)
    }

    /// Accepts only a top-level `developer_instructions = <string>`; any other
    /// mention (a table, a profile, a dotted or quoted key) is `.unknown`.
    static func parse(_ text: String) -> CodexUserInstructions {
        let unsure = CodexUserInstructions.unknown("your Codex config sets developer_instructions in a form Array cannot read")
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var found: String?
        var inTable = false
        var skipUntil: String?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            if let delimiter = skipUntil {
                if line.contains(delimiter) { skipUntil = nil }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            if trimmed.hasPrefix("[") { inTable = true }
            let keyPrefix = trimmed.hasPrefix(key) ? trimmed.dropFirst(key.count).drop(while: { $0 == " " || $0 == "\t" }) : nil
            if !inTable, let afterKey = keyPrefix, afterKey.hasPrefix("=") {
                guard found == nil else { return unsure }
                let value = afterKey.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
                guard let (parsed, consumed) = parseValue(value, following: lines[index...]) else { return unsure }
                found = parsed
                index += consumed
                continue
            }
            if trimmed.contains(key) { return unsure }
            // Step over another key's multi-line string so its lines are not read as keys.
            for delimiter in ["\"\"\"", "'''"] where line.components(separatedBy: delimiter).count == 2 {
                skipUntil = delimiter
            }
        }
        return found.map { .text($0) } ?? .none
    }

    /// Parses a string value; returns it and how many following lines it used.
    private static func parseValue(_ value: Substring, following: ArraySlice<String>) -> (String, Int)? {
        func onlyComment(_ rest: Substring) -> Bool {
            let tail = rest.trimmingCharacters(in: .whitespaces)
            return tail.isEmpty || tail.hasPrefix("#")
        }
        for (delimiter, literal) in [("\"\"\"", false), ("'''", true)] where value.hasPrefix(delimiter) {
            var body = String(value.dropFirst(3))
            var used = 0
            var lines = following.makeIterator()
            while !body.contains(delimiter) {
                guard let next = lines.next() else { return nil }
                body += "\n" + next
                used += 1
            }
            // A newline right after the opening delimiter is trimmed.
            if body.hasPrefix("\n") { body.removeFirst() }
            if literal {
                guard let range = body.range(of: delimiter) else { return nil }
                let rest = body[range.upperBound...]
                guard !rest.hasPrefix("'"), onlyComment(rest) else { return nil }
                return (String(body[..<range.lowerBound]), used)
            }
            if body.range(of: #"\\[ \t]*\n"#, options: .regularExpression) != nil { return nil }
            guard let (text, rest) = TOMLString.scanBasic(Substring(body), multiline: true), onlyComment(rest) else { return nil }
            return (text, used)
        }
        if value.hasPrefix("\"") {
            guard let (text, rest) = TOMLString.scanBasic(value.dropFirst(), multiline: false), onlyComment(rest) else { return nil }
            return (text, 0)
        }
        if value.hasPrefix("'") {
            let body = value.dropFirst()
            guard let end = body.firstIndex(of: "'"), onlyComment(body[body.index(after: end)...]) else { return nil }
            return (String(body[..<end]), 0)
        }
        return nil
    }
}
