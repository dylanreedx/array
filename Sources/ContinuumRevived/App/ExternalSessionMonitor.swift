import AppKit
import ContinuumRevivedCore

// Plan: .plans/79-session-handoff/README.md
/// Every Claude and Codex session on this Mac, kept current for the sidebar.
///
/// One owner for the whole app. Discovery runs off the main thread every 3s
/// while Array is frontmost and every 10s when it is not; the main thread only
/// compares the result with the last one and, when it changed, tells
/// `onChange`. Nothing here runs per frame, and an unchanged Mac costs the main
/// thread one array comparison per tick.
///
/// Inert until `start()`, which only a real launch calls (CLAUDE.md hazard 6):
/// a check drives it with `publish(_:)` and never touches the real process
/// table or anyone's session files.
@MainActor
final class ExternalSessionMonitor {
    static let activeInterval: TimeInterval = 3
    static let inactiveInterval: TimeInterval = 10
    /// How long a launch's sends wait for the first pass (~150 ms on a real
    /// Mac) before going ahead without it.
    static let firstPassWait: TimeInterval = 2

    private(set) var snapshot = ExternalSessionSnapshot.empty
    /// Called on the main thread after `snapshot` changed.
    var onChange: (() -> Void)?
    /// True while something waits on a holder process to exit. Its exit can
    /// end the wait with the snapshot unchanged (the session already missing
    /// from a pass that read its status file mid-rewrite), so every pass is
    /// reported then, not only a changed one.
    var reportsEveryPass: () -> Bool = { false }
    /// tmux pane id → the shell tile showing it, read on the main thread before
    /// each pass: a project's shell tiles share one tmux session, so only the
    /// pane says which tile a claude was typed into.
    var arrayShellPanes: () -> [String: UUID] = { [:] }
    /// Checks only: discovery reads these folders instead of the user's.
    var homeOverride: (home: URL, codexHome: URL)?

    private let worker = Worker()
    private var timer: Timer?
    private var tickInFlight = false
    private(set) var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        beginAwaitingFirstPass()
        tick()
    }

    /// Pauses are not saved: after a launch, until the first pass has looked,
    /// Array cannot know that another app holds an agent's session. Claude and
    /// Codex agents' sends wait while this is true (`AgentSupervisor
    /// .awaitsSessionDiscovery`), for at most `firstPassWait`.
    var isAwaitingFirstPass: Bool {
        guard let awaitingSince, !hasDiscovered else { return false }
        return Date().timeIntervalSince(awaitingSince) < Self.firstPassWait
    }
    private var awaitingSince: Date?
    /// The wait above ended: the first pass published, or it took too long.
    var onFirstPassSettled: (() -> Void)?

    /// `start()`'s first step; a check calls it alone, without reading the Mac.
    func beginAwaitingFirstPass() {
        guard awaitingSince == nil, !hasDiscovered else { return }
        awaitingSince = Date()
        let timer = Timer(timeInterval: Self.firstPassWait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hasDiscovered else { return }
                self.onFirstPassSettled?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
    }

    /// Replace the snapshot. The production path's last step, and the one a
    /// check drives with sessions it made up.
    func publish(_ next: ExternalSessionSnapshot) {
        let first = !hasDiscovered
        hasDiscovered = true
        guard next != snapshot || first || reportsEveryPass() else { return }
        snapshot = next
        onChange?()
        if first, awaitingSince != nil { onFirstPassSettled?() }
    }

    /// Whether any pass has published yet. Until one has, an absent session
    /// means nothing — after a relaunch a Move here tile must not take a
    /// session merely because nobody has looked.
    private(set) var hasDiscovered = false

    func session(forRowId id: UUID) -> ExternalAgentSession? {
        snapshot.sessions.first { ExternalSessionRows.rowId(forSessionKey: $0.id) == id }
    }

    private func tick() {
        guard isStarted, !tickInFlight else { return }
        tickInFlight = true
        let worker = worker
        let panes = arrayShellPanes()
        let home = homeOverride
        worker.queue.async {
            var inputs = ExternalSessionDiscovery.Inputs.live(reader: worker.reader, arrayShellPanes: panes)
            if let home {
                inputs.homeURL = home.home
                inputs.codexHomeURL = home.codexHome
            }
            let next = worker.discovery.discover(inputs)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tickInFlight = false
                    guard self.isStarted else { return }
                    self.publish(next)
                    self.scheduleNext()
                }
            }
        }
    }

    /// Checks only: one interval whether or not the app is frontmost.
    var qaInterval: TimeInterval?

    private func scheduleNext() {
        let interval = qaInterval ?? (NSApp?.isActive == true ? Self.activeInterval : Self.inactiveInterval)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes: a scroll or a drag in progress must not hold a scan.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The reader and discovery keep caches and are not thread-safe; they only
    /// ever run on this queue.
    private final class Worker: @unchecked Sendable {
        let queue = DispatchQueue(label: "array.external-session-monitor", qos: .utility)
        let reader = ProcessTableReader()
        let discovery = ExternalSessionDiscovery()
    }
}
