import Foundation

/// One row of the OS process table, as far as attribution needs it.
public struct ProcessSample: Equatable, Sendable {
    public var pid: Int32
    public var parentPid: Int32
    public var startedAt: Date
    public var executablePath: String
    public var arguments: [String]
    /// `AgentProcessAttribution.ownerEnvironmentKey` from the process's own
    /// environment, or nil. Some processes rewrite or never expose theirs (a
    /// zsh tool shell reads as untagged), which is why ancestry is the second
    /// rung.
    public var ownerTag: String?
    /// `AgentProcessAttribution.faceEnvironmentKey` from the same environment:
    /// `terminal` for a claude Array runs in an agent tile's Terminal face.
    public var ownerFace: String?
    public var listeningPorts: [UInt16]

    public init(
        pid: Int32, parentPid: Int32, startedAt: Date, executablePath: String,
        arguments: [String], ownerTag: String?, ownerFace: String? = nil, listeningPorts: [UInt16] = []
    ) {
        self.pid = pid
        self.parentPid = parentPid
        self.startedAt = startedAt
        self.executablePath = executablePath
        self.arguments = arguments
        self.ownerTag = ownerTag
        self.ownerFace = ownerFace
        self.listeningPorts = listeningPorts
    }
}

/// Something an agent started that is still running: a dev server, a watcher,
/// a long test run. One job is a subtree rooted where the agent's own CLI
/// handed off, or where a process escaped it.
public struct AgentBackgroundJob: Equatable, Sendable, Identifiable {
    /// Stable for the life of the root process (pid + start time), so a pid
    /// the OS reuses is a different job.
    public var id: String
    public var owner: String
    public var rootPid: Int32
    /// The whole subtree, root first. Stopping a job signals all of them.
    public var pids: [Int32]
    /// Each pid's start time, so a stop never signals a pid the OS has since
    /// handed to an unrelated process.
    public var startTimes: [Int32: Date]
    /// What the row says: the command a person would recognise.
    public var label: String
    public var commandLine: String
    public var ports: [UInt16]
    public var startedAt: Date
    /// True when the job is no longer under the agent's CLI (it `setsid`ed,
    /// was backgrounded with `&` from a shell that exited, or its CLI is gone).
    /// Such a job outlives Stop and closing the tile.
    public var detached: Bool

    public init(
        id: String, owner: String, rootPid: Int32, pids: [Int32], startTimes: [Int32: Date],
        label: String, commandLine: String, ports: [UInt16], startedAt: Date, detached: Bool
    ) {
        self.id = id
        self.owner = owner
        self.rootPid = rootPid
        self.pids = pids
        self.startTimes = startTimes
        self.label = label
        self.commandLine = commandLine
        self.ports = ports
        self.startedAt = startedAt
        self.detached = detached
    }
}

/// Which running processes belong to which agent.
///
/// Process groups cannot answer this: Claude runs every tool shell in a group
/// of its own, so killing the CLI's group never reached them and they were
/// adopted by launchd, untracked. Two rungs instead — the owner tag every
/// managed CLI is launched with (inherited through `setsid` and adoption), and,
/// for a process that does not show it, its nearest tagged ancestor.
public enum AgentProcessAttribution {
    public static let ownerEnvironmentKey = "ARRAY_AGENT_ID"
    /// Which face of the agent's tile started the process. Set to `terminal`
    /// beside the owner tag when the tile runs the real CLI in its Terminal
    /// face; absent for the headless runners.
    public static let faceEnvironmentKey = "ARRAY_AGENT_FACE"

    public static func ownerTag(for id: AgentID) -> String { id.rawValue.uuidString }

    /// A job younger than this is a tool call in flight, not a background job.
    public static let minimumJobAge: TimeInterval = 3

    /// A direct child the CLI starts this soon after itself is part of the CLI
    /// (Codex's node wrapper execs its native binary immediately); a tool call
    /// cannot be issued before a model has answered.
    public static let cliInternalWindow: TimeInterval = 2

    /// Every process an agent owns, by owner tag. Processes under `hostPid`
    /// that carry no tag and have no tagged ancestor (terminal tiles, the app's
    /// own helpers) own nothing.
    public static func owners(in samples: [ProcessSample], hostPid: Int32) -> [Int32: String] {
        let byPid = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var resolved: [Int32: String?] = [:]
        func owner(of pid: Int32, depth: Int) -> String? {
            if let known = resolved[pid] { return known }
            guard depth < 64, let sample = byPid[pid] else { return nil }
            var result = sample.ownerTag
            if result == nil, sample.parentPid > 1, sample.parentPid != hostPid, sample.parentPid != pid {
                result = owner(of: sample.parentPid, depth: depth + 1)
            }
            resolved[pid] = result
            return result
        }
        var owners: [Int32: String] = [:]
        for sample in samples where sample.pid != hostPid {
            if let tag = owner(of: sample.pid, depth: 0) { owners[sample.pid] = tag }
        }
        return owners
    }

    /// The jobs in `samples`, grouped under their owner tag.
    ///
    /// - Parameters:
    ///   - hostPid: this app. An owned process whose parent is the host is an
    ///     agent's CLI and is never a job.
    ///   - internalPathPrefixes: executables that are part of the host (the
    ///     workspace MCP helper inside the app bundle).
    public static func jobs(
        in samples: [ProcessSample],
        hostPid: Int32,
        internalPathPrefixes: [String],
        now: Date,
        minimumAge: TimeInterval = minimumJobAge
    ) -> [String: [AgentBackgroundJob]] {
        let owners = owners(in: samples, hostPid: hostPid)
        let byPid = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Int32: [ProcessSample]] = [:]
        for sample in samples { children[sample.parentPid, default: []].append(sample) }
        for key in children.keys { children[key]?.sort { ($0.startedAt, $0.pid) < ($1.startedAt, $1.pid) } }

        // The agent's own CLI processes: the one the host launched, plus what
        // that CLI execs into at once, plus the host's helpers.
        var cliPids: Set<Int32> = []
        func markInternal(_ sample: ProcessSample) {
            cliPids.insert(sample.pid)
            for child in children[sample.pid] ?? [] where owners[child.pid] != nil {
                let isHelper = internalPathPrefixes.contains { child.executablePath.hasPrefix($0) }
                let isImmediate = child.startedAt.timeIntervalSince(sample.startedAt) < cliInternalWindow
                    && !isShell(child)
                if isHelper { cliPids.insert(child.pid) } else if isImmediate { markInternal(child) }
            }
        }
        for sample in samples where sample.parentPid == hostPid && owners[sample.pid] != nil {
            markInternal(sample)
        }

        var result: [String: [AgentBackgroundJob]] = [:]
        for sample in samples {
            guard let owner = owners[sample.pid], !cliPids.contains(sample.pid) else { continue }
            if internalPathPrefixes.contains(where: { sample.executablePath.hasPrefix($0) }) { continue }
            let parentOwner = owners[sample.parentPid]
            let underCLI = cliPids.contains(sample.parentPid)
            // A root is where the agent's own tree hands off, or where a
            // process stands outside it. Anything else is inside a job.
            guard underCLI || parentOwner != owner else { continue }
            guard now.timeIntervalSince(sample.startedAt) >= minimumAge else { continue }

            var subtree: [ProcessSample] = []
            var queue = [sample]
            while !queue.isEmpty {
                let next = queue.removeFirst()
                subtree.append(next)
                queue.append(contentsOf: (children[next.pid] ?? []).filter { owners[$0.pid] == owner })
            }
            let ports = Array(Set(subtree.flatMap(\.listeningPorts))).sorted()
            let shown = subtree.first { !$0.listeningPorts.isEmpty }
                ?? subtree.first { !isShell($0) }
                ?? sample
            result[owner, default: []].append(AgentBackgroundJob(
                id: "\(sample.pid)-\(Int(sample.startedAt.timeIntervalSince1970 * 1000))",
                owner: owner,
                rootPid: sample.pid,
                pids: subtree.map(\.pid),
                startTimes: Dictionary(subtree.map { ($0.pid, $0.startedAt) }, uniquingKeysWith: { a, _ in a }),
                label: label(for: shown),
                commandLine: shown.arguments.joined(separator: " "),
                ports: ports,
                startedAt: sample.startedAt,
                detached: !underCLI || byPid[sample.parentPid] == nil))
        }
        for key in result.keys { result[key]?.sort { ($0.startedAt, $0.rootPid) < ($1.startedAt, $1.rootPid) } }
        return result
    }

    static let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "-zsh", "-bash"]
    static let interpreterNames: Set<String> = ["node", "python", "python3", "ruby", "bun", "deno", "perl", "php"]

    static func isShell(_ sample: ProcessSample) -> Bool {
        let name = (sample.arguments.first.map { ($0 as NSString).lastPathComponent }
            ?? (sample.executablePath as NSString).lastPathComponent)
        return shellNames.contains(name) || shellNames.contains((sample.executablePath as NSString).lastPathComponent)
    }

    /// The command as a person would type it: `npm run dev`, not
    /// `/opt/homebrew/bin/node /opt/homebrew/bin/npm run dev`, and the script a
    /// shell is running rather than the shell.
    public static func label(for sample: ProcessSample, limit: Int = 80) -> String {
        var arguments = sample.arguments
        if arguments.isEmpty { arguments = [sample.executablePath] }
        let first = (arguments[0] as NSString).lastPathComponent
        var words: [String]
        if shellNames.contains(first), let flag = arguments.firstIndex(of: "-c"), flag + 1 < arguments.count {
            words = [shellScriptSummary(arguments[flag + 1])]
        } else if interpreterNames.contains(where: { first == $0 || first.hasPrefix($0 + ".") || first.hasPrefix($0 + "3") }),
                  arguments.count > 1, arguments[1].contains("/"), !arguments[1].hasPrefix("-") {
            words = [(arguments[1] as NSString).lastPathComponent] + arguments.dropFirst(2)
        } else {
            words = [first] + arguments.dropFirst()
        }
        words = words.map { $0.hasPrefix("/") && $0.count > 24 ? ($0 as NSString).lastPathComponent : $0 }
        let text = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// Claude wraps every Bash call as `source <snapshot> && … && eval '<cmd>'`.
    /// The command is the part inside `eval`.
    static func shellScriptSummary(_ script: String) -> String {
        if let range = script.range(of: "eval '") {
            let rest = script[range.upperBound...]
            if let end = rest.range(of: "' \\< /dev/null") ?? rest.range(of: "'", options: .backwards) {
                return String(rest[..<end.lowerBound]).replacingOccurrences(of: "'\\''", with: "'")
            }
        }
        return script.split(separator: "\n").first.map(String.init) ?? script
    }
}

/// The rest of the Mac's listening ports, one row per app.
public struct OtherListeningApp: Equatable, Sendable {
    public var name: String
    public var ports: [UInt16]
    /// Every process behind the row's ports; the first is the one shown.
    public var processes: [ProcessSample]
}

public enum OtherListeningApps {
    /// macOS's own listeners (AirPlay in ControlCenter, rapportd, sharingd) are
    /// most of what a Mac has open and none of it is something you would open
    /// or stop; Array's own installs are the canvas you are looking at.
    public static func isHidden(_ sample: ProcessSample) -> Bool {
        let path = sample.executablePath
        if ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"].contains(where: path.hasPrefix) { return true }
        return ["Array", "Array Dev"].contains(name(for: sample))
    }

    /// The app a process belongs to: `Docker` for anything inside
    /// `Docker.app`, the command's name for a binary (`postgres`), and the
    /// script for an interpreter (`vite`, not `node`).
    public static func name(for sample: ProcessSample) -> String {
        if let app = appName(sample.executablePath) { return app }
        let command = ((sample.arguments.first ?? sample.executablePath) as NSString).lastPathComponent
        let interpreted = AgentProcessAttribution.interpreterNames.contains { command == $0 || command.hasPrefix($0 + ".") }
        return interpreted ? AgentProcessAttribution.label(for: sample, limit: 48) : command
    }

    /// Grouped by app, ordered by each app's lowest port; hidden ones dropped.
    public static func groups(_ samples: [ProcessSample]) -> [OtherListeningApp] {
        var order: [String] = []
        var byName: [String: OtherListeningApp] = [:]
        for sample in samples where !sample.listeningPorts.isEmpty && !isHidden(sample) {
            let name = name(for: sample)
            if byName[name] == nil {
                order.append(name)
                byName[name] = OtherListeningApp(name: name, ports: [], processes: [])
            }
            byName[name]?.ports.append(contentsOf: sample.listeningPorts)
            byName[name]?.processes.append(sample)
        }
        return order.compactMap { name in
            byName[name].map { app in
                var app = app
                app.ports = Array(Set(app.ports)).sorted()
                return app
            }
        }.sorted { ($0.ports.first ?? 0, $0.name) < ($1.ports.first ?? 0, $1.name) }
    }

    /// `/Applications/Docker.app/Contents/MacOS/com.docker.backend` → `Docker`.
    /// The outermost bundle, so a helper app nested inside names its parent.
    static func appName(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return (String(path[..<range.lowerBound]) as NSString).lastPathComponent
    }
}

/// What the tile chip, its menu and the top-bar menu say about a set of jobs.
public enum AgentBackgroundJobText {
    /// The chip's value: the ports when there are any (the thing you open),
    /// else how many jobs. `:3000 :8000`, `:3000 +2`, `2 running`.
    public static func chipValue(_ jobs: [AgentBackgroundJob]) -> String? {
        guard !jobs.isEmpty else { return nil }
        let ports = jobs.flatMap(\.ports)
        guard !ports.isEmpty else { return jobs.count == 1 ? "1 running" : "\(jobs.count) running" }
        let shown = ports.prefix(2).map { ":\($0)" }.joined(separator: " ")
        let rest = jobs.filter { $0.ports.isEmpty }.count + max(0, ports.count - 2)
        return rest > 0 ? "\(shown) +\(rest)" : shown
    }

    public static func uptime(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return "\(seconds / 86_400)d"
    }

    /// One menu row: `next dev  :3000 · 12m`.
    public static func menuTitle(_ job: AgentBackgroundJob, now: Date) -> String {
        "\(job.label)  \(menuDetail(job, now: now))"
    }

    /// The quiet half of a row: `:3000 · 12m`.
    public static func menuDetail(_ job: AgentBackgroundJob, now: Date) -> String {
        let ports = job.ports.map { ":\($0)" }.joined(separator: " ")
        return [ports, uptime(since: job.startedAt, now: now)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The top bar icon's tooltip and spoken label.
    public static func summary(_ count: Int) -> String {
        count == 1 ? "1 process running in the background" : "\(count) processes running in the background"
    }

    public static func detail(_ jobs: [AgentBackgroundJob], now: Date) -> String {
        let lines = jobs.map { job in
            menuTitle(job, now: now) + (job.detached ? " (keeps running after Stop)" : "")
        }
        return (["Running in the background:"] + lines).joined(separator: "\n")
    }
}
