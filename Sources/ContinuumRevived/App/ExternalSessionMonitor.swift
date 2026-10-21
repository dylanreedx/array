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

    private(set) var snapshot = ExternalSessionSnapshot.empty
    /// Called on the main thread after `snapshot` changed.
    var onChange: (() -> Void)?
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
        tick()
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
    }

    /// Replace the snapshot. The production path's last step, and the one a
    /// check drives with sessions it made up.
    func publish(_ next: ExternalSessionSnapshot) {
        guard next != snapshot else { return }
        snapshot = next
        onChange?()
    }

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
