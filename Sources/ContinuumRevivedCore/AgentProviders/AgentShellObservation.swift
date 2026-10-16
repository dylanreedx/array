import ContinuumRevivedAgentContent
import Foundation

/// Launch polish, item J — the provider-specific halves of reading one shell
/// command, shared by the three translators so each harness's quirks live in
/// one place:
///
/// - Codex sends `command` already wrapped in a login shell, as a joined
///   string (`/bin/zsh -lc '…'`) or, on older builds, as an argv array.
/// - Claude reports a non-zero exit only as an "Exit code N" first line of the
///   tool_result, and timeouts/backgrounding/interrupts in `tool_use_result`.
/// - Pi appends its own status line ("Command exited with code N", "Command
///   timed out after N seconds", "Command aborted") to the result text.
///
/// Everything here produces host-local observation values only (see
/// `AgentToolDetailObservation`); none of it reaches an `AgentRuntimeEvent`.
enum AgentShellObservation {
    static func isShellTool(_ name: String) -> Bool {
        AgentToolKind.resolve(toolName: name) == .shell
    }

    /// The `command` detail field from a provider's raw command value, wrapper
    /// removed. Newlines and tabs survive (a command can be a script); every
    /// other control character is dropped.
    static func commandField(_ raw: Any?) -> (key: String, value: String)? {
        let command: String
        if let string = raw as? String {
            command = AgentShellInvocation.unwrapShellWrapper(string)
        } else if let argv = raw as? [String], !argv.isEmpty {
            command = AgentShellInvocation.unwrapShellWrapper(argv: argv)
        } else {
            return nil
        }
        let cleaned = String(String.UnicodeScalarView(command.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        // Redacted HERE, before it enters any observation, not only later in
        // the store: `deploy --token abc` must never exist on this channel.
        return (key: AgentToolDetailObservation.shellCommandKey, value: SecretRedactor.redact(cleaned))
    }

    /// The `cwd` detail field, only when the command ran somewhere other than
    /// the agent's home — and then as a path relative to that home, or the last
    /// two components, never a full machine path.
    static func cwdField(_ raw: String?, home: URL?) -> (key: String, value: String)? {
        guard let raw, !raw.isEmpty, (raw as NSString).isAbsolutePath,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let cwd = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.pathComponents
        if let home {
            let base = home.standardizedFileURL.pathComponents
            if cwd == base { return nil }
            if cwd.count > base.count, Array(cwd.prefix(base.count)) == base {
                return (key: AgentToolDetailObservation.shellCwdKey,
                        value: cwd.dropFirst(base.count).joined(separator: "/"))
            }
        }
        let tail = cwd.filter { $0 != "/" }.suffix(2)
        guard !tail.isEmpty else { return nil }
        return (key: AgentToolDetailObservation.shellCwdKey, value: "…/" + tail.joined(separator: "/"))
    }

    struct ShellResult: Equatable {
        var output: String?
        var exitCode: Int?
        var outcome: AgentShellStatus?
    }

    /// Claude Code's Bash result. `content` is the tool_result text the model
    /// saw; `toolUseResult` is the frame's `tool_use_result` (an object with
    /// `stdout`/`stderr`/`interrupted`/`backgroundTaskId`/`timedOutAfterMs`, or
    /// an error string).
    static func claudeResult(content: String?, isError: Bool, toolUseResult: Any?) -> ShellResult {
        var result = ShellResult(output: content)
        if isError, let content {
            let lines = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let first = String(lines.first ?? "").trimmingCharacters(in: .whitespaces)
            if let code = leadingExitCode(first) {
                result.exitCode = code
                let rest = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                result.output = rest.isEmpty ? nil : rest
            }
        }
        if let details = toolUseResult as? [String: Any] {
            if (details["interrupted"] as? Bool) == true {
                result.outcome = .interrupted
            } else if details["timedOutAfterMs"] is NSNumber {
                result.outcome = .timedOut
            } else if let background = details["backgroundTaskId"] as? String, !background.isEmpty {
                result.outcome = .backgrounded
            }
        }
        return result
    }

    /// "Exit code 2" / "Error: Exit code 2" → 2.
    private static func leadingExitCode(_ line: String) -> Int? {
        var text = Substring(line)
        if text.hasPrefix("Error: ") { text = text.dropFirst("Error: ".count) }
        guard text.hasPrefix("Exit code ") else { return nil }
        return Int(text.dropFirst("Exit code ".count).trimmingCharacters(in: .whitespaces))
    }

    /// Pi's bash result: its own status line is the last line of the text.
    static func piResult(text: String?) -> ShellResult {
        guard let text else { return ShellResult() }
        var lines = text.components(separatedBy: "\n")
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces) else { return ShellResult(output: text) }
        var result = ShellResult()
        if last.hasPrefix("Command exited with code "),
           let code = Int(last.dropFirst("Command exited with code ".count)) {
            result.exitCode = code
        } else if last.hasPrefix("Command timed out after ") {
            result.outcome = .timedOut
        } else if last == "Command aborted" {
            result.outcome = .interrupted
        } else {
            return ShellResult(output: text)
        }
        lines.removeLast()
        let rest = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        result.output = rest.isEmpty ? nil : rest
        return result
    }
}
