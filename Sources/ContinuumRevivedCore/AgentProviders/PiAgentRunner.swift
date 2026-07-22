import Foundation

// Ticket: docs/38-tickets/88-provider-adapter-pi-gpt.md
//
// The IMPURE half of the Pi adapter: spawn `pi -p --mode json`, stream its
// stdout line-by-line through the (pure, tested) PiEventTranslator, and hand
// each normalized AgentRuntimeEvent to a callback as it arrives. Streaming is
// the point — the tile updates turn-by-turn, not at the end.
//
// Thread-safety: FileHandle readability callbacks fire on a background queue;
// the translator + line buffer are confined to `queue`, so translation stays
// serial and the caller only ever sees events (which it hops to the main
// actor itself).
public final class PiAgentRunner: @unchecked Sendable {
    public struct Config: Sendable {
        public var model: String
        public var cwd: URL
        /// Extra args before the prompt (e.g. session control). The runner
        /// always adds `-p --mode json <model>`.
        public var extraArgs: [String]

        public init(model: String = "openai-codex/gpt-5.6", cwd: URL, extraArgs: [String] = ["--no-session"]) {
            self.model = model
            self.cwd = cwd
            self.extraArgs = extraArgs
        }
    }

    public enum RunError: Error {
        case launchFailed(String)
        case piFailed(exitCode: Int32, stderr: String)
    }

    private let config: Config
    private let queue = DispatchQueue(label: "continuum.pi-agent-runner")
    private var translator = PiEventTranslator()
    private var buffer = Data()
    private var process: Process?

    public init(config: Config) {
        self.config = config
    }

    /// Runs Pi with `prompt`, streaming events to `onEvent` until Pi exits.
    /// Blocking; call off the main thread. `onEvent` is invoked on the
    /// runner's serial queue.
    public func run(prompt: String, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        let process = Process()
        // /usr/bin/env resolves `pi` on PATH. A GUI-launched app must inject a
        // PATH that includes the pi install (nvm bin) — see the ticket watch-out.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["pi", "-p", "--mode", "json", "--model", config.model] + config.extraArgs + [prompt]
        process.currentDirectoryURL = config.cwd

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.sync { self?.consume(chunk, onEvent: onEvent) }
        }

        self.process = process
        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(String(describing: error))
        }
        process.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil

        // Flush any trailing partial line + drain whatever the handler missed.
        let remainder = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        queue.sync {
            if !remainder.isEmpty { consume(remainder, onEvent: onEvent) }
            flushBuffer(onEvent: onEvent)
        }

        if process.terminationStatus != 0 {
            let errText = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw RunError.piFailed(exitCode: process.terminationStatus, stderr: errText)
        }
    }

    public func stop() {
        process?.terminate()
    }

    // MARK: - queue-confined line assembly

    private func consume(_ chunk: Data, onEvent: @Sendable (AgentRuntimeEvent) -> Void) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            emit(lineData, onEvent: onEvent)
        }
    }

    private func flushBuffer(onEvent: @Sendable (AgentRuntimeEvent) -> Void) {
        guard !buffer.isEmpty else { return }
        emit(buffer[...], onEvent: onEvent)
        buffer.removeAll()
    }

    private func emit(_ lineData: Data.SubSequence, onEvent: @Sendable (AgentRuntimeEvent) -> Void) {
        guard let line = String(data: Data(lineData), encoding: .utf8) else { return }
        for event in translator.translate(line: line) {
            onEvent(event)
        }
    }
}
