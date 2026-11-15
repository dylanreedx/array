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
    import os, select, sys, time
    _fixture_parent = os.getppid()
    _fixture_deadline = time.monotonic() + 600
    def fixture_pause(seconds):
        reason = None
        if os.getppid() == 1 or os.getppid() != _fixture_parent:
            reason = 'parent gone'
        elif time.monotonic() >= _fixture_deadline:
            reason = 'deadline expired'
        else:
            # A poll object cannot be entered concurrently by prompt threads.
            fixture_input = select.poll()
            fixture_input.register(0, select.POLLHUP | select.POLLERR | select.POLLNVAL)
            if fixture_input.poll(0): reason = 'stdin closed'
        if reason:
            try:
                print('fixture_pause: ' + reason, file=sys.stderr, flush=True)
            except (OSError, ValueError):
                pass  # The parent may already have closed its stderr reader.
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

    /// Stretch the OS poll window so two real prompt threads overlap
    /// deterministically; every holder still uses the production fixture guard.
    static func overlappingHolds() async throws {
        let b = try WorkspaceAgentReportChecks.makeBench(label: "fake-cli-overlap")
        defer { b.tearDown() }
        let script = WorkspaceAgentReportChecks.fakePi
            .replacingOccurrences(of: ".poll(0)", with: ".poll(10)")
            .replacingOccurrences(of: #""release.flag""#, with: #""release-" + str(cmd["id"]) + ".flag""#)
        let cli = b.binDir.appendingPathComponent("pi")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        let child = try ProcessGroupChild.spawn(executable: cli.path, arguments: [],
            environment: ProcessInfo.processInfo.environment, currentDirectory: b.binDir, standardInput: .pipe)
        defer { child.terminateGroup() }
        for id in ["a", "b"] {
            let frame: [String: String] = ["id": id, "type": "prompt", "message": "HOLD-" + id]
            try child.standardInput!.write(contentsOf: JSONSerialization.data(withJSONObject: frame) + Data([10]))
        }
        var output = ""
        func count(_ marker: String) -> Int { output.components(separatedBy: marker).count - 1 }
        let started = await waitUntil(timeout: 5, pollInterval: 0.02) {
            output += String(decoding: ProcessGroupChild.drainRemainder(of: child.standardOutput, cap: 0.02), as: UTF8.self)
            return count("turn_start") == 2
        }
        try WorkspaceAgentReportChecks.expect(started, "two overlapping holds never started: \(output)")
        try await Task.sleep(for: .milliseconds(100))
        for id in ["a", "b"] { try Data().write(to: b.binDir.appendingPathComponent("release-" + id + ".flag")) }
        let settled = await waitUntil(timeout: 3, pollInterval: 0.02) {
            output += String(decoding: ProcessGroupChild.drainRemainder(of: child.standardOutput, cap: 0.02), as: UTF8.self)
            return count("agent_settled") == 2
        }
        let errors = String(decoding: ProcessGroupChild.drainRemainder(of: child.standardError, cap: 0.05), as: UTF8.self)
        print("Fake CLI overlapping holds: starts \(count("turn_start"))/2; settled \(count("agent_settled"))/2; concurrent poll errors \(errors.components(separatedBy: "concurrent poll() invocation").count - 1)")
        if !errors.isEmpty { fputs(errors, stderr) }
        try WorkspaceAgentReportChecks.expect(settled && !errors.contains("Traceback"), "overlapping fixture holds lost a holder thread")
    }

    /// A real production bench intentionally hands off one held fake to the
    /// matrix. The positive-control driver owns its PID/group and always reaps
    /// it. An old-fixture mode restores the original unguarded release poll.
    static func leakProbe() async throws {
        guard let path = ProcessInfo.processInfo.environment["ARRAY_FAKE_CLI_CONTROL_PATH"],
              let runID = ProcessInfo.processInfo.environment["ARRAY_CHECK_RUN_ID"], !runID.isEmpty else {
            throw WorkspaceAgentReportChecks.Failure(description: "leak probe requires its matrix driver and run marker")
        }
        let b = try ManagedModeChecks.bench("fake-cli-positive-control")
        var handedOff = false
        var child: ProcessGroupChild?
        defer { if !handedOff { child?.terminateGroup(); b.tearDown() } }
        let old = ProcessInfo.processInfo.environment["CONTINUUM_FAKE_CLI_LEAK_OLD_FIXTURE"] == "1"
        let cli = b.binDir.appendingPathComponent("claude")
        if old {
            let script = ManagedModeChecks.fakeClaude
                .replacingOccurrences(of: "time.monotonic() + 600", with: "time.monotonic() + 60")
                .replacingOccurrences(of: "while not os.path.exists('managed-release'): fixture_pause(.02)",
                    with: "while not os.path.exists('managed-release') and time.monotonic() < _fixture_deadline: time.sleep(.02)")
            try script.write(to: cli, atomically: true, encoding: .utf8)
        }
        let spawned = try ProcessGroupChild.spawn(executable: cli.path, arguments: ["--session-id", "positive-control"],
            environment: ProcessInfo.processInfo.environment, currentDirectory: b.binDir, standardInput: .pipe)
        child = spawned
        try spawned.standardInput!.write(contentsOf: Data(#"{"type":"user","message":"HOLD"}"#.utf8) + Data([10]))
        var output = ""
        let held = await waitUntil(timeout: 5, pollInterval: 0.02) {
            output += String(decoding: ProcessGroupChild.drainRemainder(of: spawned.standardOutput, cap: 0.02), as: UTF8.self)
            return output.contains("\"init\"")
        }
        try WorkspaceAgentReportChecks.expect(held, "real bench fake never entered HOLD: \(output)")
        let record: [String: Any] = ["pid": spawned.pid, "pgid": spawned.processGroupId,
            "bin": b.binDir.path, "executable": cli.path, "runID": runID, "oldFixture": old,
            "foundationTemp": FileManager.default.temporaryDirectory.path,
            "environmentTMPDIR": ProcessInfo.processInfo.environment["TMPDIR"] ?? ""]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
        print("Real bench leak probe: pid \(spawned.pid), old fixture \(old), bin \(b.binDir.path)")
        b.settings.removePersistentDomain(forName: b.settings.suiteDomainName)
        b.f.tearDown()
        setenv("PATH", b.originalPath, 1)
        setenv("CONTINUUM_APP_SUPPORT", b.originalSupport, 1)
        handedOff = true
    }

    static func run() async throws {
        try await overlappingHolds()
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
            let diagnostic = String(decoding: ProcessGroupChild.drainRemainder(of: child.standardError, cap: 0.05), as: UTF8.self)
            if exited && !diagnostic.contains("fixture_pause: stdin closed") {
                failures.append("\(variant) omitted its EOF exit diagnostic: \(diagnostic)")
            }
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
