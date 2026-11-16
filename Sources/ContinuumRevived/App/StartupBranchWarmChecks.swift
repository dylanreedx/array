import AppKit
import Darwin
import ContinuumRevivedCore

/// Measures the production branch warm after restoring a large agent store.
/// Each checkout is a distinct working directory backed by the same temporary
/// git object store; no user's checkout or tmux server is touched.
@MainActor
enum StartupBranchWarmChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    /// Samples from a background queue even while the main actor is busy.
    /// proc_pidinfo enumerates actual pipe descriptors without an fd ceiling.
    private final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private let group = DispatchGroup()
        private var stopping = false
        private var peakMalloc = 0
        private var peakPipes = 0
        private var validSamples = 0

        private func sample() {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { return }
            let stride = MemoryLayout<proc_fdinfo>.stride
            // Fds can open between sizing and reading; retry with room when the
            // returned buffer is full so a growing pipe burst cannot be truncated.
            var capacity = Int(size) / stride + 32
            var pipes: Int?
            for _ in 0..<4 {
                var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
                let bytes = Int32(fds.count * stride)
                let got = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &fds, bytes)
                guard got > 0 else { break }
                if got < bytes {
                    pipes = fds.prefix(Int(got) / stride).filter { $0.proc_fdtype == PROX_FDTYPE_PIPE }.count
                    break
                }
                capacity *= 2
            }
            guard let pipes else { return }
            lock.lock()
            peakMalloc = max(peakMalloc, stats.size_in_use)
            peakPipes = max(peakPipes, pipes)
            validSamples += 1
            lock.unlock()
        }

        func start() {
            sample()
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { group.leave() }
                while true {
                    lock.lock(); let done = stopping; lock.unlock()
                    if done { return }
                    sample()
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }

        func peaks() -> (malloc: Int, pipes: Int, samples: Int) {
            lock.lock(); defer { lock.unlock() }
            return (peakMalloc, peakPipes, validSamples)
        }

        func stop() -> (malloc: Int, pipes: Int, samples: Int) {
            lock.lock(); stopping = true; lock.unlock()
            group.wait()
            sample()
            return peaks()
        }
    }

    private static func git(_ args: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "fixture git failed: \(args)")
    }

    static func run() async throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-startup-branch-warm-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let common = root.appendingPathComponent("common", isDirectory: true)
        try fm.createDirectory(at: common, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], at: common)
        try git(["-c", "user.name=Array QA", "-c", "user.email=qa@example.invalid",
                 "commit", "--allow-empty", "--no-gpg-sign", "-qm", "fixture"], at: common)

        let checkoutCount = 400
        var checkouts: [URL] = []
        for index in 0..<checkoutCount {
            let checkout = root.appendingPathComponent("checkout-\(index)", isDirectory: true)
            try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
            try "gitdir: \(common.appendingPathComponent(".git").path)\n".write(
                to: checkout.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
            checkouts.append(checkout)
        }

        var fixture = AgentRecordArchiveChecks.makeFixture(cwd: root.path, total: 2300)
        for index in fixture.records.indices {
            let path = checkouts[index % checkoutCount].path
            fixture.records[index].cwd = path
            fixture.records[index].checkoutRoot = path
        }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let store = AgentStore(applicationSupportDirectory: support)
        try AgentRecordArchiveChecks.write(fixture.records, to: store)
        store.waitForBackupMigration()
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil })
        let suite = "array-startup-branch-warm-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AgentRecordArchiveConfig.enabledKey)
        supervisor.recordArchiveDefaults = defaults
        supervisor.codexRestoreHomeForQA = support.appendingPathComponent("codex-empty")
        defer { supervisor.stopAll() }
        let report = supervisor.restore()
        try expect(report.restored.count == fixture.records.count, "restore did not adopt all 2,300 fixture agents")
        let app = AppDelegate()
        app.agentSupervisor = supervisor
        let sampler = Sampler()
        sampler.start()
        defer { _ = sampler.stop() }
        let baseline = sampler.peaks()
        try expect(baseline.samples > 0, "could not enumerate pipe descriptors")
        app.warmCheckedOutBranchesIfNeeded()
        try expect(app.branchWarmInFlight, "the production warmer never started")
        let deadline = Date().addingTimeInterval(180)
        while app.branchWarmInFlight && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try expect(!app.branchWarmInFlight, "the production branch warmer did not finish")
        let peak = sampler.stop()
        try expect(peak.samples > baseline.samples, "no pipe samples were captured during warming")
        // Every restored record uses one of the fixture checkouts. Validate all
        // cached branch results, including agents without a currently visible tile.
        for record in fixture.records {
            try expect(supervisor.branchContextCachedOnly(for: record.id)?.checkedOutBranch == "main",
                       "a restored agent did not receive its checkout branch")
        }
        let deltaPipes = peak.pipes - baseline.pipes
        let deltaMalloc = max(0, peak.malloc - baseline.malloc)
        let metric = "startup branch warm: agents=2300 checkouts=\(checkoutCount) pipes baseline=\(baseline.pipes) peak=\(peak.pipes) delta=\(deltaPipes) malloc baseline=\(baseline.malloc) peak=\(peak.malloc) delta=\(deltaMalloc) samples=\(peak.samples)"
        print(metric)
        try expect(deltaPipes <= 32, "branch warming accumulated \(deltaPipes) pipe descriptors")
        return metric
    }
}
