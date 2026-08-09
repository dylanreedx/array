import Foundation

/// Live `pi --list-models` catalogue (follow-up to P0.10's explicit-model-id
/// work).
///
/// P0.10 froze the picker to a literal snapshot of `pi --list-models` because
/// `--model` takes a PATTERN and partial ids fuzzy-match. Freezing kept ids
/// exact but also invisible: pi lists only models whose provider is authed,
/// so when the user logs into a new provider (via pi's own `/login` CLI auth
/// flow — never pasted API keys) the picker stayed stuck on the snapshot.
/// This cache keeps the exactness rule — ids come verbatim from pi's own
/// list — and makes the list live: seeded with the frozen fallback, replaced
/// by one successful bounded probe per process (kicked at real-app startup).
///
/// QA never calls `startRefresh()`, so every check sees the deterministic
/// fallback.
public final class AgentModelCatalog: @unchecked Sendable {
    public static let shared = AgentModelCatalog()

    private let lock = NSLock()
    private var liveOptions: [String]?
    private var refreshStarted = false

    /// Public so checks can exercise instances without touching `shared`.
    public init() {}

    public func options(fallback: [String] = AgentModelConfig.fallbackModelOptions) -> [String] {
        lock.withLock { liveOptions } ?? fallback
    }

    /// Parse the `pi --list-models` table: a header row, then columns
    /// `provider  model  context  max-out  thinking  images` aligned with
    /// spaces. Returns fully-qualified `provider/model` ids in pi's own
    /// order. Pure — pinned in the matrix against a real fixture.
    public static func parse(listModelsOutput: String) -> [String] {
        var ids: [String] = []
        for rawLine in listModelsOutput.split(whereSeparator: \.isNewline) {
            // pi styles some terminal output; strip ANSI escapes defensively.
            let line = String(rawLine).replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { continue }
            let provider = String(fields[0])
            let model = String(fields[1])
            if provider == "provider", model == "model" { continue }
            ids.append("\(provider)/\(model)")
        }
        return ids
    }

    /// A non-empty parse replaces the current options; an empty or failed
    /// probe changes nothing (the picker must never go blank).
    public func apply(listModelsOutput: String) {
        let parsed = Self.parse(listModelsOutput: listModelsOutput)
        guard !parsed.isEmpty else { return }
        lock.withLock { liveOptions = parsed }
    }

    public func resetForQA(options: [String]? = nil) {
        lock.withLock {
            liveOptions = options
            refreshStarted = false
        }
    }

    /// Bounded live probe, once per process: resolve pi the same way the
    /// runner does, run `--list-models`, apply on success. Silent on every
    /// failure — no pi, no auth, timeout — because the fallback still stands.
    public func startRefresh(timeout: TimeInterval = 5.0) {
        let shouldStart = lock.withLock {
            if refreshStarted { return false }
            refreshStarted = true
            return true
        }
        guard shouldStart else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let command = PiAgentRunner.liveResolvedCommand()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.prefixArgs + ["--list-models"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = PiAgentRunner.augmentedPath(
                basePath: environment["PATH"] ?? "", extraDirs: PiAgentRunner.liveExtraDirs())
            process.environment = environment
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            do { try process.run() } catch { return }
            let killer = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return }
            self?.apply(listModelsOutput: output)
        }
    }
}
