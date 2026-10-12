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
        ]
        let padded = " " + lowered
        // "401 Unauthorized…", "503 …": an HTTP status leading the line.
        let leadsWithStatus = lowered.count >= 3 && lowered.prefix(3).allSatisfy(\.isNumber)
            && (lowered.hasPrefix("4") || lowered.hasPrefix("5"))
        guard leadsWithStatus || markers.contains(where: { padded.contains($0) }) else { return nil }
        return bounded(SecretRedactor.redactLocalDiagnostics(line), maxCharacters)
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
