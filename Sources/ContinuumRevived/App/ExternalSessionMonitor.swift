import AppKit
import CoreServices
import ContinuumRevivedCore

// Plan: .plans/79-session-handoff/README.md
/// Every Claude and Codex session on this Mac, kept current for the sidebar.
///
/// One owner for the whole app. Discovery runs off the main thread when
/// FSEvents reports a change under `~/.claude/sessions` or `~/.codex/sessions`
/// (coalesced, at most one pass per `eventMinGap`), plus a slow safety poll for
/// missed events. While a Codex CLI runs, its exit and busy window have no file
/// event, so the old 3s/10s cadence stays until it is gone. The main thread only
/// compares the result with the last one and, when it changed, tells
/// `onChange`. Nothing here runs per frame, and an unchanged Mac costs nothing
/// between events.
///
/// Inert until `start()`, which only a real launch calls (CLAUDE.md hazard 6):
/// a check drives it with `publish(_:)` and never touches the real process
/// table or anyone's session files.
@MainActor
final class ExternalSessionMonitor {
    static let activeInterval: TimeInterval = 3
    static let inactiveInterval: TimeInterval = 10
    /// Safety net for an event FSEvents did not deliver, and for a Claude that
    /// died without removing its file.
    static let safetyInterval: TimeInterval = 60
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

    /// Passes started, for the witness.
    private(set) var passCount = 0
    /// False falls back to polling at the old cadence (the witness's RED arm).
    var watchesFilesystem = true
    /// A pass never starts sooner than this after the last one ended, however
    /// many events arrive: a streaming Codex rollout must not out-poll 3s.
    var eventMinGap: TimeInterval = 3
    private var watcher: SessionFolderWatcher?
    private var lastPassEnded = Date.distantPast
    private var eventTimer: Timer?

    private let worker = Worker()
    private var timer: Timer?
    private var tickInFlight = false
    private(set) var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        beginAwaitingFirstPass()
        if watchesFilesystem { startWatching() }
        tick()
    }

    private func startWatching() {
        let home = homeOverride?.home ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let codexHome = homeOverride?.codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        watcher = SessionFolderWatcher(paths: [
            home.appendingPathComponent(".claude/sessions", isDirectory: true).path,
            codexHome.appendingPathComponent("sessions", isDirectory: true).path,
        ]) { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
    }

    /// An event: pass now if the last pass is old enough, else once it is.
    private func folderChanged() {
        guard isStarted, eventTimer == nil, !tickInFlight else {
            if tickInFlight { eventPending = true }
            return
        }
        let wait = max(0, eventMinGap - Date().timeIntervalSince(lastPassEnded))
        guard wait > 0 else { fireEventPass(); return }
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireEventPass() }
        }
        RunLoop.main.add(timer, forMode: .common)
        eventTimer = timer
    }
    private var eventPending = false

    private func fireEventPass() {
        eventTimer?.invalidate()
        eventTimer = nil
        timer?.invalidate()
        timer = nil
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
        eventTimer?.invalidate()
        eventTimer = nil
        watcher = nil
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
        passCount += 1
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
                    self.lastPassEnded = Date()
                    guard self.isStarted else { return }
                    self.publish(next)
                    self.scheduleNext()
                    if self.eventPending {
                        self.eventPending = false
                        self.folderChanged()
                    }
                }
            }
        }
    }

    /// Checks only: one interval whether or not the app is frontmost.
    var qaInterval: TimeInterval?
    /// Checks only: the polling cadence (not the safety interval).
    var pollingOverride: TimeInterval?

    private func scheduleNext() {
        let polling = pollingOverride ?? (NSApp?.isActive == true ? Self.activeInterval : Self.inactiveInterval)
        // A Codex CLI's exit and busy window leave no file event.
        let needsPolling = !watchesFilesystem || reportsEveryPass()
            || snapshot.sessions.contains { $0.provider == .codex }
        let interval = qaInterval ?? (needsPolling ? polling : Self.safetyInterval)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes: a scroll or a drag in progress must not hold a scan.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// FSEvents on the folders discovery reads. The stream's own latency
    /// coalesces a burst into one callback.
    private final class SessionFolderWatcher {
        private var stream: FSEventStreamRef?
        private let handler: () -> Void

        init(paths: [String], handler: @escaping () -> Void) {
            self.handler = handler
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<SessionFolderWatcher>.fromOpaque(info).takeUnretainedValue().handler()
            }
            guard let stream = FSEventStreamCreate(
                nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
            ) else { return }
            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }

        deinit {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// The reader and discovery keep caches and are not thread-safe; they only
    /// ever run on this queue.
    private final class Worker: @unchecked Sendable {
        let queue = DispatchQueue(label: "array.external-session-monitor", qos: .utility)
        let reader = ProcessTableReader()
        let discovery = ExternalSessionDiscovery()
    }
}
