import ContinuumRevivedCore
import Foundation

/// M1.8 (`.plans/46`) — stopping an agent stops everything it launched.
///
/// A Stop used to signal the CLI leader and nothing beneath it:
/// `Process.terminate()` sends SIGTERM to one pid, so the shells, MCP servers and
/// tool subprocesses a coding agent launches kept running — holding files, ports
/// and CPU after the user believed they had stopped. Foundation `Process` exposes
/// no process-group API at all, which is why this is a `posix_spawn`.
///
/// The fixture is the one `checkGeneratedNameOneShot` already proved out: a shell
/// that forks a **background grandchild** which records its own pid and then
/// touches a marker file after a delay. Killing only the leader leaves the
/// grandchild to touch the marker; killing the group does not. The assertions are
/// therefore *the marker is absent* AND *the pid is gone* — `kill(pid, 0) == -1`
/// with `ESRCH` — rather than anything the parent merely believes.
enum ProcessGroupChildChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private static func pidIsGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    static func run() throws -> String {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-process-group-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

        // === 1. The plain case: it runs, it streams, it reports an exit code. ===
        let plain = try ProcessGroupChild.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "printf out; printf err 1>&2; exit 3"],
            environment: environment,
            currentDirectory: nil,
            standardInput: .nullDevice)
        let plainOut = plain.standardOutput.readDataToEndOfFile()
        let plainErr = plain.standardError.readDataToEndOfFile()
        let plainCode = plain.wait()
        try expect(String(decoding: plainOut, as: UTF8.self) == "out",
                   "plain: stdout must be captured; got \(String(decoding: plainOut, as: UTF8.self).debugDescription)")
        try expect(String(decoding: plainErr, as: UTF8.self) == "err",
                   "plain: stderr must be captured; got \(String(decoding: plainErr, as: UTF8.self).debugDescription)")
        try expect(plainCode == 3, "plain: exit code must be 3; got \(plainCode)")

        // === 2. stdin, cwd and argv[0]. ===
        let echoed = try ProcessGroupChild.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "cat; pwd; printf '%s' \"$0\""],
            environment: environment,
            currentDirectory: root,
            standardInput: .pipe,
            argv0: "named-argv0")
        guard let stdin = echoed.standardInput else {
            throw Failure(message: "stdin: .pipe must give the caller a write handle")
        }
        try stdin.write(contentsOf: Data("piped\n".utf8))
        try stdin.close()
        let echoedText = String(decoding: echoed.standardOutput.readDataToEndOfFile(), as: UTF8.self)
        _ = echoed.wait()
        try expect(echoedText.contains("piped"), "stdin: the child must read what was written; got \(echoedText.debugDescription)")
        try expect(echoedText.contains(root.lastPathComponent),
                   "cwd: the child must run in the requested directory; got \(echoedText.debugDescription)")
        try expect(echoedText.hasSuffix("named-argv0"),
                   "argv0: the child must see the argv[0] it was given; got \(echoedText.debugDescription)")

        // === 3. The one that matters: a SIGTERM'd leader must take its whole tree. ===
        let marker = root.appendingPathComponent("grandchild-marker", isDirectory: false)
        let pidFile = root.appendingPathComponent("grandchild-pid", isDirectory: false)
        // The grandchild is a SEPARATE `sh -c`, backgrounded, and it outlives its
        // parent shell on purpose: it is the thing a per-pid terminate cannot
        // reach.
        //
        // `sh -c` rather than a `( … )` subshell, and that detail is the whole
        // fixture. Inside a subshell `$$` still expands to the PARENT shell's pid,
        // so the earlier draft recorded the leader and then "proved" the grandchild
        // died by watching the leader die — it stayed green with the group kill
        // replaced by a per-pid `kill(pid, …)`, i.e. it was green for the exact
        // defect it exists to catch.
        let script = """
        /bin/sh -c 'echo $$ > \(pidFile.path); sleep 3; : > \(marker.path)' &
        while :; do sleep 0.05; done
        """
        let tree = try ProcessGroupChild.spawn(
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: environment,
            currentDirectory: nil,
            standardInput: .nullDevice)

        // Wait for the grandchild to exist before killing anything, or the test
        // would pass by racing rather than by working.
        var grandchildPid: pid_t?
        let spawnDeadline = Date().addingTimeInterval(5)
        while Date() < spawnDeadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                grandchildPid = value
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let grandchildPid else {
            throw Failure(message: "tree: the grandchild never recorded its pid, so this case proves nothing")
        }
        try expect(!pidIsGone(grandchildPid),
                   "tree: precondition -- the grandchild must be alive before the group is stopped")
        try expect(getpgid(grandchildPid) == tree.processGroupId,
                   "tree: the grandchild must have INHERITED the leader's process group "
                   + "(\(getpgid(grandchildPid)) vs \(tree.processGroupId)); if it did not, the group "
                   + "kill below would be proving nothing")

        tree.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)

        var gone = false
        // Shorter than the grandchild's own `sleep 3`, so "gone" means killed and
        // never means "finished on its own while we waited".
        let killDeadline = Date().addingTimeInterval(1.5)
        while Date() < killDeadline {
            if pidIsGone(grandchildPid) { gone = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try expect(gone,
                   "tree: stopping the agent must kill the WHOLE process group -- grandchild "
                   + "\(grandchildPid) is still alive. This is what a per-pid Process.terminate() "
                   + "left behind: every shell, MCP server and tool subprocess the agent launched.")
        try expect(pidIsGone(tree.pid), "tree: the leader must be gone too")

        // Outlast the grandchild's own `sleep 3`. A survivor writes its marker at
        // that point and not before, so a shorter wait here would pass by racing.
        Thread.sleep(forTimeInterval: 3.5)
        try expect(!fileManager.fileExists(atPath: marker.path),
                   "tree: the grandchild wrote its marker, so it outlived the stop")

        // === 4. Escalation: a child that IGNORES SIGTERM still dies. ===
        let stubborn = try ProcessGroupChild.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do sleep 0.05; done"],
            environment: environment,
            currentDirectory: nil,
            standardInput: .nullDevice)
        Thread.sleep(forTimeInterval: 0.2)  // let the trap be installed
        let started = Date()
        stubborn.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)
        let elapsed = Date().timeIntervalSince(started)
        try expect(pidIsGone(stubborn.pid),
                   "escalation: a child that ignores SIGTERM must still be SIGKILLed")
        // Bounded, not timed: the claim is that cleanup cannot hang, not that it
        // hits a stopwatch. A wedged child turning cleanup into a second hang is
        // the trap the one-shot path already learned.
        try expect(elapsed < 2.0,
                   "escalation: cleanup must be bounded by the grace, not open-ended; took \(elapsed)s")

        // === 5. The cost of a short grace, made into an assertion.
        //
        // All three CLIs flush session state on a clean exit -- pi's own docs
        // describe `abort()` as clean precisely because it KEEPS the session file.
        // The interactive grace is ~0.15s so the Stop button feels instant, and a
        // SIGKILL that lands before the flush would truncate the conversation. So
        // the claim is not merely "the tree died": it is that a child which
        // handles SIGTERM and writes its session on the way out still gets to
        // finish. If this ever goes flaky, the grace goes UP; the assertion does
        // not come out.
        let sessionFile = root.appendingPathComponent("session.json", isDirectory: false)
        let sessionId = "sess-7f3a9c"
        let flushing = """
        trap 'printf "{\\"session\\":\\"\(sessionId)\\",\\"turns\\":2}" > \(sessionFile.path); exit 0' TERM
        while :; do sleep 0.02; done
        """
        let flusher = try ProcessGroupChild.spawn(
            executable: "/bin/sh",
            arguments: ["-c", flushing],
            environment: environment,
            currentDirectory: nil,
            standardInput: .nullDevice)
        Thread.sleep(forTimeInterval: 0.2)  // let the trap be installed
        try expect(!fileManager.fileExists(atPath: sessionFile.path),
                   "session: precondition -- nothing may be written before the stop")
        flusher.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)
        try expect(pidIsGone(flusher.pid), "session: the child must be gone after the stop")
        guard let written = try? String(contentsOf: sessionFile, encoding: .utf8) else {
            throw Failure(message: "session: the SIGTERM handler never got to write its session file "
                          + "-- the interactive grace (\(ProcessGroupChild.Grace.interactive)s) is too "
                          + "short, and a real Stop would be truncating the conversation")
        }
        try expect(written.contains(sessionId),
                   "session: the file must still name the same session; got \(written.debugDescription)")
        try expect(written.hasSuffix("}"),
                   "session: the file must be COMPLETE, not truncated mid-write; got "
                   + "\(written.debugDescription)")

        return "ProcessGroupChildChecks passed: stdio, cwd, argv0, whole-group kill (grandchild reaped), "
            + "SIGKILL escalation past an ignored SIGTERM, and a SIGTERM handler still flushed a "
            + "complete session file inside the interactive grace"
    }
}

/// Named `run…Checks()` so `check-matrix-inventory.sh` counts it: that script's
/// suite floor greps `run[A-Za-z0-9_]*Checks\(\)` in each target's main, and a
/// call it cannot see could be deleted without the inventory noticing.
func runProcessGroupChildChecks() {
    do {
        print(try ProcessGroupChildChecks.run())
    } catch {
        fputs("FAIL: \(error)\n", stderr)
        exit(1)
    }
}
