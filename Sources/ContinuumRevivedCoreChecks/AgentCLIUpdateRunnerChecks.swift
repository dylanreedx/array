import ContinuumRevivedCore
import Darwin
import Foundation

/// `--cli-update-runner-check` — the production update runner against fake
/// CLIs: shell scripts in a temp dir laid out like real installs, whose
/// `--version` reads a state file and whose `update` rewrites it. Nothing here
/// touches a real CLI, a real package manager or the network.
///
/// Cases: success (version moved → updated, idle sessions stopped, running ones
/// told to restart), no change (→ unchanged), exit 3 (→ failed with output), a
/// hang (→ timed out, process group gone), ownership changed between check and
/// run (→ aborted, nothing ran), two concurrent updates through one installer
/// (→ serialized), an npm-owned update while a turn runs (→ refused, npm never
/// started), and the child's environment carries no inherited credential.
func runAgentCLIUpdateRunnerChecks() {
    let fileManager = FileManager.default
    let scratch = fileManager.temporaryDirectory.appendingPathComponent("cli-runner-\(UUID().uuidString)", isDirectory: true)
    try? fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
    let root = AgentCLIFileSystem.live.realPath(scratch.path)
    defer { try? fileManager.removeItem(at: scratch) }

    final class GateLog: @unchecked Sendable {
        let lock = NSLock()
        var running = false
        var stopped: [AgentHarness] = []
        var restartNotes: [String] = []
        var gate: AgentCLISessionGate {
            AgentCLISessionGate(
                hasRunningTurn: { [self] _ in lock.withLock { running } },
                stopIdleSessions: { [self] harness in lock.withLock { stopped.append(harness) }; return 1 },
                noteRunningSessionsNeedRestart: { [self] harness, version in
                    lock.withLock { restartNotes.append("\(harness.rawValue)@\(version)") }
                })
        }
        func reset(running: Bool = false) { lock.withLock { self.running = running; stopped = []; restartNotes = [] } }
    }

    func write(_ path: String, _ text: String, executable: Bool = false) {
        try? fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fileManager.createFile(atPath: path, contents: Data(text.utf8))
        if executable { chmod(path, 0o755) }
    }
    func read(_ path: String) -> String? { fileManager.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } }

    /// A fake native claude: ~/.local/bin/claude -> versions/<file>. Its state
    /// lives in `state/`, baked into the script because the runner hands it an
    /// environment built from nothing.
    struct Fake { let link: String; let state: String }
    func nativeClaude(_ name: String, version: String, update: String) -> Fake {
        let home = root + "/\(name)/home"
        let state = root + "/\(name)/state"
        try? fileManager.createDirectory(atPath: state, withIntermediateDirectories: true)
        write(state + "/version", version + "\n")
        let script = """
        #!/bin/sh
        STATE='\(state)'
        case "$1" in
          --version) printf '%s (Claude Code)\\n' "$(cat "$STATE/version")" ;;
          update)
            pwd > "$STATE/cwd"
            env > "$STATE/env"
            echo $$ > "$STATE/pid"
        \(update)
            ;;
          *) exit 64 ;;
        esac
        """
        let binary = home + "/.local/share/claude/versions/\(version)"
        write(binary, script, executable: true)
        let link = home + "/.local/bin/claude"
        try? fileManager.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? fileManager.createSymbolicLink(atPath: link, withDestinationPath: binary)
        return Fake(link: link, state: state)
    }
    func plan(_ harness: AgentHarness, _ path: String) -> AgentCLIUpdatePlan {
        guard let plan = AgentCLIInstallOwnerResolver.plan(harness: harness, resolvedPath: path), plan.isRunnable else {
            expect(false, "cli-runner: the fake at \(path) must classify as runnable")
            fatalError()
        }
        return plan
    }
    final class PathBox: @unchecked Sendable { var paths: [AgentHarness: String] = [:] }
    let pathBox = PathBox()
    @Sendable func currentPath(_ harness: AgentHarness) -> String? { pathBox.paths[harness] }
    // A credential-laden app environment, as a user's shell might export.
    let secrets = ["ANTHROPIC_API_KEY": "sk-ant-SECRET", "OPENAI_API_KEY": "sk-SECRET", "GITHUB_TOKEN": "ghp_SECRET",
                   "NPM_TOKEN": "npm_SECRET", "AWS_SECRET_ACCESS_KEY": "aws-SECRET"]
    func runner(timeout: TimeInterval = AgentCLIUpdateRunner.defaultTimeout) -> AgentCLIUpdateRunner {
        AgentCLIUpdateRunner(
            resolvePlan: { harness in
                // The production re-check: resolve the same path, classify it again.
                AgentCLIInstallOwnerResolver.plan(harness: harness, resolvedPath: currentPath(harness))
            },
            environment: { plan in
                var base = secrets
                base["HOME"] = root
                base["PATH"] = "/should/not/lead"
                return AgentCLIProcess.environment(for: plan.argv?.first ?? plan.resolvedPath, base: base, extraDirs: [])
            },
            timeout: timeout)
    }
    let log = GateLog()

    // 1. Success: the version moves, output streams, sessions are handled.
    let success = nativeClaude("success", version: "2.1.302",
                               update: "    echo 'Updating Claude Code...'\n    echo '2.1.305' > \"$STATE/version\"\n    echo 'done'")
    pathBox.paths[.claudeCode] = success.link
    final class Streamed: @unchecked Sendable { let lock = NSLock(); var chunks: [String] = [] }
    let streamed = Streamed()
    let updated = runner().run(plan(.claudeCode, success.link), gate: log.gate) { tail in
        streamed.lock.withLock { streamed.chunks.append(tail) }
    }
    expect(updated == .updated(from: "2.1.302", to: "2.1.305", output: "Updating Claude Code...\ndone\n"),
           "cli-runner[success]: \(updated)")
    expect(updated.summary == "Updated to 2.1.305", "cli-runner[success]: summary \(updated.summary)")
    expect(streamed.lock.withLock { streamed.chunks.contains { $0.contains("Updating Claude Code") } },
           "cli-runner[success]: output must stream while the command runs")
    expect(log.stopped == [.claudeCode], "cli-runner[success]: the harness's idle sessions must be stopped once; \(log.stopped)")
    expect(log.restartNotes == ["Claude Code@2.1.305"], "cli-runner[success]: running sessions must be told; \(log.restartNotes)")
    // No shell, a disposable cwd, and nothing inherited but the basics.
    let cwd = (read(success.state + "/cwd") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    expect(cwd.contains("array-cli-update-") && !fileManager.fileExists(atPath: cwd),
           "cli-runner[success]: must run in a fresh temp cwd that is removed afterwards; ran in \(cwd)")
    let env = read(success.state + "/env") ?? ""
    for (key, value) in secrets {
        expect(!env.contains(key) && !env.contains(value), "cli-runner[success]: \(key) leaked into the updater's environment")
    }
    let childPath = env.split(separator: "\n").first { $0.hasPrefix("PATH=") }.map { String($0.dropFirst(5)) } ?? ""
    expect(childPath.hasPrefix((success.link as NSString).deletingLastPathComponent + ":") && !childPath.contains("/should/not/lead"),
           "cli-runner[success]: PATH must lead with the installer's own bin dir; got \(childPath)")

    // 2. No change.
    log.reset()
    let same = nativeClaude("unchanged", version: "2.1.305", update: "    echo 'Claude Code is up to date (2.1.305)'")
    pathBox.paths[.claudeCode] = same.link
    let unchanged = runner().run(plan(.claudeCode, same.link), gate: log.gate)
    expect(unchanged == .unchanged(version: "2.1.305", output: "Claude Code is up to date (2.1.305)\n"), "cli-runner[unchanged]: \(unchanged)")
    expect(log.stopped.isEmpty && log.restartNotes.isEmpty, "cli-runner[unchanged]: nothing changed, so no session may be touched")

    // 3. Exit 3, with what it said.
    log.reset()
    let failing = nativeClaude("failing", version: "2.1.302", update: "    echo 'boom: could not reach the registry' >&2\n    exit 3")
    pathBox.paths[.claudeCode] = failing.link
    let failed = runner().run(plan(.claudeCode, failing.link), gate: log.gate)
    expect(failed == .failed(exitCode: 3, output: "boom: could not reach the registry\n"), "cli-runner[exit 3]: \(failed)")
    expect(failed.summary == "Failed (exit 3)" && log.stopped.isEmpty, "cli-runner[exit 3]: \(failed.summary)")

    // 4. A hang: timed out, and the whole process group is gone.
    log.reset()
    let hanging = nativeClaude("hanging", version: "2.1.302", update: "    echo 'starting'\n    sleep 30 &\n    echo $! > \"$STATE/sleeper\"\n    wait")
    pathBox.paths[.claudeCode] = hanging.link
    let started = Date()
    let timedOut = runner(timeout: 1).run(plan(.claudeCode, hanging.link), gate: log.gate)
    let elapsed = Date().timeIntervalSince(started)
    expect(timedOut == .timedOut(output: "starting\n"), "cli-runner[timeout]: \(timedOut)")
    expect(elapsed < 8, "cli-runner[timeout]: took \(elapsed)s for a 1s deadline")
    for marker in ["pid", "sleeper"] {
        if let pid = read(hanging.state + "/" + marker).flatMap({ pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            expect(kill(pid, 0) != 0, "cli-runner[timeout]: \(marker) \(pid) outlived the timeout")
        } else {
            expect(false, "cli-runner[timeout]: the fake never recorded its \(marker)")
        }
    }
    expect(log.stopped.isEmpty, "cli-runner[timeout]: no session may be touched")

    // 5. Ownership changed between the check and the run: aborted, nothing ran.
    log.reset()
    let drifting = nativeClaude("drifting", version: "2.1.302", update: "    echo '2.1.305' > \"$STATE/version\"")
    pathBox.paths[.claudeCode] = drifting.link
    let checked = plan(.claudeCode, drifting.link)
    let other = root + "/drifting/elsewhere/claude"
    write(other, "#!/bin/sh\necho 9.9.9\n", executable: true)
    try? fileManager.removeItem(atPath: drifting.link)
    try? fileManager.createSymbolicLink(atPath: drifting.link, withDestinationPath: other)
    let aborted = runner().run(checked, gate: log.gate)
    if case .aborted = aborted {} else { expect(false, "cli-runner[ownership changed]: must abort; got \(aborted)") }
    expect(!fileManager.fileExists(atPath: drifting.state + "/cwd"), "cli-runner[ownership changed]: the command must not have run")

    // 6. Two concurrent updates through ONE installer are serialized.
    log.reset()
    let busy = nativeClaude("serialized", version: "2.1.302", update: """
            if ! mkdir "$STATE/inflight" 2>/dev/null; then echo 'overlap'; exit 9; fi
            sleep 0.4
            echo '2.1.305' > "$STATE/version"
            rmdir "$STATE/inflight"
        """)
    pathBox.paths[.claudeCode] = busy.link
    let busyPlan = plan(.claudeCode, busy.link)
    final class Results: @unchecked Sendable { let lock = NSLock(); var values: [AgentCLIUpdateResult] = [] }
    let results = Results()
    let group = DispatchGroup()
    let concurrent = runner()
    for _ in 0..<2 {
        DispatchQueue.global().async(group: group) {
            let result = concurrent.run(busyPlan, gate: log.gate)
            results.lock.withLock { results.values.append(result) }
        }
    }
    expect(group.wait(timeout: .now() + 20) == .success, "cli-runner[serialized]: the two updates never finished")
    let both = results.lock.withLock { results.values }
    expect(both.contains { if case .updated = $0 { return true }; return false }
           && both.contains { if case .unchanged = $0 { return true }; return false },
           "cli-runner[serialized]: one updates, the next finds it current, neither overlaps; got \(both)")

    // 7. npm-owned with a turn in flight: refused before npm ever starts.
    log.reset(running: true)
    let prefix = root + "/nvm/versions/node/v22.22.2"
    let npmState = root + "/nvm/state"
    try? fileManager.createDirectory(atPath: npmState, withIntermediateDirectories: true)
    write(npmState + "/version", "0.159.3\n")
    write(prefix + "/lib/node_modules/@openai/codex/bin/codex.js",
          "#!/bin/sh\nprintf 'codex-cli %s\\n' \"$(cat '\(npmState)/version')\"\n", executable: true)
    try? fileManager.createDirectory(atPath: prefix + "/bin", withIntermediateDirectories: true)
    try? fileManager.createSymbolicLink(atPath: prefix + "/bin/codex", withDestinationPath: "../lib/node_modules/@openai/codex/bin/codex.js")
    write(prefix + "/bin/npm", """
        #!/bin/sh
        echo "$@" > '\(npmState)/npm-argv'
        echo '0.160.0' > '\(npmState)/version'
        echo 'added 1 package'
        """, executable: true)
    pathBox.paths[.codex] = prefix + "/bin/codex"
    let npmPlan = plan(.codex, prefix + "/bin/codex")
    let refused = runner().run(npmPlan, gate: log.gate)
    if case .refused = refused {} else { expect(false, "cli-runner[npm + running turn]: must refuse; got \(refused)") }
    expect(!fileManager.fileExists(atPath: npmState + "/npm-argv"), "cli-runner[npm + running turn]: npm must never have started")
    // The same plan with nothing running goes ahead, through the prefix's npm.
    log.reset(running: false)
    let npmUpdated = runner().run(npmPlan, gate: log.gate)
    expect(npmUpdated == .updated(from: "0.159.3", to: "0.160.0", output: "added 1 package\n"), "cli-runner[npm idle]: \(npmUpdated)")
    expect((read(npmState + "/npm-argv") ?? "") == "install -g --prefix \(prefix) --allow-scripts=@openai/codex @openai/codex@latest\n",
           "cli-runner[npm idle]: npm argv \(read(npmState + "/npm-argv") ?? "nothing")")
    expect(log.stopped == [.codex], "cli-runner[npm idle]: codex's idle sessions must be stopped; \(log.stopped)")

    // A native install with a turn running is NOT refused: the native installer
    // keeps the old version on disk, so the running turn is undisturbed.
    log.reset(running: true)
    let nativeBusy = nativeClaude("native-busy", version: "2.1.302", update: "    echo '2.1.305' > \"$STATE/version\"")
    pathBox.paths[.claudeCode] = nativeBusy.link
    let nativeResult = runner().run(plan(.claudeCode, nativeBusy.link), gate: log.gate)
    expect(nativeResult.succeeded, "cli-runner[native + running turn]: must update; got \(nativeResult)")

    // A plan with no command is refused outright.
    let manual = AgentCLIInstallOwnerResolver.plan(harness: .claudeCode, resolvedPath: root + "/success/state/version")!
    if case .refused = runner().run(manual, gate: log.gate) {} else { expect(false, "cli-runner[no command]: must refuse") }

    // The latest-version cache: an hour on a hit, a minute on a miss, a 429 held
    // for as long as the server asked, and a forced check never past a 429.
    final class ScriptedFetcher: AgentCLILatestVersionFetching, @unchecked Sendable {
        let lock = NSLock()
        var answers: [AgentCLILatestLookup]
        var calls = 0
        init(_ answers: [AgentCLILatestLookup]) { self.answers = answers }
        func lookup(_ source: AgentCLILatestSource) async -> AgentCLILatestLookup {
            lock.withLock { calls += 1; return answers.isEmpty ? .notFound : answers.removeFirst() }
        }
    }
    final class Box: @unchecked Sendable { var value: String? }
    func blocking(_ work: @escaping @Sendable () async -> String?) -> String? {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached { box.value = await work(); done.signal() }
        done.wait()
        return box.value
    }
    let fetcher = ScriptedFetcher([.found("2.1.305"), .found("2.1.306"), .rateLimited(retryAfter: 600), .found("2.1.307"), .notFound, .found("2.1.308")])
    let cache = AgentCLILatestVersionCache(fetcher: fetcher)
    let source = AgentCLILatestSource.npm(package: "@anthropic-ai/claude-code")
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    expect(blocking { await cache.latest(for: source, now: t0) } == "2.1.305", "cli-latest: first lookup")
    expect(blocking { await cache.latest(for: source, now: t0.addingTimeInterval(59 * 60)) } == "2.1.305" && fetcher.calls == 1,
           "cli-latest: a hit is reused for an hour; calls \(fetcher.calls)")
    expect(blocking { await cache.latest(for: source, now: t0.addingTimeInterval(61 * 60)) } == "2.1.306" && fetcher.calls == 2,
           "cli-latest: after an hour it looks again; calls \(fetcher.calls)")
    let t1 = t0.addingTimeInterval(3 * 60 * 60)
    expect(blocking { await cache.latest(for: source, now: t1) } == "2.1.306", "cli-latest: a 429 keeps the last answer")
    expect(blocking { await cache.latest(for: source, now: t1.addingTimeInterval(300), force: true) } == "2.1.306" && fetcher.calls == 3,
           "cli-latest: even a forced check waits out a 429's Retry-After; calls \(fetcher.calls)")
    expect(blocking { await cache.latest(for: source, now: t1.addingTimeInterval(601)) } == "2.1.307" && fetcher.calls == 4,
           "cli-latest: after Retry-After it looks again; calls \(fetcher.calls)")
    let t2 = t1.addingTimeInterval(2 * 60 * 60)
    _ = blocking { await cache.latest(for: source, now: t2) }
    expect(blocking { await cache.latest(for: source, now: t2.addingTimeInterval(61)) } == "2.1.308" && fetcher.calls == 6,
           "cli-latest: a miss is retried after a minute; calls \(fetcher.calls)")
    expect(AgentCLIUpdateOptOut.isOptedOut(.claudeCode, environment: ["DISABLE_AUTOUPDATER": "1"])
           && AgentCLIUpdateOptOut.isOptedOut(.claudeCode, environment: ["DISABLE_UPDATES": "true"])
           && AgentCLIUpdateOptOut.isOptedOut(.pi, environment: ["PI_OFFLINE": "1"])
           && AgentCLIUpdateOptOut.isOptedOut(.pi, environment: ["PI_SKIP_VERSION_CHECK": "1"])
           && !AgentCLIUpdateOptOut.isOptedOut(.claudeCode, environment: ["DISABLE_AUTOUPDATER": "0", "PI_OFFLINE": "1"])
           && !AgentCLIUpdateOptOut.isOptedOut(.codex, environment: ["DISABLE_AUTOUPDATER": "1"]),
           "cli-latest: the vendors' own opt-outs, per CLI")
    expect(AgentCLILiveLatestVersionFetcher.parseVersionJSON(Data(#"{"name":"@openai/codex","version":"0.160.0"}"#.utf8)) == "0.160.0"
           && AgentCLILiveLatestVersionFetcher.parseVersionJSON(Data(#"{"error":"Not found"}"#.utf8)) == nil,
           "cli-latest: registry document parse")
    expect(AgentCLILiveLatestVersionFetcher.parseHomebrewInfo(Data(#"{"formulae":[],"casks":[{"version":"2.1.305,abc"}]}"#.utf8), kind: .cask) == "2.1.305"
           && AgentCLILiveLatestVersionFetcher.parseHomebrewInfo(Data(#"{"formulae":[{"versions":{"stable":"0.160.0"}}],"casks":[]}"#.utf8), kind: .formula) == "0.160.0",
           "cli-latest: brew info --json=v2 parse")

    print("PASS: cli-update-runner — updated/unchanged/failed/timed out/aborted/serialized/refused, no inherited credentials; latest cache 1h/1m/429")
}
