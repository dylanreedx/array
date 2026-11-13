import Foundation

/// Host-owned immutable range. Never constructed from an AgentReport.
struct PrepassCandidate: Codable, Equatable {
    let checkout: String
    let base: String
    let head: String
}

struct CandidatePrepassOutcome: Codable {
    var evaluatorVersion: String = "eda302a28967ec2f2e4ad5587a93cae08e0187dd832c34c0b7399f8ddaed20f5"
    let candidate: PrepassCandidate?
    let state: String
    let report: String?
}

/// Separate from the ledger and runner queues. One pending job bounds admission;
/// excess requests remain unavailable rather than delaying a report.
final class CandidatePrepass {
    static let shared = CandidatePrepass()
    private let queue = DispatchQueue(label: "dev.array.candidate-prepass", qos: .utility)
    private let admission = NSLock()
    private var busy = false
    let enabled: Bool
    private let evaluator: URL?

    init(enabled: Bool = false, evaluator: URL? = CandidatePrepass.bundledEvaluator()) {
        self.enabled = enabled
        self.evaluator = evaluator
    }

    static func bundledEvaluator() -> URL? {
        for root in [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap({ $0 }) {
            let path = root.appendingPathComponent("continuum-revived_ContinuumRevived.bundle/GatePrepass/evaluator.py")
            if FileManager.default.fileExists(atPath: path.path) { return path }
        }
        return nil
    }

    /// Caller supplies only host checkout and host-captured delegation base.
    /// HEAD is captured here, asynchronously, never from report prose.
    @discardableResult
    func candidateReady(checkout: String, hostBase: String?, destination: URL,
                        completion: @escaping (CandidatePrepassOutcome) -> Void = { _ in }) -> Bool {
        guard enabled else { return false }
        admission.lock()
        guard !busy else { admission.unlock(); return false }
        busy = true
        admission.unlock()
        queue.async { [self] in
            let outcome = evaluate(checkout: checkout, base: hostBase)
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(outcome).write(to: destination, options: .atomic)
                admission.lock(); busy = false; admission.unlock()
                completion(outcome)
            } catch {
                admission.lock(); busy = false; admission.unlock()
                completion(.init(candidate: outcome.candidate, state: "unavailable:persistence", report: nil))
            }
        }
        return true
    }

    /// Review must present its exact immutable identity; disk presence alone
    /// never establishes readiness after restart or a changed head.
    static func reviewOutcome(at url: URL, matching candidate: PrepassCandidate) -> CandidatePrepassOutcome? {
        guard let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(CandidatePrepassOutcome.self, from: data),
              result.evaluatorVersion == CandidatePrepassOutcome(candidate: nil, state: "", report: nil).evaluatorVersion,
              result.candidate == candidate else { return nil }
        return result
    }

    private func evaluate(checkout: String, base: String?) -> CandidatePrepassOutcome {
        func unknown(_ reason: String) -> CandidatePrepassOutcome {
            .init(candidate: nil, state: "unavailable:" + reason, report: nil)
        }
        guard let base, isOID(base), let evaluator else { return unknown("identity-or-evaluator") }
        let root = URL(fileURLWithPath: checkout).resolvingSymlinksInPath().path
        guard let headResult = run("/usr/bin/git", ["-C", root, "rev-parse", "--verify", "HEAD^{commit}"]),
              headResult.0 == 0 else { return unknown("head") }
        let head = headResult.1.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isOID(head),
              let baseResult = run("/usr/bin/git", ["-C", root, "rev-parse", "--verify", base + "^{commit}"]),
              baseResult.0 == 0, baseResult.1.trimmingCharacters(in: .whitespacesAndNewlines) == base else { return unknown("base") }
        let candidate = PrepassCandidate(checkout: root, base: base, head: head)
        guard let result = run("/usr/bin/python3", ["-I", "-B", evaluator.path, base, head, "--repo", root, "--json"]),
              result.0 == 0 || result.0 == 1,
              let data = result.1.data(using: .utf8),
              let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              report["base"] as? String == base, report["head"] as? String == head else {
            return .init(candidate: candidate, state: "unavailable:evaluator", report: nil)
        }
        return .init(candidate: candidate, state: result.0 == 0 ? "clean" : "findings", report: result.1)
    }

    private func isOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// Bounded output and runtime; inherited managed-crash marker is preserved.
    /// No shell, checkout executable, hooks, builds, or tmux.
    private func run(_ executable: String, _ arguments: [String]) -> (Int32, String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for key in Array(env.keys) where key.hasPrefix("GIT_") || ["ARRAY_AGENT_ID", "TMUX", "TMUX_PANE", "PYTHONPATH", "PYTHONHOME"].contains(key) { env.removeValue(forKey: key) }
        env["PATH"] = "/usr/bin:/bin"
        env["GIT_NO_LAZY_FETCH"] = "1"
        env["GIT_NO_REPLACE_OBJECTS"] = "1"
        env["GIT_CONFIG_COUNT"] = "2"
        env["GIT_CONFIG_KEY_0"] = "core.fsmonitor"
        env["GIT_CONFIG_VALUE_0"] = "false"
        env["GIT_CONFIG_KEY_1"] = "diff.external"
        env["GIT_CONFIG_VALUE_1"] = ""
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let lock = NSLock()
        var output = Data()
        var overflow = false
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock()
            if output.count + data.count <= 1_048_576 { output.append(data) }
            else { overflow = true }
            lock.unlock()
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            lock.lock(); let exceeded = overflow; lock.unlock()
            if exceeded { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return nil
        }
        // Drain the tail after removing the reader.
        pipe.fileHandleForReading.readabilityHandler = nil
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        output.append(tail)
        let valid = !overflow && output.count <= 1_048_576
        let text = String(data: output, encoding: .utf8)
        lock.unlock()
        guard valid, let text else { return nil }
        return (process.terminationStatus, text)
    }
}
