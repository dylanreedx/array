import Foundation

/// A runner failure as a person reads it — "Codex exited without finishing
/// the turn: fatal: lost connection…" — never a Swift value such as
/// `appServerFailed(turn/completed not observed)`.
public protocol AgentRunFailureDescribing: Error {
    var userFacingDescription: String { get }
    /// The CLI process went away mid-turn (as opposed to the provider
    /// reporting a failure in-band).
    var isProcessLoss: Bool { get }
}

/// Bounded, redacted failure words from what a provider CLI actually said.
public enum AgentFailureText {
    /// The last few non-empty stderr lines, ANSI-stripped, redacted, bounded.
    /// stderr is the CLI's own diagnostic channel; it is the only place a
    /// crash says why.
    public static func stderrTail(_ stderr: String, maxLines: Int = 3, maxCharacters: Int = 400) -> String? {
        let lines = stripANSI(stderr)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let tail = lines.suffix(maxLines).joined(separator: "\n")
        return bounded(SecretRedactor.redactLocalDiagnostics(tail), maxCharacters)
    }

    /// A provider's in-band error text, kept only when it reads as an API or
    /// account failure (status codes, auth, limits, connectivity). Anything
    /// else may quote tool output or model text, so the caller keeps its
    /// short code instead (I5).
    public static func providerMessage(_ raw: String?, maxCharacters: Int = 300) -> String? {
        guard let raw else { return nil }
        guard let line = stripANSI(raw)
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let lowered = line.lowercased()
        let markers = [
            "api error", "unauthorized", "forbidden", "authentication", "oauth", "/login",
            "invalid api key", "access token", "token expired", "token has expired",
            "rate limit", "rate_limit", "usage limit", "quota", "credit balance", "overloaded",
            "timed out", "timeout", "connection", "network", "econnreset", "unavailable",
            "status 4", "status 5", " 401", " 403", " 429", " 500", " 502", " 503", " 529",
            // The account cannot use the chosen model. pi (openai-codex) says
            // "The 'gpt-5.3-codex-spark' model is not supported when using
            // Codex with a ChatGPT account."; this read "error" until 0.7.27.
            "model is not supported", "not supported when using", "model_not_found",
            "model not found", "does not exist or you do not have access",
        ]
        let padded = " " + lowered
        // "401 Unauthorized…", "503 …": an HTTP status leading the line.
        let leadsWithStatus = lowered.count >= 3 && lowered.prefix(3).allSatisfy(\.isNumber)
            && (lowered.hasPrefix("4") || lowered.hasPrefix("5"))
        guard leadsWithStatus || markers.contains(where: { padded.contains($0) }) else { return nil }
        return bounded(SecretRedactor.redactLocalDiagnostics(line), maxCharacters)
    }

    /// Why a compaction did not happen, in words a person can act on — or nil
    /// when the provider's text is not safe or not useful to show.
    ///
    /// A provider refusing because there is nothing to compact yet is the
    /// common case, not a fault: pi answers a tiny session with
    /// `compaction_end.errorMessage` "Compaction failed: Nothing to compact
    /// (session too small)" (captured from pi 0.x rpc, 2026-10-13), and says
    /// "Already compacted" right after a boundary. Those map to fixed wording
    /// on every harness. Anything else is kept only when it reads as an API or
    /// account failure (`providerMessage`, I5), so model text never leaks in.
    public static func compactionReason(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()
        if ["nothing to compact", "not enough messages to compact", "no messages to compact",
            "session too small"].contains(where: lowered.contains) {
            return "Nothing to compact yet"
        }
        if lowered.contains("already compacted") {
            return "Nothing new since the last compaction"
        }
        // Drop the wrappers runners and providers put in front of the reason.
        var reason = Substring(raw)
        if let range = reason.range(of: "compaction failed:", options: .caseInsensitive) {
            reason = reason[range.upperBound...]
        }
        return providerMessage(String(reason).trimmingCharacters(in: .whitespaces))
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private static func bounded(_ text: String, _ maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "…"
    }
}

/// A bounded tail of a child's stderr, safe to append from a pipe handler.
public final class AgentStderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let capacity: Int

    public init(capacity: Int = 16_384) {
        self.capacity = capacity
    }

    public func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        if data.count > capacity { data.removeFirst(data.count - capacity) }
        lock.unlock()
    }

    /// Forget what earlier turns wrote, so a failure reports only its own.
    public func reset() {
        lock.lock()
        data.removeAll()
        lock.unlock()
    }

    public var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    /// `AgentFailureText.stderrTail` of what has been captured.
    public var summary: String? { AgentFailureText.stderrTail(text) }
}

/// A session runner whose process outlives its turns (claude's stream-json
/// session, pi's rpc session) and can tell when that process went away while
/// no turn was running and nobody asked it to.
public protocol AgentIdleExitReporting: AnyObject {
    /// `handler` runs off the runner's queue with the exit code, the stderr
    /// tail, and whether background work (a background job or subagent) was
    /// still running when the process left.
    func observeIdleExit(_ handler: @escaping @Sendable (_ exitCode: Int32, _ stderrTail: String?, _ hadBackgroundWork: Bool) -> Void)
}
