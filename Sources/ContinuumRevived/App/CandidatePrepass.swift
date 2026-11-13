import Foundation
import CryptoKit

/// Minted only at the host's explicit candidate-ready seam. No HEAD inference.
struct PrepassCandidate: Codable, Equatable, Sendable {
    let id: UUID
    let task: UUID
    let checkout: String
    let base: String
    let head: String

    static func isOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

struct CandidatePrepassOutcome: Codable, Sendable {
    var evaluatorVersion: String = "404058c3c514839413999334e2d2743f0eca3a144c8b6d4c3197dfd31ccd3934"
    let candidate: PrepassCandidate?
    let state: String
    let report: String?
}

/// Host channel store; checkout files are never read as evidence. A per-host
/// secret authenticates durable bytes. Restart deliberately requires rerunning:
/// an earlier process's file cannot authorize review in a new process.
final class CandidatePrepass: @unchecked Sendable {
    private struct Envelope: Codable { let bytes: Data; let mac: Data }
    private let key = SymmetricKey(size: .bits256)
    private let queue = DispatchQueue(label: "dev.array.candidate-prepass", qos: .utility)
    private let admission = NSLock()
    private var busy = false
    #if ARRAY_CHECKS
    // Deterministic same-UID tamper rendezvous, before output consumption.
    var qaAfterProcessExit: (@Sendable (URL, String) -> Void)?
    #endif
    private var outcomes: [UUID: CandidatePrepassOutcome] = [:] // queue-owned
    let enabled: Bool
    let support: URL
    private let evaluatorOverride: URL?
    private let workerOverride: URL?
    private let useBundledResources: Bool
    private var evaluator: URL? { evaluatorOverride ?? (useBundledResources ? Self.bundledEvaluator() : nil) }
    private var worker: URL? { workerOverride ?? (useBundledResources ? Self.bundledResource("worker.py") : nil) }

    init(support: URL, enabled: Bool = false, evaluator: URL? = nil,
         worker: URL? = nil, useBundledResources: Bool = true) {
        self.support = support.appendingPathComponent("candidate-prepass", isDirectory: true)
        self.enabled = enabled
        self.evaluatorOverride = evaluator
        self.workerOverride = worker
        self.useBundledResources = useBundledResources
    }

    static func bundledResource(_ name: String) -> URL? {
        for root in [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap({ $0 }) {
            let path = root.appendingPathComponent("continuum-revived_ContinuumRevived.bundle/GatePrepass/" + name)
            if FileManager.default.fileExists(atPath: path.path) { return path }
        }
        return nil
    }
    static func bundledEvaluator() -> URL? { bundledResource("evaluator.py") }

    func outcomeURL(_ candidate: PrepassCandidate) -> URL {
        support.appendingPathComponent(candidate.id.uuidString + ".json")
    }

    /// Admission never executes Git, touches disk, or waits for a running job.
    /// Every refusal is an observable outcome; callers must consume completion.
    @discardableResult
    func candidateReady(_ candidate: PrepassCandidate?,
                        completion: @escaping @Sendable (CandidatePrepassOutcome) -> Void) -> Bool {
        guard enabled else {
            completion(.init(candidate: candidate, state: "disabled", report: nil)); return false
        }
        admission.lock()
        guard !busy else {
            admission.unlock()
            completion(.init(candidate: candidate, state: "unavailable:busy", report: nil)); return false
        }
        busy = true
        admission.unlock()
        queue.async { [self] in
            var result = evaluate(candidate)
            do {
                try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                let bytes = try JSONEncoder().encode(result)
                let mac = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: key))
                let destination = candidate.map(outcomeURL) ?? support.appendingPathComponent("unidentified-" + UUID().uuidString + ".json")
                try JSONEncoder().encode(Envelope(bytes: bytes, mac: mac)).write(to: destination, options: .atomic)
            } catch {
                // Memory overrides old durable bytes, including a failed
                // replacement for the same candidate id.
                result = .init(candidate: candidate, state: "unavailable:persistence", report: nil)
            }
            if let candidate { outcomes[candidate.id] = result }
            admission.lock(); busy = false; admission.unlock()
            completion(result)
        }
        return true
    }

    /// Observable production review consumer. Requires the exact host candidate,
    /// authentic bytes AND live HEAD revalidation immediately before readiness.
    /// This grants no merge permission; a later merge must revalidate again.
    func review(_ candidate: PrepassCandidate, completion: @escaping @Sendable (CandidatePrepassOutcome) -> Void) {
        queue.async { [self] in
            func unknown(_ reason: String) {
                completion(.init(candidate: candidate, state: "unavailable:" + reason, report: nil))
            }
            guard enabled else { unknown("disabled"); return }
            if outcomes[candidate.id]?.state == "unavailable:persistence" { unknown("persistence"); return }
            guard let data = boundedEvidence(at: outcomeURL(candidate)),
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                  HMAC<SHA256>.isValidAuthenticationCode(envelope.mac, authenticating: envelope.bytes, using: key),
                  let result = try? JSONDecoder().decode(CandidatePrepassOutcome.self, from: envelope.bytes),
                  result.candidate == candidate,
                  result.evaluatorVersion == CandidatePrepassOutcome(candidate: nil, state: "", report: nil).evaluatorVersion else {
                unknown("evidence"); return
            }
            guard matchesHead(candidate) else { unknown("changed-head"); return }
            completion(result)
        }
    }

    private func boundedEvidence(at url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= 2_100_000,
              let bytes = try? handle.read(upToCount: 2_100_001), bytes.count <= 2_100_000 else { return nil }
        return bytes
    }

    private func verifiedBundledVersion() -> Bool {
        var bytes = Data()
        for name in ["evaluator.py", "check-notification-map.py", "worker.py"] {
            guard let url = Self.bundledResource(name),
                  let part = boundedEvidence(at: url) else { return false }
            bytes.append(part)
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return digest == CandidatePrepassOutcome(candidate: nil, state: "", report: nil).evaluatorVersion
    }

    private func matchesHead(_ candidate: PrepassCandidate) -> Bool {
        guard let result = run("/usr/bin/git", ["-C", candidate.checkout, "rev-parse", "--verify", "HEAD^{commit}"]),
              result.0 == 0 else { return false }
        return result.1.trimmingCharacters(in: .whitespacesAndNewlines) == candidate.head
    }

    private func evaluate(_ candidate: PrepassCandidate?) -> CandidatePrepassOutcome {
        func unknown(_ reason: String) -> CandidatePrepassOutcome {
            .init(candidate: candidate, state: "unavailable:" + reason, report: nil)
        }
        guard let candidate, PrepassCandidate.isOID(candidate.base), PrepassCandidate.isOID(candidate.head) else { return unknown("identity") }
        guard let evaluator, worker != nil else { return unknown("resources") }
        if evaluatorOverride == nil && workerOverride == nil && !verifiedBundledVersion() {
            return unknown("resource-version")
        }
        guard matchesHead(candidate) else { return unknown("changed-head") }
        for revision in [candidate.base, candidate.head] {
            guard let result = run("/usr/bin/git", ["-C", candidate.checkout, "rev-parse", "--verify", revision + "^{commit}"]),
                  result.0 == 0, result.1.trimmingCharacters(in: .whitespacesAndNewlines) == revision else { return unknown("identity") }
        }
        guard let result = run("/usr/bin/python3", ["-I", "-B", evaluator.path, candidate.base, candidate.head,
                                                   "--repo", candidate.checkout, "--json"]),
              result.0 == 0 || result.0 == 1,
              let data = result.1.data(using: .utf8),
              let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              report["base"] as? String == candidate.base, report["head"] as? String == candidate.head else { return unknown("evaluator") }
        guard matchesHead(candidate) else { return unknown("changed-head") }
        return .init(candidate: candidate, state: result.0 == 0 ? "clean" : "findings", report: result.1)
    }

    /// The trusted Python controller owns the entire process group, enforces
    /// inherited CPU/file limits and a group resident-memory watchdog, drains both streams incrementally and
    /// kills its group on timeout/output overflow. Swift adds a 12s fallback.
    /// File output avoids a racing readability handler/tail drain.
    private func run(_ executable: String, _ arguments: [String]) -> (Int32, String)? {
        guard let worker else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-B", worker.path, executable] + arguments
        var env = ProcessInfo.processInfo.environment
        for name in Array(env.keys) where name.hasPrefix("GIT_") || name.hasPrefix("ARRAY_PREPASS_")
            || ["ARRAY_AGENT_ID", "TMUX", "TMUX_PANE", "PYTHONPATH", "PYTHONHOME"].contains(name) { env.removeValue(forKey: name) }
        env["PATH"] = "/usr/bin:/bin"
        env["GIT_NO_LAZY_FETCH"] = "1"
        env["GIT_NO_REPLACE_OBJECTS"] = "1"
        env["GIT_CONFIG_COUNT"] = "3"
        for (index, pair) in [("core.fsmonitor", "false"), ("diff.external", ""), ("log.showSignature", "false")].enumerated() {
            env["GIT_CONFIG_KEY_\(index)"] = pair.0
            env["GIT_CONFIG_VALUE_\(index)"] = pair.1
        }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env // preserves managed crash marker
        process.standardInput = FileHandle.nullDevice
        var template = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("array-prepass-output-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { return nil }
        let outputName = String(cString: template)
        guard unlink(outputName) == 0 else { close(descriptor); return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(12)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            kill(-process.processIdentifier, SIGKILL)
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return nil
        }
        // Also retire any descendant that outlived a successful controller.
        kill(-process.processIdentifier, SIGKILL)
        #if ARRAY_CHECKS
        qaAfterProcessExit?(URL(fileURLWithPath: outputName), executable)
        #endif
        var info = stat()
        guard process.terminationStatus == 0 || process.terminationStatus == 1,
              fstat(descriptor, &info) == 0, info.st_nlink == 0,
              info.st_size >= 0, info.st_size <= 1_048_576 else { return nil }
        do { try handle.seek(toOffset: 0) } catch { return nil }
        guard let data = try? handle.read(upToCount: 1_048_577),
              data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return (process.terminationStatus, text)
    }
}
