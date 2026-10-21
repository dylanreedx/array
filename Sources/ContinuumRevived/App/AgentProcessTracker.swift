import AppKit
import ContinuumRevivedCore

extension Notification.Name {
    /// Posted on the main thread when any agent's background jobs change.
    /// `userInfo["agentIDs"]` is the `Set<AgentID>` whose lists changed.
    static let agentBackgroundJobsDidChange = Notification.Name("ArrayAgentBackgroundJobsDidChange")
}

/// What every agent has left running, kept current.
///
/// One scan for the whole app, off the main thread. Scans are driven three
/// ways, so the list follows a process's whole life rather than a clock:
/// - **Exit** is an event. Every listed process is watched with a kqueue exit
///   source; the moment one ends, the table is read again (`watchExits`).
/// - **Arrival** is scheduled. A new job is listed once it is
///   `minimumJobAge` old, so the next scan is booked for exactly then.
/// - **Everything else** (a port opening, a job no source saw start) is
///   polled: every second while a panel is open, 2s while Array is frontmost,
///   5s when it is not.
/// Only agents whose lists changed are told, so an idle canvas repaints nothing.
@MainActor
final class AgentProcessTracker {
    static let liveInterval: TimeInterval = 1
    static let activeInterval: TimeInterval = 2
    static let inactiveInterval: TimeInterval = 5
    /// Exits arrive in bursts (Stop All, a dev server and its workers); one
    /// rescan covers the burst.
    static let exitCoalescing: TimeInterval = 0.08

    private(set) var jobsByAgent: [AgentID: [AgentBackgroundJob]] = [:]

    /// Agents this app owns. A tag from another install (an agent in the prod
    /// app that built this one) names an agent this app has never heard of.
    var knownAgents: () -> Set<AgentID> = { [] }
    var agentName: (AgentID) -> String = { _ in "Agent" }
    /// `Claude Code · my-project`: what the panel says under the agent's name.
    var agentDetail: (AgentID) -> String? = { _ in nil }
    /// Opens a URL in a browser tile, beside the agent's tile when one is given.
    var openURL: ((String, AgentID?) -> Void)?
    var revealAgent: ((AgentID) -> Void)?

    private let worker = Worker()
    private let internalPathPrefixes: [String]
    private var timer: Timer?
    private var tickInFlight = false
    /// Asked for while a scan was already running: that scan may predate what
    /// prompted the ask (an exit), so another runs straight after it.
    private var rescanQueued = false
    private var completions: [@MainActor @Sendable () -> Void] = []
    private var exitSources: [Int32: (startedAt: Date, source: DispatchSourceProcess)] = [:]
    private var exitRescanPending = false
    private(set) var tickCount = 0
    /// Open panels. While any is open the scan runs every second, so what you
    /// are looking at is current.
    var liveDemand = 0 {
        didSet { if liveDemand > oldValue { refreshNow() } }
    }
    private(set) lazy var panel = ProcessesPanelController(tracker: self)

    /// - Parameter internalPathPrefixes: the host's own helper executables
    ///   (the workspace MCP server), which run under an agent but are Array's.
    ///   Exact paths, not the bundle: a bare debug binary's "bundle" is the
    ///   whole build folder.
    init(internalPathPrefixes: [String]) {
        self.internalPathPrefixes = internalPathPrefixes
    }

    var totalJobCount: Int { jobsByAgent.values.reduce(0) { $0 + $1.count } }
    var watchedPidCount: Int { exitSources.count }

    func jobs(for agent: AgentID) -> [AgentBackgroundJob] { jobsByAgent[agent] ?? [] }

    func start() {
        guard timer == nil else { return }
        refreshNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Scan now, then carry on at the usual cadence. `completion` runs once a
    /// scan that started after this call has been published.
    func refreshNow(completion: (@MainActor @Sendable () -> Void)? = nil) {
        timer?.invalidate()
        timer = nil
        if let completion { completions.append(completion) }
        guard !tickInFlight else {
            rescanQueued = true
            return
        }
        tickInFlight = true
        let prefixes = internalPathPrefixes
        let worker = worker
        worker.queue.async {
            // Every job, however young; `minimumJobAge` is applied here so the
            // tracker knows when the youngest will be old enough to list.
            let raw = worker.reader.agentJobs(internalPathPrefixes: prefixes, minimumAge: 0)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.tickInFlight = false
                self.tickCount += 1
                let now = Date()
                var ready: [String: [AgentBackgroundJob]] = [:]
                var nextArrival: Date?
                for (owner, jobs) in raw {
                    for job in jobs {
                        let listable = job.startedAt.addingTimeInterval(AgentProcessAttribution.minimumJobAge)
                        if listable <= now {
                            ready[owner, default: []].append(job)
                        } else {
                            nextArrival = min(nextArrival ?? listable, listable)
                        }
                    }
                }
                self.publish(ready)
                self.watchExits()
                if self.rescanQueued {
                    self.rescanQueued = false
                    self.refreshNow()
                    return
                }
                let finished = self.completions
                self.completions.removeAll()
                self.scheduleNext(arrival: nextArrival, now: now)
                finished.forEach { $0() }
            }
        }
    }

    private func scheduleNext(arrival: Date?, now: Date) {
        var interval = liveDemand > 0 ? Self.liveInterval
            : NSApp?.isActive == true ? Self.activeInterval : Self.inactiveInterval
        if let arrival { interval = min(interval, max(0.05, arrival.timeIntervalSince(now) + 0.05)) }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        // Common modes: a scroll or a drag in progress must not hold a scan.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One exit source per listed process, matched by start time so a pid the
    /// OS reuses is never mistaken for the one we were watching.
    private func watchExits() {
        var wanted: [Int32: Date] = [:]
        for job in jobsByAgent.values.flatMap({ $0 }) {
            for pid in job.pids { wanted[pid] = job.startTimes[pid] ?? job.startedAt }
        }
        for (pid, watch) in exitSources where wanted[pid] != watch.startedAt {
            watch.source.cancel()
            exitSources[pid] = nil
        }
        for (pid, startedAt) in wanted where exitSources[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.processExited() }
            }
            source.resume()
            exitSources[pid] = (startedAt, source)
        }
    }

    private func processExited() {
        guard !exitRescanPending else { return }
        exitRescanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitCoalescing) { [weak self] in
            MainActor.assumeIsolated {
                self?.exitRescanPending = false
                self?.refreshNow()
            }
        }
    }

    func publish(_ raw: [String: [AgentBackgroundJob]]) {
        let known = knownAgents()
        var next: [AgentID: [AgentBackgroundJob]] = [:]
        for (tag, jobs) in raw {
            guard let uuid = UUID(uuidString: tag) else { continue }
            let agent = AgentID(rawValue: uuid)
            guard known.contains(agent), !jobs.isEmpty else { continue }
            next[agent] = jobs
        }
        let changed = Set(next.keys).union(jobsByAgent.keys).filter { next[$0] != jobsByAgent[$0] }
        jobsByAgent = next
        guard !changed.isEmpty else { return }
        NotificationCenter.default.post(
            name: .agentBackgroundJobsDidChange, object: self, userInfo: ["agentIDs": changed])
    }

    /// SIGTERM, then SIGKILL after 2s, off the main thread; rescans after.
    func stop(_ jobs: [AgentBackgroundJob], completion: (@MainActor @Sendable () -> Void)? = nil) {
        let worker = worker
        worker.queue.async {
            for job in jobs { AgentProcessControl.terminate(job) }
            DispatchQueue.main.async { [weak self] in self?.refreshNow(completion: completion) }
        }
    }

    /// Stop processes no agent owns (the rest of the Mac), the same way:
    /// SIGTERM, then SIGKILL, each pid checked against its start time first.
    func stop(_ processes: [ProcessSample], completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let root = processes.first else { completion?(); return }
        let job = AgentBackgroundJob(
            id: "other-\(root.pid)", owner: "", rootPid: root.pid, pids: processes.map(\.pid),
            startTimes: Dictionary(processes.map { ($0.pid, $0.startedAt) }, uniquingKeysWith: { a, _ in a }),
            label: AgentProcessAttribution.label(for: root), commandLine: root.arguments.joined(separator: " "),
            ports: processes.flatMap(\.listeningPorts), startedAt: root.startedAt, detached: true)
        stop([job], completion: completion)
    }

    /// Every app this user runs that listens on a port and that no agent of
    /// this app owns, one entry per app, macOS's own services left out.
    func otherListeningApps(_ completion: @escaping @MainActor ([OtherListeningApp]) -> Void) {
        let owned = Set(jobsByAgent.values.flatMap { $0.flatMap(\.pids) })
        let host = getpid()
        let worker = worker
        worker.queue.async {
            let apps = OtherListeningApps.groups(worker.reader.listeningProcesses()
                .filter { $0.pid != host && !owned.contains($0.pid) })
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(apps) } }
        }
    }

    /// The reader is not thread-safe; it only ever runs on this queue.
    private final class Worker: @unchecked Sendable {
        let queue = DispatchQueue(label: "array.agent-process-tracker", qos: .utility)
        let reader = ProcessTableReader()
    }
}

/// What the chip, the top bar and the panel share.
@MainActor
enum AgentProcessUI {
    static let symbolName = "square.stack.3d.up"

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
