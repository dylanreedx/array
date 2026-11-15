import AppKit
import ContinuumRevivedCore
import Darwin
import Foundation

/// Fixture processes must not outlive a failed check or its disposable bench.
@MainActor
enum FakeCLILifecycleChecks {
    /// Polling a release file must also notice EOF without consuming another
    /// protocol frame. POLLHUP works even if TextIOWrapper buffered input.
    static let pythonLifetime = #"""
    import os, select, time
    _fixture_parent = os.getppid()
    _fixture_deadline = time.monotonic() + 600
    _fixture_input = select.poll()
    _fixture_input.register(0, select.POLLHUP | select.POLLERR | select.POLLNVAL)
    def fixture_pause(seconds):
        if (os.getppid() == 1 or os.getppid() != _fixture_parent
                or time.monotonic() >= _fixture_deadline or _fixture_input.poll(0)):
            os._exit(0)
        time.sleep(seconds)
    """#

    static func protectPython(_ source: String) -> String {
        source.replacingOccurrences(of: "#!/usr/bin/env python3\n",
            with: "#!/usr/bin/env python3\n" + pythonLifetime + "\n")
    }

    struct OwnedProcess {
        let pid: pid_t
        let group: pid_t
    }

    /// Exact executable paths in this UUID-named bin directory are our proof
    /// of ownership. Never signal a shared Foundation Process group.
    static func ownedProcesses(in bin: URL) -> [OwnedProcess] {
        let ps = Process(), output = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,pgid=,command="]
        ps.standardOutput = output
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard ps.terminationStatus == 0 else { return [] }
        let canonical = bin.resolvingSymlinksInPath().path
        let roots = Set([bin.path, canonical, canonical.hasPrefix("/private/") ? String(canonical.dropFirst(8)) : canonical])
        let executables = Set(roots.flatMap { root in ["claude", "codex", "pi"].map { root + "/" + $0 } })
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let pid = pid_t(fields[0]), let group = pid_t(fields[1]),
                  pid > 1, pid != getpid(),
                  fields[2].split(whereSeparator: { $0.isWhitespace }).contains(where: { executables.contains(String($0)) }) else { return nil }
            return OwnedProcess(pid: pid, group: group)
        }
    }

    /// stopAll cannot reach a runner a check replaced or lost. Re-discover
    /// only this bench's fakes, TERM their groups, then KILL any stragglers.
    static func terminate(in bin: URL) {
        func signalOwned(_ signal: Int32) {
            for process in ownedProcesses(in: bin) {
                _ = kill(process.group == process.pid ? -process.group : process.pid, signal)
            }
        }
        let groups = Set(ownedProcesses(in: bin).filter { $0.group == $0.pid }.map(\.group))
        signalOwned(SIGTERM)
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline, !ownedProcesses(in: bin).isEmpty { Thread.sleep(forTimeInterval: 0.02) }
        // The leader may have accepted TERM while a descendant ignored it.
        // These groups were identified before TERM, while ownership was visible.
        for group in groups where ProcessGroupChild.groupExists(group) { _ = kill(-group, SIGKILL) }
        signalOwned(SIGKILL)
        let killedDeadline = Date().addingTimeInterval(1)
        while Date() < killedDeadline, !ownedProcesses(in: bin).isEmpty { Thread.sleep(forTimeInterval: 0.02) }
    }

    static func run() async throws {
        var failures: [String] = []
        var eofSurvivors = 0
        // The real generated scripts, including the string-patched derivatives.
        for variant in ["managed", "retry", "ledger", "pi", "codex"] {
            let b: WorkspaceAgentReportChecks.Bench
            switch variant {
            case "retry": b = try HelperRetryWorktreeChecks.bench("fake-lifecycle-retry")
            case "pi": b = try WorkspaceAgentReportChecks.makeBench(label: "fake-lifecycle-pi")
            case "codex": b = try ManagedCodexChecks.bench()
            default: b = try ManagedModeChecks.bench("fake-lifecycle-" + variant)
            }
            defer { b.tearDown() }
            if variant == "ledger" {
                try ManagedRunLedgerChecks.script.write(to: b.binDir.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
            }
            let cli = variant == "pi" ? "pi" : variant == "codex" ? "codex" : "claude"
            var environment = ProcessInfo.processInfo.environment
            environment["ARRAY_MANAGED_CODEX_LOG"] = b.binDir.appendingPathComponent("codex.log").path
            let child = try ProcessGroupChild.spawn(executable: b.binDir.appendingPathComponent(cli).path,
                arguments: cli == "claude" ? ["--session-id", "fixture"] : [], environment: environment,
                currentDirectory: b.binDir, standardInput: .pipe)
            defer { child.terminateGroup() }
            let prompt = cli == "claude" ? #"{"type":"user","message":"HOLD-fixture"}"#
                : cli == "pi" ? #"{"type":"prompt","id":"fixture","message":"HOLD"}"#
                : #"{"id":1,"method":"turn/start","params":{"input":[{"text":"HOLD"}]}}"#
            try child.standardInput!.write(contentsOf: Data((prompt + "\n").utf8))
            let output = ProcessGroupChild.drainRemainder(of: child.standardOutput, cap: 0.5)
            let text = String(decoding: output, as: UTF8.self)
            guard text.contains(cli == "claude" ? "\"init\"" : cli == "pi" ? "turn_start" : "turn/started") else {
                throw WorkspaceAgentReportChecks.Failure(description: "\(variant) never entered a held turn: \(text)")
            }
            try child.standardInput!.close()
            let exited = await waitUntil(timeout: 2, pollInterval: 0.02) { child.pollExitRaw() != nil }
            if !exited { eofSurvivors += 1; failures.append("\(variant) survived stdin EOF during HOLD") }
        }

        let orphanBench = try ManagedModeChecks.bench("fake-lifecycle-orphan")
        defer { orphanBench.tearDown() }
        let launcherSource = #"""
        import os, signal, subprocess, sys, time
        signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGTERM])
        child = subprocess.Popen([sys.argv[1], '--session-id', 'orphan'], stdin=sys.stdin)
        deadline = time.monotonic() + 5
        while not os.path.exists('managed-argv.jsonl') and time.monotonic() < deadline: time.sleep(.01)
        sys.exit(0 if os.path.exists('managed-argv.jsonl') else 2)
        """#
        let launcher = try ProcessGroupChild.spawn(executable: "/usr/bin/env",
            arguments: ["python3", "-c", launcherSource, orphanBench.binDir.appendingPathComponent("claude").path],
            environment: ProcessInfo.processInfo.environment, currentDirectory: orphanBench.binDir, standardInput: .pipe)
        defer { launcher.terminateGroup() }
        try launcher.standardInput!.write(contentsOf: Data(#"{"type":"user","message":"HOLD"}"#.utf8) + Data([10]))
        let parentExited = await waitUntil(timeout: 5, pollInterval: 0.02) { launcher.pollExitRaw() != nil }
        try WorkspaceAgentReportChecks.expect(parentExited, "orphan launcher did not exit")
        let orphanExited = await waitUntil(timeout: 2, pollInterval: 0.02) { ownedProcesses(in: orphanBench.binDir).isEmpty }
        let orphanSurvivors = orphanExited ? 0 : 1
        if !orphanExited { failures.append("fake survived parent death with stdin still open and TERM blocked") }

        let b = try ManagedModeChecks.bench("fake-lifecycle-teardown")
        var tornDown = false
        defer { if !tornDown { b.tearDown() } }
        // Simulate a lost runner with TERM blocked. A child in the same group
        // proves escalation applies to the group, not just its leader.
        let script = b.binDir.appendingPathComponent("claude")
        try #"""
        #!/usr/bin/env python3
        import os, signal, subprocess, time
        signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGTERM])
        descendant = subprocess.Popen(['/bin/sleep', '600'])
        print('held', flush=True)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline: time.sleep(.02)
        descendant.kill()
        descendant.wait()
        """#.write(to: script, atomically: true, encoding: .utf8)
        let child = try ProcessGroupChild.spawn(executable: script.path, arguments: [],
            environment: ProcessInfo.processInfo.environment, currentDirectory: b.binDir, standardInput: .pipe)
        defer { child.terminateGroup() }
        let output = ProcessGroupChild.drainRemainder(of: child.standardOutput, cap: 0.5)
        try WorkspaceAgentReportChecks.expect(String(decoding: output, as: UTF8.self).contains("held"), "teardown fake not ready")
        b.tearDown()
        tornDown = true
        _ = child.pollExitRaw()
        let groupSurvivors = ProcessGroupChild.groupExists(child.processGroupId) ? 1 : 0
        if groupSurvivors > 0 { failures.append("bench teardown left a TERM-blocked fake's process group alive") }
        print("Fake CLI lifecycle: EOF survivors \(eofSurvivors)/5; orphan survivors \(orphanSurvivors)/1; teardown group survivors \(groupSurvivors)/1")
        try WorkspaceAgentReportChecks.expect(failures.isEmpty, failures.joined(separator: "; "))
    }
}
