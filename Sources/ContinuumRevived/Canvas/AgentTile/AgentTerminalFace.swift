import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Session handoff (`.plans/79-session-handoff`), stream D. An agent tile's
// Terminal face: the real `claude` TUI on the agent's own conversation, in a
// Ghostty surface inside the same tile. The flip rules live on the tile
// (`ManagedAgentTileNSView`, "Terminal face"); this file is the process.

/// What a Terminal face needs from its host. The app builds one in
/// `wireManagedAgentTile`; a check builds the same with isolated values.
@MainActor
struct AgentTerminalFaceEnvironment {
    var ghostty: GhosttyRuntimeContext
    /// tmux, so claude outlives an Array quit and the tile reattaches on
    /// relaunch (edge case 5). nil runs claude directly in the surface, where
    /// it ends with the surface.
    var tmuxPath: String?
    var defaults: UserDefaults
    /// Where claude keeps `.claude/` — the user's home. Only checks move it.
    var claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser
    /// The managed runner's own resolution, so both faces run one CLI.
    var claudeCommand: () -> PiAgentRunner.ResolvedCommand = { ClaudeAgentRunner.liveResolvedCommand() }
    var reservedShortcutHandler: ((NSEvent) -> Bool)?
    /// How often the live session file is read while the face runs.
    var pollInterval: TimeInterval = 2
    /// Asks before ending a busy claude. True means go ahead.
    var confirm: (_ message: String, _ action: String) -> Bool = { message, action in
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "Its turn stops, and what it has written so far stays in the session."
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private extension AgentFaceFlipBanner.Content {
    /// Content that stays until something takes it down.
    var isLasting: Bool {
        if case .refusal = self { return false }
        return true
    }
}

/// One agent's Terminal face, from the flip until claude is gone: the mark,
/// every session claude moved through, and what claude says about itself.
///
/// Owned by the supervisor and keyed by the agent (`AgentSupervisor
/// .terminalFaceWatch(for:)`), never by a tile view: a tile can be parked in
/// another workspace, evicted, or rebuilt while claude runs, and claude
/// leaving must still end the face, release the session and bring its turns
/// home (`.plans/79` review #9). A view only hosts a surface — a Ghostty
/// client onto this face — and reflects what the watch reports.
@MainActor
final class AgentTerminalFaceWatch {
    let agentID: AgentID
    let tileId: UUID
    /// The flip's mark and the first session. `latestSessionId` follows claude.
    private(set) var state: AgentTerminalFaceState
    /// Every session id claude reported, oldest first. `/clear` and `/resume`
    /// move a running claude to a new session (edge case 3); the face's end
    /// reads all of them.
    private(set) var sessionIds: [String]
    private(set) var claudePid: Int32?
    private(set) var live: ClaudeTerminalFace.LiveSession?
    /// The tmux session claude lives in, when tmux runs it.
    let tmuxSessionName: String?
    let environment: AgentTerminalFaceEnvironment
    /// The argv a surface runs: with tmux, `new-session -A` attaches a new
    /// client to the running claude.
    var launchArguments: [String] = []
    /// The agent's consequences, set by the supervisor: the busy pill, a new
    /// session id, and claude being gone.
    var onBusyChange: ((Bool) -> Void)?
    var onSessionChange: ((String) -> Void)?
    var onGone: (() -> Void)?
    /// The hosting view's, set while a view shows this face: its tmux client
    /// went while claude runs, claude moved session, and the face is over
    /// (with the turns the transcript gained).
    var onHostClientDetached: (() -> Void)?
    var onHostSessionChange: ((AgentTerminalFaceState) -> Void)?
    var onHostEnded: ((Int) -> Void)?
    /// A surface kept running with no tile to show it in (tmux off, the tile
    /// left its workspace): claude is that surface's child, so dropping it
    /// would end claude mid-turn without asking (review #17).
    private(set) var keptSurface: AgentTerminalFaceSession?
    private var pollTimer: Timer?
    private var pollInFlight = false
    private(set) var isEnded = false
    /// tmux has shown claude's session. Until then a missing session is one
    /// not made yet, not one that ended.
    private var sawTmuxSession = false

    init(agentID: AgentID, tileId: UUID, state: AgentTerminalFaceState, environment: AgentTerminalFaceEnvironment) {
        self.agentID = agentID
        self.tileId = tileId
        self.state = state
        self.sessionIds = state.sessionIds
        self.environment = environment
        tmuxSessionName = environment.tmuxPath == nil ? nil : TmuxSession.sessionName(tileId: tileId)
    }

    var isBusy: Bool { live?.isBusy ?? false }
    var currentSessionId: String { sessionIds.last ?? state.sessionId }

    /// One timer per running face, whatever its tiles do: it is how claude
    /// leaving is seen when no surface is up to report it.
    func start() {
        guard pollTimer == nil, !isEnded else { return }
        let timer = Timer(timeInterval: environment.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        poll()
    }

    /// Claude is gone and its turns are being read: nothing more to ask.
    func stopPolling() {
        isEnded = true
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// The face is over and its turns are in the transcript: the host flips
    /// back, and a kept surface is let go.
    func end(appendedTurns: Int) {
        stopPolling()
        let ended = onHostEnded
        onHostEnded = nil
        onHostClientDetached = nil
        onHostSessionChange = nil
        keptSurface?.detachSurface()
        keptSurface = nil
        ended?(appendedTurns)
    }

    func keepSurfaceAlive(_ surface: AgentTerminalFaceSession) {
        keptSurface = surface
    }

    func takeKeptSurface() -> AgentTerminalFaceSession? {
        defer { keptSurface = nil }
        return keptSurface
    }

    /// Ends claude itself. With tmux that is its session, killed off the main
    /// thread; without, the surface it runs in. Either way the exit that
    /// follows ends the face.
    func endClaude(surface: AgentTerminalFaceSession?) {
        if let tmuxPath = environment.tmuxPath, let name = tmuxSessionName {
            let control = ProcessTmuxControl(tmuxPath: tmuxPath, defaults: environment.defaults)
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = try? control.run(["kill-session", "-t", name])
                await MainActor.run { self?.poll() }
            }
        } else {
            (surface ?? keptSurface)?.runtime.terminate(policy: .force)
        }
    }

    /// A surface showing this face ended. Only a gone claude ends the face:
    /// a tmux client can end while claude runs (detached, or the app going
    /// away), and the host attaches again.
    func surfaceExited(_ surface: AgentTerminalFaceSession) {
        if keptSurface === surface { keptSurface = nil }
        guard !isEnded else { return }
        guard let control = tmuxControl, let name = tmuxSessionName else {
            onGone?()
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let alive = (try? control.run(["has-session", "-t", name])) != nil
            await MainActor.run {
                guard let self, !self.isEnded else { return }
                if alive { self.onHostClientDetached?() } else { self.onGone?() }
            }
        }
    }

    /// Whether a tmux session for `tileId` runs now, asked off the main thread.
    nonisolated static func tmuxSessionExists(tileId: UUID, control: ProcessTmuxControl?) async -> Bool {
        guard let control else { return false }
        let name = TmuxSession.sessionName(tileId: tileId)
        return await Task.detached(priority: .userInitiated) {
            (try? control.run(["has-session", "-t", name])) != nil
        }.value
    }

    private var tmuxControl: ProcessTmuxControl? {
        environment.tmuxPath.map { ProcessTmuxControl(tmuxPath: $0, defaults: environment.defaults) }
    }

    /// One read of what claude says about the process, off the main thread.
    func poll() {
        guard !pollInFlight, !isEnded else { return }
        pollInFlight = true
        let known = claudePid
        // `ProcessTmuxControl` is Sendable; the defaults it holds are not.
        let control = tmuxControl
        let name = tmuxSessionName
        let home = environment.claudeHome
        let processOwner = AgentProcessAttribution.ownerTag(for: agentID)
        Task { @MainActor [weak self] in
            let (pid, live, tmuxGone) = await Self.readProcess(
                known: known, control: control, sessionName: name,
                processOwner: processOwner, claudeHome: home)
            guard let self else { return }
            self.pollInFlight = false
            guard !self.isEnded else { return }
            if tmuxGone {
                if self.sawTmuxSession { self.onGone?() }
                return
            }
            self.sawTmuxSession = true
            if self.claudePid == nil { self.claudePid = pid }
            guard let live else { return }
            let wasBusy = self.live?.isBusy ?? false
            self.live = live
            if live.isBusy != wasBusy { self.onBusyChange?(live.isBusy) }
            if live.sessionId != self.currentSessionId {
                self.sessionIds.append(live.sessionId)
                // Persisted, so a relaunch that finds tmux gone still adopts it.
                self.state.latestSessionId = live.sessionId
                self.onSessionChange?(live.sessionId)
                self.onHostSessionChange?(self.state)
            }
        }
    }

    /// Off the main actor: a tmux query and two small file reads.
    nonisolated private static func readProcess(
        known: Int32?, control: ProcessTmuxControl?, sessionName: String?,
        processOwner: String, claudeHome: URL
    ) async -> (Int32?, ClaudeTerminalFace.LiveSession?, tmuxGone: Bool) {
        if let control, let sessionName, (try? control.run(["has-session", "-t", sessionName])) == nil {
            return (known, nil, true)
        }
        var pid = known
        if pid == nil, let control, let sessionName {
            // `/usr/bin/env` execs claude, so the pane's pid IS claude's.
            let out = try? control.run(["list-panes", "-t", sessionName, "-F", "#{pane_pid}"])
            pid = out.flatMap { Int32($0.split(separator: "\n").first.map(String.init) ?? "") }
        }
        if pid == nil {
            pid = pidFromSessionFiles(processOwner: processOwner, claudeHome: claudeHome)
        }
        return (pid, pid.flatMap { ClaudeTerminalFace.liveSession(pid: $0, claudeHome: claudeHome) }, false)
    }

    /// A direct face can fork or /clear before its first poll, so its initial
    /// session id need not appear in any live file. Match the process's own
    /// agent/face tags instead; never mistake the source's other writer for it.
    nonisolated private static func pidFromSessionFiles(processOwner: String, claudeHome: URL) -> Int32? {
        let candidates = ProcessTableReader().sample().filter {
            $0.ownerTag == processOwner && $0.ownerFace == "terminal"
                && ClaudeTerminalFace.liveSession(pid: $0.pid, claudeHome: claudeHome) != nil
        }
        return candidates.count == 1 ? candidates[0].pid : nil
    }
}

/// One surface onto a Terminal face: a Ghostty client inside a tile. With
/// tmux it is a client of claude's tmux session and can come and go; without,
/// claude is its child. What claude is doing is the watch's to know.
@MainActor
final class AgentTerminalFaceSession {
    let tileId: UUID
    let hostView = TerminalHostView(frame: .zero)
    let runtime: GhosttyTerminalRuntime
    /// The tmux session the face lives in, when tmux runs it.
    let tmuxSessionName: String?
    let watch: AgentTerminalFaceWatch
    /// Array is tearing the surface down on purpose (a workspace switch, a
    /// close): its exit is not claude leaving.
    private var detaching = false

    init(watch: AgentTerminalFaceWatch, arguments: [String]) {
        self.watch = watch
        tileId = watch.tileId
        let environment = watch.environment
        let inner = LaunchProfile(
            command: arguments[0], arguments: Array(arguments.dropFirst()), cwd: watch.state.cwd, title: "Claude Code")
        let profile: LaunchProfile
        if let tmuxPath = environment.tmuxPath {
            // `new-session -A`: attaches when the session already exists, which
            // is the relaunch reattach; creates it running claude otherwise.
            profile = TmuxSession.wrap(profile: inner, tileId: watch.tileId, tmuxPath: tmuxPath, defaults: environment.defaults)
            tmuxSessionName = TmuxSession.sessionName(tileId: watch.tileId)
        } else {
            profile = inner
            tmuxSessionName = nil
        }
        runtime = GhosttyTerminalRuntime(
            tileId: watch.tileId, title: "Claude Code", launchProfile: profile,
            ghostty: environment.ghostty, displayDefaults: environment.defaults)
        runtime.reservedShortcutHandler = environment.reservedShortcutHandler
        runtime.onRuntimeExited = { [weak self] _, _ in
            guard let self, !self.detaching else { return }
            self.watch.surfaceExited(self)
        }
    }

    var isBusy: Bool { watch.isBusy }
    var claudePid: Int32? { watch.claudePid }
    var sessionIds: [String] { watch.sessionIds }
    var currentSessionId: String { watch.currentSessionId }

    func start() {
        hostView.attach(runtime: runtime)
    }

    /// Ends the surface. With tmux claude stays in its session.
    func detachSurface() {
        detaching = true
        runtime.terminate(policy: .force)
        hostView.detachRuntime()
    }
}

/// The banner slot above the composer (`mocks/2-one-tile-two-faces.png`,
/// bottom left). It says one thing at a time:
/// - "Switches to Terminal when this turn ends", while a flip waits (edge case
///   9), with Stop now and Cancel;
/// - why a flip cannot happen now, for a few seconds — a refusal is news about
///   a click, not part of the conversation, so it never enters the transcript.
/// Paints in `draw(_:)` from tokens, like the title band, so it adds no layer
/// colour.
@MainActor
final class AgentFaceFlipBanner: NSView {
    enum Content: Equatable {
        case pendingFlip
        case refusal(String)
    }

    /// How long a refusal stays up.
    static let refusalDuration: TimeInterval = 4

    let label = NSTextField(labelWithString: "Switches to Terminal when this turn ends")
    let stopButton = NSButton(title: "Stop now", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let icon = NSImageView()
    var onStopNow: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var content: Content?
    /// Under a refusal, what to show again once it has gone.
    private var underlying: Content?
    private var refusalTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("agentTile.faceFlipBanner")
        isHidden = true
        icon.setAccessibilityElement(false)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [stopButton, cancelButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        stopButton.action = #selector(stopNow)
        cancelButton.action = #selector(cancel)
        let row = NSStackView(views: [icon, label, NSView(), stopButton, cancelButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = CGFloat(Space.m)
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Space.m)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.m)),
            row.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(Space.s)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CGFloat(Space.s)),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label.stringValue)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func stopNow() { onStopNow?() }
    @objc private func cancel() { onCancel?() }

    /// Shows `content`. A refusal stands over whatever was showing and gives
    /// it back when it goes.
    func show(_ content: Content) {
        refusalTimer?.invalidate()
        refusalTimer = nil
        if case .refusal = content {
            if let current = self.content, current.isLasting { underlying = current }
            let timer = Timer(timeInterval: Self.refusalDuration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.endRefusal() }
            }
            RunLoop.main.add(timer, forMode: .common)
            refusalTimer = timer
        } else {
            underlying = nil
        }
        apply(content)
    }

    /// Takes `content` down if it is what shows (or what a refusal covers).
    func dismiss(_ content: Content? = nil) {
        if let content, self.content != content {
            if underlying == content { underlying = nil }
            return
        }
        refusalTimer?.invalidate()
        refusalTimer = nil
        underlying = nil
        apply(nil)
    }

    private func endRefusal() {
        refusalTimer = nil
        let next = underlying
        underlying = nil
        apply(next)
    }

    private func apply(_ content: Content?) {
        self.content = content
        isHidden = content == nil
        guard let content else { return }
        let symbol: String
        switch content {
        case .pendingFlip:
            symbol = "clock"
            label.stringValue = "Switches to Terminal when this turn ends"
        case .refusal(let reason):
            symbol = "exclamationmark.circle"
            label.stringValue = reason
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        stopButton.isHidden = content != .pendingFlip
        cancelButton.isHidden = content != .pendingFlip
        setAccessibilityLabel(label.stringValue)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        label.textColor = TextToken.textPrimary.color.nsColor(for: theme)
        let card = bounds.insetBy(dx: CGFloat(Space.m), dy: CGFloat(Space.s))
        let radius = CGFloat(Radius.card)
        SurfaceToken.cardMessage.color.nsColor(for: theme).setFill()
        NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius).fill()
    }
}
