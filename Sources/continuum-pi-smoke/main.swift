import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/88-provider-adapter-pi-gpt.md
//
// Live end-to-end proof for PiAgentRunner: spawn a REAL GPT-5.6 agent via Pi
// and print the normalized AgentRuntimeEvents as they stream. Not in the
// matrix (needs network + Pi auth) — a dogfood harness.
//
//   continuum-pi-smoke "Read notes.txt and reply in one sentence."

let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
guard !prompt.isEmpty else {
    FileHandle.standardError.write(Data("usage: continuum-pi-smoke <prompt>\n".utf8))
    exit(2)
}

let runner = PiAgentRunner(config: .init(cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
let counter = Counter()
do {
    try runner.run(prompt: prompt) { event in
        print("[\(counter.next())] \(event)")
    }
    print("--- streamed \(counter.value) normalized events ---")
} catch {
    FileHandle.standardError.write(Data("pi-agent-runner failed: \(error)\n".utf8))
    exit(1)
}
