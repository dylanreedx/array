import Foundation

/// Where one shell command stands. Richer than `AgentItemStatus` on purpose: a
/// command that timed out, or that its harness moved to the background, is not
/// the same fact as one that failed or one that is still running, and the row
/// says each one differently.
public enum AgentShellStatus: String, Equatable, Sendable {
    case running
    case succeeded
    case failed
    case timedOut
    case interrupted
    case backgrounded
}

/// One shell command an agent ran, normalised across Claude Code, Codex and Pi.
///
/// The three harnesses describe the same act three ways: Codex sends the
/// command already wrapped in a login shell (`/bin/zsh -lc '…'`, or as an argv
/// array on older builds) with an integer exit code and its own measured
/// duration; Claude sends a bare `command` with an optional human
/// `description`, and reports failure as an "Exit code N" line at the top of
/// the result; Pi sends a bare `command` and appends "Command exited with code
/// N" to the result. Translators reduce each to this one shape so the row has
/// a single thing to draw.
///
/// PRESENTATION ONLY. This never enters the semantic document's Codable shape
/// (see `AgentToolCallPayload.presentedShell`): a command body and its output
/// are host-local detail, and the document crosses a sync boundary (I5).
public struct AgentShellInvocation: Equatable, Sendable {
    /// The command as the user would have typed it, wrapper removed.
    public var command: String
    /// Claude's model-authored one-line summary, when it supplied one.
    public var description: String?
    /// Display form of the working directory, present only when it differs
    /// from the agent's own home (translators decide; they know the home).
    public var cwd: String?
    public var output: String?
    public var exitCode: Int?
    /// Seconds. Nil when no real measurement exists.
    public var duration: TimeInterval?
    public var status: AgentShellStatus

    public init(
        command: String,
        description: String? = nil,
        cwd: String? = nil,
        output: String? = nil,
        exitCode: Int? = nil,
        duration: TimeInterval? = nil,
        status: AgentShellStatus
    ) {
        self.command = command
        self.description = description
        self.cwd = cwd
        self.output = output
        self.exitCode = exitCode
        self.duration = duration
        self.status = status
    }

    // MARK: - What the row shows

    /// The collapsed headline: the command's first line, bounded. A command
    /// that continues past its first line says so with a trailing ellipsis
    /// rather than silently stopping.
    public var headline: String {
        let lines = command.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var first = lines.first else { return "" }
        first = first.replacingOccurrences(of: "\t", with: " ")
        var truncated = lines.count > 1
        if first.count > Self.maxHeadlineCharacters {
            first = String(first.prefix(Self.maxHeadlineCharacters))
            truncated = true
        }
        return truncated ? first + " …" : first
    }

    /// The trailing badge. Nothing at all on success — an exit status of zero
    /// is the expected outcome and printing it is noise.
    public var badgeText: String? {
        switch status {
        case .failed:
            guard let exitCode, exitCode != 0 else { return nil }
            return "exit \(exitCode)"
        case .timedOut: return "timed out"
        case .interrupted: return "interrupted"
        case .backgrounded: return "background"
        case .running, .succeeded: return nil
        }
    }

    /// Whether the row should pull the eye (the error token).
    public var needsAttention: Bool { status == .failed || status == .timedOut }

    /// The duration column, only when it is a real number worth reading. A
    /// span that would print as "0.0s" is not shown: it is either a command
    /// that took no measurable time or two events that arrived together, and
    /// in neither case does "0.0s" tell the reader anything true.
    public var durationText: String? {
        guard let duration, duration.isFinite, duration >= 0.05 else { return nil }
        if duration < 10 { return String(format: "%.1fs", duration) }
        if duration < 60 { return "\(Int(duration.rounded()))s" }
        let total = Int(duration.rounded())
        return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s"
    }

    /// The expanded body: the whole command, then where it ran when that is
    /// somewhere other than the agent's home.
    public var disclosureText: String {
        var parts = [command.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let cwd, !cwd.isEmpty { parts.append("in \(cwd)") }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public static let maxHeadlineCharacters = 240

    // MARK: - Unwrapping the shell wrapper

    /// The shells whose `-c` wrapper is stripped. A wrapper around anything
    /// else is left alone: it might be the command.
    static let wrapperShells: Set<String> = ["bash", "zsh", "sh", "dash", "ksh"]

    /// `bash -lc 'git status'` → `git status`. Returns the input unchanged
    /// whenever it is not exactly one wrapper around exactly one shell word —
    /// an unterminated quote, extra positional arguments, or an unknown shell
    /// all mean "show what was sent", never a guess.
    public static func unwrapShellWrapper(_ raw: String) -> String {
        var current = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bounded: a wrapper inside a wrapper (`bash -lc "zsh -c '…'"`) peels
        // too, but a pathological input cannot loop.
        for _ in 0..<3 {
            guard let inner = unwrapOnce(current) else { break }
            current = inner
        }
        return current
    }

    /// The argv form older Codex builds send: `["bash", "-lc", "git status"]`.
    /// Any other argv is joined back into the line a person would type.
    public static func unwrapShellWrapper(argv: [String]) -> String {
        if argv.count == 3, isWrapperShell(argv[0]), isCommandFlag(argv[1]) {
            return unwrapShellWrapper(argv[2])
        }
        return argv.map(shellQuoted).joined(separator: " ")
    }

    private static func unwrapOnce(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        func skipSpaces() { while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" { index += 1 } }
        func bareWord() -> String {
            var word = String.UnicodeScalarView()
            while index < scalars.count, scalars[index] != " ", scalars[index] != "\t" {
                word.append(scalars[index]); index += 1
            }
            return String(word)
        }
        let shell = bareWord()
        guard isWrapperShell(shell) else { return nil }
        skipSpaces()
        guard isCommandFlag(bareWord()) else { return nil }
        skipSpaces()
        guard index < scalars.count, let script = shellWord(scalars, from: &index) else { return nil }
        skipSpaces()
        // A trailing positional (`sh -c 'cmd' name`) is part of the call; the
        // script alone would misreport it.
        guard index == scalars.count else { return nil }
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isWrapperShell(_ word: String) -> Bool {
        let name = word.split(separator: "/").last.map(String.init) ?? word
        return wrapperShells.contains(name)
    }

    /// `-c`, `-lc`, `-cl`, `-ic`, `-ilc`: single-dash letter clusters that
    /// include `c`.
    private static func isCommandFlag(_ word: String) -> Bool {
        guard word.hasPrefix("-"), !word.hasPrefix("--"), word.count >= 2 else { return false }
        let letters = word.dropFirst()
        return letters.contains("c") && letters.allSatisfy { $0.isLetter && $0.isASCII }
    }

    /// One POSIX shell word starting at `index`: unquoted text, `'…'` taken
    /// literally, `"…"` with its backslash escapes, adjacent pieces joined. Nil
    /// on an unterminated quote.
    private static func shellWord(_ scalars: [Unicode.Scalar], from index: inout Int) -> String? {
        var word = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case " ", "\t", "\n":
                return String(word)
            case "'":
                index += 1
                while index < scalars.count, scalars[index] != "'" { word.append(scalars[index]); index += 1 }
                guard index < scalars.count else { return nil }
                index += 1
            case "\"":
                index += 1
                var closed = false
                while index < scalars.count {
                    let inner = scalars[index]
                    if inner == "\"" { closed = true; index += 1; break }
                    if inner == "\\", index + 1 < scalars.count,
                       ["$", "`", "\"", "\\", "\n"].contains(scalars[index + 1]) {
                        if scalars[index + 1] != "\n" { word.append(scalars[index + 1]) }
                        index += 2
                        continue
                    }
                    word.append(inner); index += 1
                }
                guard closed else { return nil }
            case "\\":
                guard index + 1 < scalars.count else { return nil }
                if scalars[index + 1] != "\n" { word.append(scalars[index + 1]) }
                index += 2
            default:
                word.append(scalar); index += 1
            }
        }
        return String(word)
    }

    private static func shellQuoted(_ word: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
        guard word.isEmpty || word.unicodeScalars.contains(where: { !safe.contains($0) }) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
