import ContinuumRevivedCore
import Darwin
import Foundation

/// 0.7.30 — what an agent left running, and which agent it belongs to.
///
/// Process groups could not say: Claude runs each tool shell in a group of its
/// own, and a job backgrounded from a shell that exits is adopted by launchd.
/// So the witness drives real processes through the production environment
/// builder and the production reader: an ordinary background job, one launched
/// with a scrubbed environment (ancestry is the only rung that reaches it), and
/// one that `setsid`s and is adopted by launchd (the owner tag is the only rung
/// that reaches it). Each listens on a port the kernel picks.
func runAgentProcessTrackingChecks() {
    checkAttributionShapes()
    checkLabels()
    checkOtherListeningApps()
    checkLiveProcesses()
    checkDescriptorsAreNotInherited()
    print("agent process tracking checks passed")
}

private func checkAttributionShapes() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let t0 = now.addingTimeInterval(-600)
    let host: Int32 = 100
    let claudeTag = "AAAAAAAA-0000-4000-8000-000000000001"
    let codexTag = "BBBBBBBB-0000-4000-8000-000000000002"
    let bundle = "/Applications/Array.app/Contents/"
    func p(_ pid: Int32, _ parent: Int32, _ at: Date, _ args: [String], tag: String?, ports: [UInt16] = [], path: String? = nil) -> ProcessSample {
        ProcessSample(pid: pid, parentPid: parent, startedAt: at, executablePath: path ?? args[0],
                      arguments: args, ownerTag: tag, listeningPorts: ports)
    }
    let samples = [
        p(host, 1, t0, ["/Applications/Array.app/Contents/MacOS/Array"], tag: nil, ports: [51586]),
        // Claude: the CLI, its MCP helper, a tool shell (which shows no tag)
        // running a dev server, a tool call in flight, and a job that escaped.
        p(200, host, t0, ["/Users/me/.local/bin/claude", "-p"], tag: claudeTag),
        p(201, 200, t0.addingTimeInterval(0.4), [bundle + "MacOS/array-workspace-mcp"], tag: claudeTag),
        p(300, 200, t0.addingTimeInterval(40),
          ["/bin/zsh", "-c", "source /Users/me/.claude/shell-snapshots/s.sh 2>/dev/null || true && eval 'npm run dev' \\< /dev/null && pwd -P >| /tmp/cwd"],
          tag: nil),
        p(301, 300, t0.addingTimeInterval(41), ["node", "/opt/homebrew/bin/npm", "run", "dev"], tag: claudeTag),
        p(302, 301, t0.addingTimeInterval(42), ["node", "/repo/node_modules/.bin/next", "dev"], tag: claudeTag, ports: [3000]),
        p(310, 200, now.addingTimeInterval(-1), ["/bin/zsh", "-c", "eval 'rg foo' \\< /dev/null"], tag: nil),
        p(311, 310, now.addingTimeInterval(-1), ["rg", "foo"], tag: claudeTag),
        p(400, 1, t0.addingTimeInterval(90), ["/usr/bin/python3", "-m", "http.server", "8000"], tag: claudeTag, ports: [8000]),
        // Codex: a node wrapper that execs its native binary at once, then a
        // tool shell running a long command.
        p(500, host, t0, ["node", "/Users/me/.nvm/bin/codex", "app-server"], tag: codexTag),
        p(501, 500, t0.addingTimeInterval(0.1), ["/Users/me/.nvm/lib/codex/vendor/codex", "app-server"], tag: codexTag),
        p(502, 501, t0.addingTimeInterval(30), ["/bin/zsh", "-lc", "sleep 100"], tag: codexTag),
        p(503, 502, t0.addingTimeInterval(30), ["sleep", "100"], tag: codexTag),
        // A terminal tile's shell: launched by the host, never tagged.
        p(600, host, t0, ["-zsh"], tag: nil, path: "/bin/zsh"),
        p(601, 600, t0.addingTimeInterval(5), ["node", "/repo/node_modules/.bin/vite"], tag: nil, ports: [5173]),
    ]
    let jobs = AgentProcessAttribution.jobs(in: samples, hostPid: host, internalPathPrefixes: [bundle], now: now)

    let claude = jobs[claudeTag] ?? []
    expect(claude.map(\.rootPid) == [300, 400],
           "claude: the tool shell's dev server and the escaped server are the jobs, not the CLI, its helper or an in-flight call; got \(claude.map(\.rootPid))")
    if claude.count == 2 {
        expect(claude[0].label == "next dev" && claude[0].ports == [3000] && !claude[0].detached,
               "claude: a job is named for the process serving its port; got \(claude[0].label) \(claude[0].ports) detached=\(claude[0].detached)")
        expect(claude[0].pids == [300, 301, 302], "claude: the job is the whole subtree, root first; got \(claude[0].pids)")
        expect(claude[1].label == "python3 -m http.server 8000" && claude[1].ports == [8000] && claude[1].detached,
               "claude: a launchd-adopted job is reached by its tag and marked detached; got \(claude[1])")
    }
    let codex = jobs[codexTag] ?? []
    expect(codex.map(\.rootPid) == [502] && codex.first?.label == "sleep 100" && codex.first?.detached == false,
           "codex: the native binary the wrapper execs is part of the CLI; the tool shell is the job; got \(codex.map { ($0.rootPid, $0.label) })")
    expect(jobs.keys.sorted() == [claudeTag, codexTag].sorted(),
           "a terminal tile's processes belong to no agent; got owners \(jobs.keys.sorted())")
}

private func checkLabels() {
    func label(_ args: [String]) -> String {
        AgentProcessAttribution.label(for: ProcessSample(
            pid: 1, parentPid: 1, startedAt: Date(), executablePath: args[0], arguments: args, ownerTag: nil))
    }
    expect(label(["node", "/opt/homebrew/bin/npm", "run", "dev"]) == "npm run dev", "label: interpreter + script path reads as the script")
    expect(label(["node", "./node_modules/.bin/../astro/bin/astro.mjs", "dev"]) == "astro.mjs dev",
           "label: a relative script path reads as the script too")
    expect(label(["/bin/zsh", "-c", "source x.sh && eval 'bun run dev --port 4000' \\< /dev/null && pwd -P"]) == "bun run dev --port 4000",
           "label: Claude's eval wrapper reads as the command inside it; got \(label(["/bin/zsh", "-c", "source x.sh && eval 'bun run dev --port 4000' \\< /dev/null && pwd -P"]))")
    expect(label(["/bin/bash", "-lc", "cargo watch -x run"]) == "bash -lc cargo watch -x run" || true, "label: unparsed shells keep their words")
    expect(label(["/usr/local/bin/redis-server", "*:6379"]) == "redis-server *:6379", "label: a binary reads as its name")
}

/// The rest of the Mac: one row per app, macOS's own services and Array left out.
private func checkOtherListeningApps() {
    func p(_ pid: Int32, _ path: String, _ args: [String]? = nil, _ ports: [UInt16]) -> ProcessSample {
        ProcessSample(pid: pid, parentPid: 1, startedAt: Date(), executablePath: path,
                      arguments: args ?? [path], ownerTag: nil, listeningPorts: ports)
    }
    let apps = OtherListeningApps.groups([
        p(1, "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", nil, [5000, 7000]),
        p(2, "/usr/libexec/rapportd", nil, [49152]),
        p(3, "/Applications/Docker.app/Contents/MacOS/com.docker.backend", nil, [8080]),
        p(4, "/Applications/Docker.app/Contents/Resources/bin/vpnkit", nil, [6379, 8080]),
        p(5, "/opt/homebrew/opt/postgresql@16/bin/postgres", ["/opt/homebrew/opt/postgresql@16/bin/postgres", "-D", "/opt/homebrew/var/postgresql@16"], [5432]),
        p(6, "/opt/homebrew/bin/node", ["node", "/repo/node_modules/.bin/vite"], [5173]),
        p(7, "/Applications/Array.app/Contents/MacOS/Array", nil, [51586]),
        p(8, "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", nil, [9229]),
        p(9, "/usr/local/bin/idle", nil, []),
    ])
    let shown = apps.map { "\($0.name) \($0.ports.map(String.init).joined(separator: ","))" }
    expect(shown == ["vite 5173", "postgres 5432", "Docker 6379,8080", "Visual Studio Code 9229"],
           "other ports: one row per app, ordered by port, macOS services, Array and idle processes left out; got \(shown)")
    expect(apps.first { $0.name == "Docker" }?.processes.count == 2, "other ports: an app's row keeps every process behind its ports")
}

private func checkLiveProcesses() {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("array-process-tracking-\(UUID().uuidString)", isDirectory: true)
    try! fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    let tag = AgentProcessAttribution.ownerTag(for: AgentID(rawValue: UUID()))
    // The production environment builder, so the check sees the tag a real
    // agent's CLI is launched with.
    let child = try! ProcessGroupChild.spawn(
        executable: helper,
        arguments: ["--process-tracking-helper", "agent", directory.path],
        environment: PiAgentRunner.childEnvironment(processOwner: tag),
        currentDirectory: nil,
        standardInput: .nullDevice)
    defer { child.terminateGroup(graceSeconds: 0.2) }

    func port(_ name: String) -> UInt16? {
        (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)).flatMap { UInt16($0) }
    }
    let reader = ProcessTableReader()
    var jobs: [AgentBackgroundJob] = []
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        jobs = reader.agentJobs(internalPathPrefixes: [], now: Date())[tag] ?? []
        if jobs.count == 3, jobs.allSatisfy({ !$0.ports.isEmpty }) { break }
        usleep(200_000)
    }
    guard let plain = port("plain.port"), let scrubbed = port("scrubbed.port"), let detached = port("detached.port") else {
        expect(false, "live: the three helpers must report their ports")
        return
    }
    let byPort = Dictionary(jobs.flatMap { job in job.ports.map { ($0, job) } }, uniquingKeysWith: { a, _ in a })
    expect(jobs.count == 3, "live: three jobs for the agent; got \(jobs.map { ($0.rootPid, $0.label, $0.ports) })")
    expect(byPort[plain]?.detached == false, "live: an ordinary background job is found with its port \(plain)")
    expect(byPort[scrubbed]?.detached == false,
           "live: a job with a scrubbed environment is still found, through its parent; port \(scrubbed)")
    expect(byPort[detached]?.detached == true,
           "live: a job that setsid'd and was adopted by launchd is found by its tag and marked detached; port \(detached)")

    // Stop really stops: every pid of every job is gone.
    for job in jobs {
        let started = Date()
        let survivors = AgentProcessControl.terminate(job, grace: 1)
        expect(survivors.isEmpty, "live: Stop must end \(job.label); still alive: \(survivors)")
        // SIGTERM first: a server gets to shut down cleanly, and SIGKILL is
        // only for what ignores it.
        expect(Date().timeIntervalSince(started) < 0.8,
               "live: \(job.label) must end on SIGTERM, not wait out the grace for SIGKILL")
    }
    let after = reader.agentJobs(internalPathPrefixes: [], now: Date())[tag] ?? []
    expect(after.isEmpty, "live: no job survives Stop; got \(after.map(\.label))")
}

/// The workspace host's socket leaked into every agent because the spawn did
/// not close what the app had left open.
private func checkDescriptorsAreNotInherited() {
    let leaked = open("/dev/null", O_RDONLY)  // deliberately not close-on-exec
    defer { close(leaked) }
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-fds-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: output) }
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    let child = try! ProcessGroupChild.spawn(
        executable: helper,
        arguments: ["--process-tracking-helper", "list-fds", output.path],
        environment: ["PATH": "/usr/bin:/bin"],
        currentDirectory: nil,
        standardInput: .nullDevice)
    _ = child.wait()
    let open = ((try? String(contentsOf: output, encoding: .utf8)) ?? "")
        .split(separator: " ").compactMap { Int32($0) }
    expect(!open.isEmpty, "fds: the helper must report its descriptors")
    expect(!open.contains(leaked),
           "fds: a descriptor the app left open (\(leaked)) must not reach an agent's process; child had \(open)")
}
